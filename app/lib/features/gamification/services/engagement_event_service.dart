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
  return EngagementEventService(db: ref.watch(appDatabaseProvider));
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
    final res = await Supabase.instance.client.rpc<dynamic>(
      'record_engagement_event',
      params: {
        'p_event_id': eventId,
        'p_event_type': eventType,
        'p_occurred_at': occurredAt,
        'p_business_key': businessKey,
        'p_event_version': eventVersion,
      },
    );
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
  })  : _db = db,
        _recorder = recorder ?? const SupabaseEngagementRecorder(),
        _isSyncEnabled = isSyncEnabled ?? (() => SupabaseConfig.isConfigured),
        _getAuthUserId = getAuthUserId ?? _defaultGetAuthUserId;

  final AppDatabase _db;
  final EngagementRemoteRecorder _recorder;
  final bool Function() _isSyncEnabled;
  final Future<String?> Function() _getAuthUserId;

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
  Future<int> push() async {
    if (!_isSyncEnabled()) return 0;
    if (await _getAuthUserId() == null) return 0;

    final now = dateTimeToSql(DateTime.now().toUtc());
    final pending = await _db.customSelect(
      "SELECT event_id, event_type, occurred_at, business_key, event_version "
      "FROM engagement_events WHERE status = 'pending' "
      'AND (attempt_count < $kOutboxMaxAttempts);',
    ).get();

    var synced = 0;
    for (final row in pending) {
      final eventId = row.read<String>('event_id');
      try {
        final ack = await _recorder.record(
          eventId: eventId,
          eventType: row.read<String>('event_type'),
          occurredAt: row.read<String>('occurred_at'),
          businessKey: row.readNullable<String>('business_key'),
          eventVersion: row.read<int>('event_version'),
        );
        // Exactly-once ack: mark synced (removes it from the pending projection)
        // and store the acknowledged server aggregate.
        await _db.customStatement(
          "UPDATE engagement_events SET status = 'synced', "
          'synced_at = ${sqlString(now)} WHERE event_id = ${sqlString(eventId)};',
        );
        await _storeAcknowledgedAggregate(ack);
        synced++;
      } catch (e) {
        final failure = classifyOutboxError(e);
        // A permanent/validation error (unknown type, unsupported version) or an
        // exhausted retry dead-letters; otherwise it stays pending for retry.
        await _markFailure(eventId, failure);
        if (kDebugMode) {
          debugPrint('[Engagement] push failed (${failure.name}): $e');
        }
      }
    }
    return synced;
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
