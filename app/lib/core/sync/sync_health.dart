import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart'
    show AuthException, PostgrestException;

import '../../data/db/app_database.dart';
import '../../data/db/sql_value_codec.dart';
import '../di/app_providers.dart' show appDatabaseProvider;
import 'outbox_failure.dart';

/// Every independently-synced data domain.
enum SyncDomain {
  ledger,
  planning,
  accounts,
  children,
  senderMappings,
  smartInbox,
  engagement,
}

enum SyncDirection { push, pull }

/// Coarse failure class. Deliberately a closed enum with NO message payload:
/// raw error text can carry user data (amounts, merchant names, emails), so it
/// must never be stored or surfaced.
enum SyncErrorClass {
  offline,
  auth,

  /// Cloud consent is off — a STATE, not a failure.
  consentBlocked,

  /// Held durably until an exact-transport capability is verified — a STATE.
  capabilityParked,
  serverRejected,
  conflict,
  unknown;

  /// States that resolve on their own (consent granted / capability verified)
  /// and therefore do not count as failures.
  bool get isBlockedState =>
      this == consentBlocked || this == capabilityParked;

  /// Coarse classification that NEVER reads or retains the error message.
  static SyncErrorClass classify(Object error) {
    if (error is SocketException ||
        error is HttpException ||
        error is TimeoutException) {
      return offline;
    }
    if (error is AuthException) return auth;
    if (error is PostgrestException) {
      switch (classifyOutboxError(error)) {
        case OutboxFailureClass.auth:
          return auth;
        case OutboxFailureClass.conflict:
          return conflict;
        case OutboxFailureClass.transientNetwork:
          return offline;
        case OutboxFailureClass.rateLimit:
        case OutboxFailureClass.serverError:
        case OutboxFailureClass.permanentValidation:
        case OutboxFailureClass.unsupportedSchema:
        case OutboxFailureClass.corruptedPayload:
          return serverRejected;
        case OutboxFailureClass.missingDependency:
          return unknown;
      }
    }
    return unknown;
  }
}

/// Immutable per-domain snapshot.
class SyncDomainHealth {
  const SyncDomainHealth({
    this.lastPushSuccessAt,
    this.lastPullSuccessAt,
    this.lastErrorAt,
    this.lastErrorClass,
    this.consecutiveFailures = 0,
  });

  final DateTime? lastPushSuccessAt;
  final DateTime? lastPullSuccessAt;
  final DateTime? lastErrorAt;
  final SyncErrorClass? lastErrorClass;
  final int consecutiveFailures;

  Map<String, dynamic> toJson() => {
        if (lastPushSuccessAt != null)
          'push': lastPushSuccessAt!.toUtc().toIso8601String(),
        if (lastPullSuccessAt != null)
          'pull': lastPullSuccessAt!.toUtc().toIso8601String(),
        if (lastErrorAt != null)
          'errAt': lastErrorAt!.toUtc().toIso8601String(),
        if (lastErrorClass != null) 'errClass': lastErrorClass!.name,
        'fails': consecutiveFailures,
      };

  static SyncDomainHealth fromJson(Map<String, dynamic> j) {
    DateTime? t(Object? v) => v is String ? DateTime.tryParse(v) : null;
    SyncErrorClass? c;
    final name = j['errClass'];
    for (final v in SyncErrorClass.values) {
      if (v.name == name) c = v;
    }
    return SyncDomainHealth(
      lastPushSuccessAt: t(j['push']),
      lastPullSuccessAt: t(j['pull']),
      lastErrorAt: t(j['errAt']),
      lastErrorClass: c,
      consecutiveFailures: (j['fails'] as num?)?.toInt() ?? 0,
    );
  }
}

/// Outbox/queue depth, for the health surface. Counts only — no payloads.
class SyncQueueCounts {
  const SyncQueueCounts({
    this.pending = 0,
    this.parked = 0,
    this.deadLetter = 0,
    this.senderMappingsPending = 0,
    this.senderMappingsFailed = 0,
    this.smartInboxPendingSync = 0,
  });

  /// Ledger + planning outbox rows awaiting push.
  final int pending;

  /// Ledger + planning rows held durably for an unverified transport.
  final int parked;

  /// Ledger + planning rows that exhausted retries / failed permanently.
  final int deadLetter;
  final int senderMappingsPending;
  final int senderMappingsFailed;
  final int smartInboxPendingSync;
}

/// Durable, lightweight per-domain sync health.
///
/// Persistence pattern: one `sync_cursors` row per domain, keyed
/// `sync_health:<domain>`, with the JSON snapshot in `last_id`. That table is
/// the app's existing device-local key-value store for sync state: it is
/// wiped on sign-out, excluded from backups and from the financial-revision
/// signal, and needs no schema change.
///
/// Orchestrators wrap each phase in [runPhase]; services that swallow errors or
/// refuse on consent report through [noteConsentBlocked] / [noteFailure] /
/// [noteCapabilityParked] so the enclosing phase records ONE accurate state.
class SyncHealth {
  SyncHealth({DateTime Function()? clock, AppDatabase? db})
      : _clock = clock ?? DateTime.now,
        _db = db;

  /// Process-wide instance used by providers and by non-Riverpod construction
  /// sites (the bootstrap sender-mapping sync). Persists once [attach]ed.
  static final SyncHealth shared = SyncHealth();

  static const _keyPrefix = 'sync_health:';

  final DateTime Function() _clock;
  AppDatabase? _db;
  final Map<SyncDomain, SyncDomainHealth> _state = {};
  final Map<SyncDomain, _PhaseNotes> _notes = {};

  SyncDomainHealth of(SyncDomain d) => _state[d] ?? const SyncDomainHealth();

  Map<SyncDomain, SyncDomainHealth> get all => {
        for (final d in SyncDomain.values) d: of(d),
      };

  /// Binds the persistence target and loads persisted state. Domains already
  /// touched in this process win over the persisted copy.
  Future<void> attach(AppDatabase db) async {
    if (identical(_db, db)) return;
    _db = db;
    try {
      final rows = await db
          .customSelect('SELECT entity, last_id FROM sync_cursors '
              "WHERE entity LIKE 'sync_health:%';")
          .get();
      for (final row in rows) {
        final name = row.read<String>('entity').substring(_keyPrefix.length);
        for (final d in SyncDomain.values) {
          if (d.name != name || _state.containsKey(d)) continue;
          final json = jsonDecode(row.read<String>('last_id')) as Map;
          _state[d] = SyncDomainHealth.fromJson(json.cast<String, dynamic>());
        }
      }
    } catch (_) {
      // Health is diagnostic — a corrupt/unavailable store must never break sync.
    }
  }

  // --- services report into the enclosing phase -----------------------------

  void noteConsentBlocked(SyncDomain d) => _note(d).consentBlocked = true;

  void noteCapabilityParked(SyncDomain d) => _note(d).capabilityParked = true;

  /// Records that a swallowed error happened inside the phase. Only the coarse
  /// class is kept — never the error or its message.
  void noteFailure(SyncDomain d, Object error) =>
      _note(d).failure ??= SyncErrorClass.classify(error);

  _PhaseNotes _note(SyncDomain d) => _notes.putIfAbsent(d, _PhaseNotes.new);

  // --- orchestrators --------------------------------------------------------

  /// Runs [body] as one sync phase and records its outcome:
  /// thrown error -> failure (rethrown only when [rethrowErrors]);
  /// consent denied -> consentBlocked; a swallowed failure noted by the service
  /// -> failure; parked -> capabilityParked; otherwise success.
  Future<T?> runPhase<T>(
    SyncDomain domain,
    SyncDirection direction,
    Future<T> Function() body, {
    bool rethrowErrors = false,
  }) async {
    _notes[domain] = _PhaseNotes();
    try {
      final result = await body();
      final n = _notes[domain]!;
      if (n.consentBlocked) {
        _recordBlocked(domain, SyncErrorClass.consentBlocked);
      } else if (n.failure != null) {
        _recordFailure(domain, n.failure!);
      } else if (n.capabilityParked) {
        _recordBlocked(domain, SyncErrorClass.capabilityParked);
      } else {
        _recordSuccess(domain, direction);
      }
      return result;
    } catch (e) {
      recordFailure(domain, e);
      if (rethrowErrors) rethrow;
      return null;
    } finally {
      _notes.remove(domain);
    }
  }

  void recordFailure(SyncDomain d, Object error) =>
      _recordFailure(d, SyncErrorClass.classify(error));

  void _recordSuccess(SyncDomain d, SyncDirection dir) {
    final s = of(d);
    final now = _clock();
    final clearState = s.lastErrorClass?.isBlockedState ?? false;
    _state[d] = SyncDomainHealth(
      lastPushSuccessAt: dir == SyncDirection.push ? now : s.lastPushSuccessAt,
      lastPullSuccessAt: dir == SyncDirection.pull ? now : s.lastPullSuccessAt,
      lastErrorAt: clearState ? null : s.lastErrorAt,
      lastErrorClass: clearState ? null : s.lastErrorClass,
      consecutiveFailures: 0,
    );
    _save(d);
  }

  void _recordFailure(SyncDomain d, SyncErrorClass c) {
    final s = of(d);
    _state[d] = SyncDomainHealth(
      lastPushSuccessAt: s.lastPushSuccessAt,
      lastPullSuccessAt: s.lastPullSuccessAt,
      lastErrorAt: _clock(),
      lastErrorClass: c,
      consecutiveFailures: s.consecutiveFailures + 1,
    );
    _save(d);
  }

  /// A blocked state is ONE state: re-entering it repeatedly neither bumps the
  /// failure counter nor rewrites the timestamp.
  void _recordBlocked(SyncDomain d, SyncErrorClass c) {
    final s = of(d);
    if (s.lastErrorClass == c) return;
    _state[d] = SyncDomainHealth(
      lastPushSuccessAt: s.lastPushSuccessAt,
      lastPullSuccessAt: s.lastPullSuccessAt,
      lastErrorAt: _clock(),
      lastErrorClass: c,
      consecutiveFailures: s.consecutiveFailures,
    );
    _save(d);
  }

  void _save(SyncDomain d) {
    final db = _db;
    if (db == null) return;
    unawaited(() async {
      try {
        await db.customStatement(
          'INSERT INTO sync_cursors(entity, last_updated_at, last_id) VALUES ('
          '${sqlString('$_keyPrefix${d.name}')}, '
          '${sqlString(_clock().toUtc().toIso8601String())}, '
          '${sqlString(jsonEncode(of(d).toJson()))}) '
          'ON CONFLICT(entity) DO UPDATE SET '
          'last_updated_at = excluded.last_updated_at, '
          'last_id = excluded.last_id;',
        );
      } catch (e) {
        if (kDebugMode) {
          debugPrint('[SyncHealth] persist failed: ${e.runtimeType}');
        }
      }
    }());
  }

  /// Outbox depth for the health surface. Raw counts only.
  static Future<SyncQueueCounts> queueCounts(AppDatabase db) async {
    Future<int> n(String sql) async =>
        (await db.customSelect(sql).getSingle()).read<int>('n');
    Future<int> outbox(String status) async =>
        await n("SELECT COUNT(*) AS n FROM ledger_sync_outbox "
            "WHERE status = '$status'") +
        await n("SELECT COUNT(*) AS n FROM planning_sync_outbox "
            "WHERE status = '$status'");
    return SyncQueueCounts(
      pending: await outbox('pending'),
      parked: await outbox('parked'),
      deadLetter: await outbox('dead_letter'),
      senderMappingsPending: await n("SELECT COUNT(*) AS n FROM "
          "sender_bank_mappings WHERE sync_status = 'pending'"),
      senderMappingsFailed: await n("SELECT COUNT(*) AS n FROM "
          "sender_bank_mappings WHERE sync_status = 'failed'"),
      smartInboxPendingSync: await n(
          'SELECT COUNT(*) AS n FROM smart_inbox_items WHERE pending_sync = 1'),
    );
  }
}

class _PhaseNotes {
  bool consentBlocked = false;
  bool capabilityParked = false;
  SyncErrorClass? failure;
}

final syncHealthProvider = Provider<SyncHealth>((ref) {
  final health = SyncHealth.shared;
  unawaited(health.attach(ref.watch(appDatabaseProvider)));
  return health;
});
