import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/sync/outbox_failure.dart';
import 'package:money_companion/core/sync/sync_health.dart';
import 'package:money_companion/core/sync/sync_pull_proof.dart';
import 'package:money_companion/core/sync/sync_status.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/sync/seq_pull.dart';
import 'package:money_companion/data/sync/server_capabilities.dart';
import 'package:money_companion/data/sync/sync_cursor.dart';

// WP-8: the status derivation table for every state (SYNC_PLAN §13), the head
// proof for "All data synced", and the sync-plan tests that surface as a status
// (T5, T13, T14, T15, T16, T17).

final _t0 = DateTime.utc(2026, 6, 1, 10);
final _t1 = DateTime.utc(2026, 6, 1, 11);

Map<SyncDomain, SyncDomainHealth> _health({DateTime? push}) => {
      for (final d in SyncDomain.values)
        d: SyncDomainHealth(lastPushSuccessAt: push, lastPullSuccessAt: push),
    };

SyncStatus _derive({
  SyncQueueCounts counts = const SyncQueueCounts(),
  Map<SyncDomain, SyncDomainHealth>? health,
  bool consent = true,
  SyncIdentity identity = SyncIdentity.authenticated,
  bool running = false,
  SyncPullProof pull = SyncPullProof.notApplicable,
}) =>
    SyncStatus.derive(
      counts: counts,
      health: health ?? _health(push: _t1),
      cloudConsent: consent,
      identity: identity,
      syncRunning: running,
      pull: pull,
    );

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'k';
  @override
  Future<String?> readStoredKey() async => 'k';
}

void main() {
  group('derivation table, one row per state (plan §13)', () {
    final table = <String, (SyncStatus, SyncStatusKind)>{
      'clean, push-proven, pull proven':
          (_derive(pull: SyncPullProof.proven), SyncStatusKind.allSynced),
      'clean, flags/capabilities false (no pull proof)':
          (_derive(), SyncStatusKind.allSynced),
      'run in progress': (_derive(running: true), SyncStatusKind.syncing),
      'queued ops': (
        _derive(counts: const SyncQueueCounts(pending: 2)),
        SyncStatusKind.waiting
      ),
      'conflict': (
        _derive(counts: const SyncQueueCounts(conflicts: 1)),
        SyncStatusKind.needsAttention
      ),
      'quarantined pulled row': (
        _derive(counts: const SyncQueueCounts(quarantined: 1)),
        SyncStatusKind.needsAttention
      ),
      'epoch break without rebootstrap': (
        _derive(pull: SyncPullProof.stoppedEpoch),
        SyncStatusKind.needsAttention
      ),
      'dead letter': (
        _derive(counts: const SyncQueueCounts(deadLetter: 1)),
        SyncStatusKind.failed
      ),
      'cloud sync paused (consent off)':
          (_derive(consent: false), SyncStatusKind.consentOff),
      'signed out': (
        _derive(identity: SyncIdentity.signedOut),
        SyncStatusKind.signedOut
      ),
    };
    table.forEach((name, row) {
      test(name, () => expect(row.$1.kind, row.$2));
    });

    test('conflict + quarantine + epoch count into needsAttention', () {
      final s = _derive(
        counts: const SyncQueueCounts(conflicts: 2, quarantined: 3),
        pull: SyncPullProof.stoppedEpoch,
      );
      expect(s.kind, SyncStatusKind.needsAttention);
      expect(s.count, 6);
      expect(s.needsAttention, 6);
      expect(s.canRetry, isTrue);
    });

    test('a failed (retry exhausted) item outranks a decision', () {
      final s = _derive(
          counts: const SyncQueueCounts(deadLetter: 1, conflicts: 1));
      expect(s.kind, SyncStatusKind.failed);
      expect(s.needsAttention, 2);
    });

    test('consent off / signed out are never overridden by pull state', () {
      for (final pull in SyncPullProof.values) {
        expect(_derive(consent: false, pull: pull).kind,
            SyncStatusKind.consentOff);
        expect(_derive(identity: SyncIdentity.guest, pull: pull).kind,
            SyncStatusKind.signedOut);
      }
    });
  });

  group('head-proven "All data synced"', () {
    test('behind the head is never allSynced, whatever the push proof', () {
      expect(_derive(pull: SyncPullProof.behind).kind, SyncStatusKind.waiting);
      expect(_derive(pull: SyncPullProof.stoppedTransient).kind,
          SyncStatusKind.waiting);
    });

    test('a run in progress while behind is the one allowed "Syncing…"', () {
      expect(_derive(pull: SyncPullProof.behind, running: true).kind,
          SyncStatusKind.syncing);
    });

    test('exit criterion: without an active run NO input yields syncing', () {
      const countsShapes = <SyncQueueCounts>[
        SyncQueueCounts(),
        SyncQueueCounts(pending: 1),
        SyncQueueCounts(inFlight: 1),
        SyncQueueCounts(parked: 1, parkedByReason: {kParkAuthRequired: 1}),
        SyncQueueCounts(deadLetter: 1),
        SyncQueueCounts(conflicts: 1),
        SyncQueueCounts(quarantined: 1),
        SyncQueueCounts(networkStalled: 1, pending: 1),
      ];
      for (final counts in countsShapes) {
        for (final pull in SyncPullProof.values) {
          for (final consent in [true, false]) {
            for (final id in SyncIdentity.values) {
              for (final mutated in [null, _t1]) {
                final c = SyncQueueCounts(
                  pending: counts.pending,
                  parked: counts.parked,
                  parkedByReason: counts.parkedByReason,
                  deadLetter: counts.deadLetter,
                  inFlight: counts.inFlight,
                  conflicts: counts.conflicts,
                  quarantined: counts.quarantined,
                  networkStalled: counts.networkStalled,
                  lastLocalMutationAt: mutated,
                );
                final s = _derive(
                  counts: c,
                  consent: consent,
                  identity: id,
                  pull: pull,
                  health: _health(push: _t0),
                );
                expect(s.kind, isNot(SyncStatusKind.syncing),
                    reason: '$counts $pull $consent $id $mutated');
              }
            }
          }
        }
      }
    });

    test('NEVER allSynced with a conflict, quarantine or pull stop', () {
      for (final pull in [
        SyncPullProof.behind,
        SyncPullProof.stoppedTransient,
        SyncPullProof.stoppedEpoch,
      ]) {
        expect(_derive(pull: pull).kind, isNot(SyncStatusKind.allSynced));
      }
      expect(
          _derive(counts: const SyncQueueCounts(quarantined: 1)).kind,
          isNot(SyncStatusKind.allSynced));
    });
  });

  group('sync-plan tests that surface as a status', () {
    test('T5 offline transaction then reconnect: waiting, then all synced', () {
      final offline = _derive(
        counts: SyncQueueCounts(
            pending: 1, networkStalled: 1, lastLocalMutationAt: _t1),
        health: _health(push: _t0),
        running: true,
      );
      expect(offline.kind, SyncStatusKind.waiting);
      final back = _derive(pull: SyncPullProof.proven);
      expect(back.kind, SyncStatusKind.allSynced);
    });

    test('T13 pending ops survive a kill: still waiting, never allSynced', () {
      final s = _derive(counts: const SyncQueueCounts(pending: 2, inFlight: 1));
      expect(s.kind, SyncStatusKind.waiting);
      expect(s.count, 2);
    });

    test('T14 expired token: ops parked auth_required are waiting', () {
      final s = _derive(
          counts: const SyncQueueCounts(
              parked: 3, parkedByReason: {kParkAuthRequired: 3}));
      expect(s.kind, SyncStatusKind.waiting);
      expect(s.waitingForConnection, 3);
    });

    test('T15 server/RLS failure: failed or waiting, never stuck syncing', () {
      final dead = _derive(
          counts: const SyncQueueCounts(
              deadLetter: 1, deadLetterByReason: {'permissionDenied': 1}),
          running: true);
      expect(dead.kind, SyncStatusKind.failed);
      final retrying = _derive(
          counts: const SyncQueueCounts(pending: 1, networkStalled: 1),
          running: true);
      expect(retrying.kind, SyncStatusKind.waiting);
    });

    test('T16 stale replica (epoch bumped): needs attention, not synced', () {
      final s = _derive(pull: SyncPullProof.stoppedEpoch);
      expect(s.kind, SyncStatusKind.needsAttention);
    });

    test('T17 rebootstrap in progress is waiting, then all synced', () {
      expect(_derive(pull: SyncPullProof.stoppedTransient).kind,
          SyncStatusKind.waiting);
      expect(_derive(pull: SyncPullProof.proven).kind,
          SyncStatusKind.allSynced);
    });
  });

  group('SyncHealth.queueCounts reads the WP-4 quarantine', () {
    late AppDatabase db;
    setUp(() async {
      db = await AppDatabase.open(
          executor: NativeDatabase.memory(), keyStore: _MemoryKeyStore());
    });
    tearDown(() async => db.close());

    test('integrity-parked rows are counted, other parks are not', () async {
      Future<void> park(String id, String reason) => db.customStatement(
          'INSERT INTO parked_child_rows(table_name, server_id, row_json, '
          "reason, attempt_count, first_seen_at, updated_at) VALUES "
          "('transactions', '$id', '{}', '$reason', 0, '2026-10-01T00:00:00Z', "
          "'2026-10-01T00:00:00Z');");
      await park('a', 'integrity');
      await park('b', 'integrity');
      await park('c', 'quarantine');
      expect((await SyncHealth.queueCounts(db)).quarantined, 2);
      final s = SyncStatus.derive(
        counts: await SyncHealth.queueCounts(db),
        health: _health(push: _t1),
        cloudConsent: true,
        identity: SyncIdentity.authenticated,
        syncRunning: false,
      );
      expect(s.kind, SyncStatusKind.needsAttention);
    });
  });

  group('deriveSyncPullProof', () {
    late AppDatabase db;
    const uid = 'u-1';
    final obs = SyncPullObservation(headSeq: 10, at: _t1);

    setUp(() async {
      db = await AppDatabase.open(
          executor: NativeDatabase.memory(), keyStore: _MemoryKeyStore());
    });
    tearDown(() async => db.close());

    Future<SyncPullProof> proof({
      ServerCapabilityState cap = ServerCapabilityState.verified,
      SyncPullObservation? observation,
      bool pending = false,
      String? user = uid,
    }) =>
        deriveSyncPullProof(
          db: db,
          uid: user,
          syncSeq: cap,
          observation: observation,
          rebootstrapPending: pending,
        );

    test('capability false / unknown / no uid: not applicable (legacy view)',
        () async {
      for (final cap in [
        ServerCapabilityState.unsupported,
        ServerCapabilityState.unknown
      ]) {
        expect(await proof(cap: cap, observation: obs),
            SyncPullProof.notApplicable);
      }
      expect(await proof(user: null, observation: obs),
          SyncPullProof.notApplicable);
    });

    test('verified: behind until every cursor reached the head', () async {
      expect(await proof(), SyncPullProof.behind, reason: 'no plan yet');
      expect(await proof(observation: obs), SyncPullProof.behind,
          reason: 'no cursor');
      await writeSeqCursor(db, uid, 'transactions', 10);
      await writeSeqCursor(db, uid, 'accounts', 7);
      expect(await proof(observation: obs), SyncPullProof.behind);
      await writeSeqCursor(db, uid, 'accounts', 10);
      expect(await proof(observation: obs), SyncPullProof.proven);
    });

    test('another uid\'s cursors never prove this uid', () async {
      await writeSeqCursor(db, 'other', 'transactions', 10);
      expect(await proof(observation: obs), SyncPullProof.behind);
    });

    test('an empty stream (head 0) is proven', () async {
      expect(
          await proof(observation: SyncPullObservation(headSeq: 0, at: _t1)),
          SyncPullProof.proven);
    });

    test('typed stops map: epoch -> stoppedEpoch, others -> transient',
        () async {
      expect(
          await proof(
              observation: SyncPullObservation(
                  stop: SyncPullStop.epochMismatch, at: _t1)),
          SyncPullProof.stoppedEpoch);
      for (final stop in [
        SyncPullStop.capabilityUnknown,
        SyncPullStop.headUnavailable
      ]) {
        expect(
            await proof(
                observation: SyncPullObservation(stop: stop, at: _t1)),
            SyncPullProof.stoppedTransient);
      }
    });

    test('a rebootstrap marker wins: transient, not an epoch stop', () async {
      expect(
          await proof(
              pending: true,
              observation: SyncPullObservation(
                  stop: SyncPullStop.epochMismatch, at: _t1)),
          SyncPullProof.stoppedTransient);
    });
  });

  group('the gate reports its plan to SyncHealth', () {
    late AppDatabase db;
    setUp(() async {
      db = await AppDatabase.open(
          executor: NativeDatabase.memory(), keyStore: _MemoryKeyStore());
    });
    tearDown(() async => db.close());

    test('head, then epoch mismatch, then capability unknown', () async {
      final remote = _Remote(const SyncHead(lastSeq: 5, epoch: 'e1'));
      var cap = ServerCapabilityState.verified;
      final gate = SeqPullGate(
        db: db,
        capability: () async => cap,
        remote: remote,
        headTtl: Duration.zero,
      );
      final health = SyncHealth.shared;
      await gate.plan('u-1');
      expect(health.pullObservation!.stop, isNull);
      expect(health.pullObservation!.headSeq, 5);

      remote.head = const SyncHead(lastSeq: 6, epoch: 'e2');
      await gate.plan('u-1');
      expect(health.pullObservation!.stop, SyncPullStop.epochMismatch);

      cap = ServerCapabilityState.unknown;
      await gate.plan('u-1');
      expect(health.pullObservation!.stop, SyncPullStop.capabilityUnknown);
    });
  });
}

class _Remote implements SeqRemote {
  _Remote(this.head);
  SyncHead? head;
  @override
  Future<SyncHead?> fetchHead(String userId) async => head;
  @override
  Future<List<Map<String, dynamic>>> fetchRowsBySeq({
    required String table,
    required String userId,
    required int afterSeq,
    required int limit,
    String select = '*',
  }) async =>
      const [];
}
