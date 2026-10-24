import 'dart:async';
import '../../../core/session/account_fence_authority.dart';
import '../../../core/session/admission_authority.dart';
import '../../../core/session/app_session.dart';
import '../../../core/sync/account_fence_retry.dart';
import '../../../core/privacy/consent_authority.dart';
import '../../../core/sync/sync_health.dart';
import '../../../data/repositories/drift_user_settings_repository.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/backend/supabase_config.dart';
import '../../../core/di/app_providers.dart';
import '../../../core/sync/outbox_failure.dart';
import '../../../core/utils/id_generator.dart';
import '../../../data/db/app_database.dart';
import '../../../data/db/sql_value_codec.dart';

/// MALI-024 — the server-authoritative engagement-event service.
final engagementEventServiceProvider =
    Provider<EngagementEventService>((ref) {
  return EngagementEventService(
    db: ref.watch(appDatabaseProvider),
    health: ref.watch(syncHealthProvider),
    // C-3 — engagement events describe what the user did in the app. Read fresh
    // per push so a revocation is observed by the next drain.
    mayEgress: () => ConsentAuthority(
          () => DriftUserSettingsRepository(ref.read(appDatabaseProvider))
              .getSettings(),
        ).allows(EgressClass.gamification),
  );
});

/// MALI-024 — server-authoritative, idempotent engagement events.
///
/// The client records typed engagement events in a durable outbox and submits
/// them to the server (the `record_engagement_event` RPC), which decides the
/// award from server rules and applies it exactly once. The client NEVER uploads
/// an authoritative XP/streak total. The displayed state is the acknowledged
/// server aggregate plus a PROJECTION of not-yet-acknowledged local events —
/// the projection never mutates the authoritative aggregate.

/// The engagement event types the server understands. Kept in one place so the
/// client projection mirrors the server award rule; an unknown type projects 0
/// (and the server rejects it), so a future/unknown type never invents an award.
const Map<String, int> kEngagementAward = {
  'transaction_confirmed': 10,
  'goal_contribution': 15,
  'budget_action': 5,
  'bill_payment': 5,
  'streak_activity': 2,
};

/// The projected XP award for [eventType] (client mirror of the server rule).
/// Unknown/future types project 0 — never a fabricated award.
int projectedAwardFor(String eventType) => kEngagementAward[eventType] ?? 0;

/// The acknowledged server aggregate + a projection of pending local events.
class EngagementProjection {
  const EngagementProjection({
    required this.acknowledgedXp,
    required this.acknowledgedLevel,
    required this.pendingCount,
    required this.projectedXp,
  });

  final int acknowledgedXp;
  final int acknowledgedLevel;
  final int pendingCount;

  /// acknowledged + Σ(projected award of pending events). Equals acknowledged
  /// when nothing is pending.
  final int projectedXp;

  bool get hasPending => pendingCount > 0;
}

/// The result of the server RPC.
class EngagementAck {
  const EngagementAck({required this.xp, required this.level, this.awarded = 0});
  final int xp;
  final int level;
  final int awarded;
}

/// Injectable server recorder — real impl calls the RPC; tests supply a fake.
abstract class EngagementRemoteRecorder {
  Future<EngagementAck> record({
    required String eventId,
    required String eventType,
    required String occurredAt,
    String? businessKey,
    int eventVersion,
  });
}

class SupabaseEngagementRecorder implements EngagementRemoteRecorder {
  const SupabaseEngagementRecorder();

  @override
  Future<EngagementAck> record({
    required String eventId,
    required String eventType,
    required String occurredAt,
    String? businessKey,
    int eventVersion = 1,
  }) async {
    final context = Zone.current[_engagementRemoteKey] as _EngagementRemoteContext?;
    context?.invocation.requireCurrent();
    final intent = context?.intent;
    if (intent != null && (intent.eventId != eventId || intent.eventType != eventType ||
        intent.occurredAt != occurredAt || intent.businessKey != businessKey ||
        intent.eventVersion != eventVersion)) {
      throw const EngagementDeliveryStopped(EngagementDeliveryStopReason.provenance);
    }
    // The synchronous SDK factory and receipt parsing are outside origin tagging.
    final response = Supabase.instance.client.rpc<dynamic>(
      'record_engagement_event',
      params: {
        'p_event_id': eventId,
        'p_event_type': eventType,
        'p_occurred_at': occurredAt,
        'p_business_key': businessKey,
        'p_event_version': eventVersion,
      },
    );
    final dynamic res;
    try {
      res = await response;
    } on PostgrestException catch (error) {
      if (context != null && decodeEngagementAccountDenial(error) != null) {
        throw _EngagementMutationRefusal(context, error);
      }
      rethrow;
    }
    final map = (res as Map).cast<String, dynamic>();
    return EngagementAck(
      xp: (map['xp'] as num?)?.toInt() ?? 0,
      level: (map['level'] as num?)?.toInt() ?? 1,
      awarded: (map['awarded'] as num?)?.toInt() ?? 0,
    );
  }
}

class EngagementEventService {
  EngagementEventService({
    required AppDatabase db,
    EngagementRemoteRecorder? recorder,
    bool Function()? isSyncEnabled,
    Future<String?> Function()? getAuthUserId,
    /// C-3 — consulted at the moment of egress; defaults to DENY so a caller
    /// that omits it makes no network call and leaves events pending.
    Future<bool> Function()? mayEgress,
    SyncHealth? health,
    AccountFenceRetry? fenceRetry,
  })  : _mayEgress = mayEgress ?? _denyEgressByDefault,
        _health = health,
        _fenceRetry = fenceRetry ?? AccountFenceRetry(),
        _db = db,
        _recorder = recorder ?? const SupabaseEngagementRecorder(),
        _isSyncEnabled = isSyncEnabled ?? (() => SupabaseConfig.isConfigured),
        _getAuthUserId = getAuthUserId ?? _defaultGetAuthUserId;

  final AppDatabase _db;
  final EngagementRemoteRecorder _recorder;
  final bool Function() _isSyncEnabled;
  final Future<String?> Function() _getAuthUserId;
  final Future<bool> Function() _mayEgress;
  final SyncHealth? _health;
  final AccountFenceRetry _fenceRetry;
  bool _busy = false;

  static Future<bool> _denyEgressByDefault() async => false;

  static Future<String?> _defaultGetAuthUserId() async {
    if (!SupabaseConfig.isConfigured) return null;
    try {
      return Supabase.instance.client.auth.currentUser?.id;
    } catch (_) {
      return null;
    }
  }

  /// Records a local engagement event. Idempotent by [eventId] (a replay of the
  /// same id is a no-op locally) and, when given, by [businessKey] (a second
  /// event for the same business action is dropped) — so a duplicate domain
  /// action never produces a duplicate award or notification-trigger record.
  Future<void> enqueue({
    required String eventType,
    DateTime? occurredAt,
    String? businessKey,
    String? eventId,
  }) async {
    final id = eventId ?? IdGenerator.next();
    final now = dateTimeToSql(DateTime.now().toUtc());
    final occurred = dateTimeToSql((occurredAt ?? DateTime.now()).toUtc());
    // Drop a duplicate business action (same business_key still unsynced/awarded)
    // before inserting — no double state mutation.
    if (businessKey != null) {
      final dup = await _db
          .customSelect(
            'SELECT event_id FROM engagement_events '
            'WHERE business_key = ${sqlString(businessKey)} LIMIT 1;',
          )
          .getSingleOrNull();
      if (dup != null) return;
    }
    await _db.customStatement('''
      INSERT OR IGNORE INTO engagement_events(
        event_id, event_type, occurred_at, business_key, event_version,
        status, attempt_count, created_at
      ) VALUES (
        ${sqlString(id)}, ${sqlString(eventType)}, ${sqlString(occurred)},
        ${sqlNullableString(businessKey)}, 1, 'pending', 0, ${sqlString(now)}
      );
    ''');
  }

  /// Submits pending events to the server exactly once. On acknowledgement the
  /// event is marked synced and the ACKNOWLEDGED aggregate is stored locally
  /// (never a client-invented total). Typed errors → bounded retry / dead-letter.
  Future<int> push() => pushWithPhase(SyncPhaseBinding());

  Future<int> pushWithPhase(SyncPhaseBinding phase) async {
    if (_busy) throw const EngagementDeliveryStopped(EngagementDeliveryStopReason.overlap);
    _busy = true;
    final inherited = phase.isBound ? phase : null;
    void supplied() {
      if (inherited != null && (!inherited.isCurrent || !identical(inherited.database, _db))) {
        throw const EngagementDeliveryStopped(EngagementDeliveryStopReason.stale);
      }
    }
    try {
      supplied();
      final authority = AccountFenceAuthority.shared;
      final handle = await authority.captureForDatabase(AppSession.instance, _db);
      supplied();
      if (handle == null) throw const EngagementDeliveryStopped(EngagementDeliveryStopReason.unbound);
      final invocation = _EngagementInvocation(authority, handle, _db, inherited);
      if (!phase.isBound) phase.bind(invocation);
      invocation.requireCurrent();
      if (!_isSyncEnabled()) return 0;
      final uid = await _getAuthUserId();
      invocation.requireCurrent();
      if (uid != authority.ownerUid(handle)) {
        throw const EngagementDeliveryStopped(EngagementDeliveryStopReason.stale);
      }
      final allowed = await _mayEgress();
      invocation.requireCurrent();
      if (!allowed) { phase.noteConsentBlocked(_health); return 0; }
      final pending = await invocation.runLocal(() => _db.transaction(() => _db.customSelect(
        "SELECT * FROM engagement_events WHERE status='pending' "
        'AND attempt_count < $kOutboxMaxAttempts;',
      ).get()));
      invocation.requireCurrent();
      var synced = 0;
      for (final row in pending) {
        invocation.requireCurrent();
        final edit = _EngagementEdit(row.read<String>('event_id'), row.read<String>('event_type'),
            row.read<String>('occurred_at'), row.readNullable<String>('business_key'),
            row.read<int>('event_version'), row.read<int>('attempt_count'),
            row.readNullable<String>('failure_class'));
        final intent = await authority.captureEngagementIntent(handle, _db,
            eventId: edit.id, eventType: edit.type, occurredAt: edit.occurredAt,
            businessKey: edit.businessKey, eventVersion: edit.version);
        invocation.requireCurrent();
        if (intent == null) continue;
        final context = _EngagementRemoteContext(invocation, intent);
        try {
          final ack = await _fenceRetry.runItem(
            isCurrent: () => _retryCurrent(invocation, edit, uid!),
            body: () => retryAccountFenceMutation(() {
              invocation.requireCurrent();
              return runZoned(() => _recorder.record(eventId: edit.id, eventType: edit.type,
                  occurredAt: edit.occurredAt, businessKey: edit.businessKey, eventVersion: edit.version),
                  zoneValues: {_engagementRemoteKey: context});
            }),
          );
          invocation.requireCurrent();
          if (await _finishEvent(invocation, edit, ack: ack)) synced++;
        } on _EngagementMutationRefusal catch (refusal) {
          if (!identical(refusal.context, context)) {
            throw const EngagementDeliveryStopped(EngagementDeliveryStopReason.provenance);
          }
          final result = await authority.acceptEngagementDenial(handle, _db, intent,
              decodeEngagementAccountDenial(refusal.raw)!);
          throw EngagementDeliveryStopped(EngagementDeliveryStopReason.denial,
              accepted: result.accepted, complete: result.complete);
        } on AccountFenceDeliveryCancellation { rethrow; }
        on AccountFenceRetryStopped {
          throw const EngagementDeliveryStopped(EngagementDeliveryStopReason.stale);
        } catch (error) {
          if (decodeEngagementAccountDenial(error) != null) {
            throw const EngagementDeliveryStopped(EngagementDeliveryStopReason.nonMutationRefusal);
          }
          invocation.requireCurrent();
          final contention = error is PostgrestException && error.code == '55P03';
          final matched = await _finishEvent(invocation, edit, error: error, contention: contention);
          if (matched) phase.noteFailure(_health, error);
          if (kDebugMode) debugPrint('[Engagement] push failed: $error');
        }
      }
      invocation.requireCurrent();
      return synced;
    } on StaleAdmissionException {
      throw const EngagementDeliveryStopped(EngagementDeliveryStopReason.stale);
    } finally { _busy = false; }
  }

  Future<bool> _retryCurrent(_EngagementInvocation invocation, _EngagementEdit edit, String uid) async {
    invocation.requireCurrent();
    final current = await _getAuthUserId();
    invocation.requireCurrent();
    if (current != uid || !_isSyncEnabled()) return false;
    final allowed = await _mayEgress();
    invocation.requireCurrent();
    if (!allowed) return false;
    final held = await invocation.runLocal(() => _db.transaction(() async =>
        await _db.customSelect('SELECT 1 FROM engagement_events WHERE ${edit.predicate};')
            .getSingleOrNull() != null));
    invocation.requireCurrent();
    return held;
  }

  Future<bool> _finishEvent(_EngagementInvocation invocation, _EngagementEdit edit,
      {EngagementAck? ack, Object? error, bool contention = false}) async {
    invocation.requireCurrent();
    final matched = await invocation.runLocal(() => _db.transaction(() async {
      if (await _db.customSelect('SELECT 1 FROM engagement_events WHERE ${edit.predicate};')
          .getSingleOrNull() == null) { return false; }
      if (ack != null) {
        await _db.customStatement("UPDATE engagement_events SET status='synced', "
            'synced_at=${sqlString(dateTimeToSql(_fenceRetry.clock().toUtc()))} WHERE ${edit.predicate};');
        await _storeAcknowledgedAggregate(ack);
      } else if (!contention) {
        await _markFailure(edit.id, classifyOutboxError(error!));
      }
      return true;
    }));
    invocation.requireCurrent();
    return matched;
  }

  /// The displayed state: acknowledged server aggregate + projection of pending
  /// events. Never writes the aggregate.
  Future<EngagementProjection> projection() async {
    final agg = await _db
        .customSelect('SELECT total_xp, level FROM xp_levels LIMIT 1;')
        .getSingleOrNull();
    final ackXp = agg?.readNullable<int>('total_xp') ?? 0;
    final ackLevel = agg?.readNullable<int>('level') ?? 1;

    final pending = await _db
        .customSelect(
          "SELECT event_type FROM engagement_events WHERE status = 'pending';",
        )
        .get();
    var projected = ackXp;
    for (final row in pending) {
      projected += projectedAwardFor(row.read<String>('event_type'));
    }
    return EngagementProjection(
      acknowledgedXp: ackXp,
      acknowledgedLevel: ackLevel,
      pendingCount: pending.length,
      projectedXp: projected,
    );
  }

  /// Re-arm dead-lettered events after a compatible app upgrade.
  Future<int> reArmDeadLetter() async {
    final rows = await _db.customSelect(
      "SELECT COUNT(*) AS n FROM engagement_events WHERE status = 'dead';",
    ).getSingle();
    await _db.customStatement(
      "UPDATE engagement_events SET status = 'pending', attempt_count = 0, "
      "failure_class = NULL WHERE status = 'dead';",
    );
    return rows.read<int>('n');
  }

  Future<int> deadLetterCount() async => (await _db
          .customSelect(
              "SELECT COUNT(*) AS n FROM engagement_events WHERE status = 'dead';")
          .getSingle())
      .read<int>('n');

  Future<void> _storeAcknowledgedAggregate(EngagementAck ack) async {
    // Store the ACKNOWLEDGED server aggregate as the authoritative local value.
    // xp_levels is a singleton row (seeded with a generated id), so a bare
    // UPDATE targets it without depending on a specific id.
    await _db.customStatement(
      'UPDATE xp_levels SET total_xp = ${ack.xp}, level = ${ack.level};',
    );
  }

  Future<void> _markFailure(String eventId, OutboxFailureClass failure) async {
    // A-5: an auth rejection never consumes an attempt — the event stays pending
    // and is retried once the session is valid again.
    if (failure == OutboxFailureClass.auth) return;
    // Permanent failures dead-letter immediately; transient ones increment the
    // attempt counter and dead-letter once the bound is reached.
    if (failure.isPermanent) {
      await _db.customStatement(
        "UPDATE engagement_events SET status = 'dead', "
        'failure_class = ${sqlString(failure.name)} '
        'WHERE event_id = ${sqlString(eventId)};',
      );
      return;
    }
    await _db.customStatement('''
      UPDATE engagement_events
      SET attempt_count = attempt_count + 1,
          failure_class = ${sqlString(failure.name)},
          status = CASE WHEN attempt_count + 1 >= $kOutboxMaxAttempts
                        THEN 'dead' ELSE 'pending' END
      WHERE event_id = ${sqlString(eventId)};
    ''');
  }
}

class _EngagementEdit {
  const _EngagementEdit(this.id, this.type, this.occurredAt, this.businessKey,
      this.version, this.attempts, this.failure);
  final String id, type, occurredAt;
  final String? businessKey, failure;
  final int version, attempts;
  String get predicate => 'event_id=${sqlString(id)} AND event_type=${sqlString(type)} '
      'AND occurred_at=${sqlString(occurredAt)} AND business_key IS ${sqlNullableString(businessKey)} '
      "AND event_version=$version AND status='pending' AND attempt_count=$attempts "
      'AND failure_class IS ${sqlNullableString(failure)}';
}
class _EngagementInvocation implements SyncPhaseLifecycle {
  _EngagementInvocation(this.authority, this.handle, this.database, this.inherited);
  final AccountFenceAuthority authority;
  final AccountFenceHandle handle;
  @override
  final AppDatabase database;
  final SyncPhaseBinding? inherited;
  @override
  bool get isCurrent => authority.isCurrentForDatabase(handle, database) &&
      (inherited == null || inherited!.isCurrent);
  void requireCurrent() {
    if (!isCurrent) throw const EngagementDeliveryStopped(EngagementDeliveryStopReason.stale);
  }
  @override
  Future<T> runLocal<T>(Future<T> Function() action) {
    requireCurrent();
    return authority.runCurrentLocal(handle, database, action);
  }
}
const _engagementRemoteKey = #engagementMutation;
class _EngagementRemoteContext {
  const _EngagementRemoteContext(this.invocation, this.intent);
  final _EngagementInvocation invocation;
  final AccountFenceEngagementIntent intent;
}
class _EngagementMutationRefusal implements Exception {
  const _EngagementMutationRefusal(this.context, this.raw);
  final _EngagementRemoteContext context;
  final PostgrestException raw;
}
