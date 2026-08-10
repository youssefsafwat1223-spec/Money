import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/sync/outbox_failure.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/repositories/drift_account_repository.dart';
import 'package:money_companion/data/repositories/drift_goal_repository.dart';
import 'package:money_companion/domain/entities/account_entity.dart';
import 'package:money_companion/domain/entities/goal_entity.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/features/planning_sync/services/accounts_push_service.dart';
import 'package:money_companion/features/planning_sync/services/planning_outbox_queue.dart';
import 'package:money_companion/features/planning_sync/services/planning_push_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show PostgrestException;

// MALI-022 / 0068 — client revision compare-and-set contract tests. The
// capability ships OFF (kServerRevisionCas=false); here it is injected ON to
// exercise the dormant CAS path. Covers OFF, ON-supported, ON-unsupported, old
// payloads (null revision), conflicts, and the accounts blind-overwrite fix.

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'test-key';
  @override
  Future<String?> readStoredKey() async => 'test-key';
}

/// A planning sink with real revision semantics + call counters.
class _CasSink implements PlanningRemoteSink {
  _CasSink({this.serverRevision = 1, this.unsupported = false});

  int serverRevision;
  bool unsupported; // simulate a server without 0068 (revision column absent)
  // Matches the seeded base by default, so the guarded (OFF) path sees the
  // server as unchanged and proceeds to a normal update rather than a conflict.
  String serverUpdatedAt = 'base-ts';
  int casCalls = 0;
  int guardedUpdateCalls = 0;

  @override
  Future<Map<String, dynamic>> upsert(String t, Map<String, dynamic> r) async =>
      {'id': 'srv-${r['local_id']}', 'updated_at': serverUpdatedAt, 'revision': serverRevision};

  @override
  Future<String?> fetchServerUpdatedAt(String t, String s) async =>
      serverUpdatedAt;

  @override
  Future<Map<String, dynamic>?> findByLocalId(String t, String u, String l) async =>
      null;

  @override
  Future<void> tombstone(String t, String s) async {}

  @override
  Future<Map<String, dynamic>> updateByServerId(
      String t, String s, Map<String, dynamic> r) async {
    guardedUpdateCalls++;
    serverUpdatedAt = 'guarded-ts';
    return {'id': s, 'updated_at': serverUpdatedAt, 'revision': serverRevision};
  }

  @override
  Future<Map<String, dynamic>?> casUpdateByServerId(
      String t, String s, int expectedRevision, Map<String, dynamic> r) async {
    casCalls++;
    if (unsupported) {
      throw const PostgrestException(
          message: 'column "revision" does not exist', code: '42703');
    }
    if (expectedRevision != serverRevision) return null; // stale → conflict
    serverRevision += 1;
    serverUpdatedAt = 'cas-ts-$serverRevision';
    return {'id': s, 'updated_at': serverUpdatedAt, 'revision': serverRevision};
  }
}

GoalEntity _goal() => GoalEntity(
      id: 'g1',
      name: 'Travel',
      targetAmount: 5000,
      savedAmount: 300,
      vaultSkin: 'classic',
      status: 'active',
      createdAt: DateTime.utc(2026, 7, 1),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  late PlanningOutboxQueue queue;

  setUp(() async {
    db = await AppDatabase.open(
      executor: NativeDatabase.memory(),
      keyStore: _MemoryKeyStore(),
    );
    queue = PlanningOutboxQueue(
      db: db,
      isSyncEnabled: (_) => true,
      getAuthUserId: () async => 'user-1',
    );
  });
  tearDown(() => db.close());

  // Seeds a synced goal at [revision] (null = old row, revision unknown) and
  // enqueues an update, so the outbox payload carries the base revision.
  Future<void> seedAndEnqueue({int? revision}) async {
    await DriftGoalRepository(db, outboxQueue: queue).save(_goal());
    await db.customStatement('DELETE FROM planning_sync_outbox;');
    await db.customStatement(
      "UPDATE goals SET server_id = 'srv-g1', server_updated_at = 'base-ts', "
      "server_revision = ${revision ?? 'NULL'}, sync_status = 'synced' "
      "WHERE id = 'g1';",
    );
    final g = await DriftGoalRepository(db, outboxQueue: queue).getById('g1');
    await queue.enqueueGoal(PlanningSyncOperation.update, g!);
  }

  Future<String?> goalStatus() async => (await db
          .customSelect("SELECT sync_status FROM goals WHERE id='g1';")
          .getSingle())
      .readNullable<String>('sync_status');

  Future<int?> goalRevision() async => (await db
          .customSelect("SELECT server_revision FROM goals WHERE id='g1';")
          .getSingle())
      .readNullable<int>('server_revision');

  PlanningPushService push(_CasSink sink, {required bool casEnabled}) =>
      PlanningPushService(
        db: db,
        queue: queue,
        isEnabled: (_) => true,
        getAuthUserId: () async => 'user-1',
        remoteSink: sink,
        revisionCasEnabled: casEnabled,
      );

  group('planning revision CAS', () {
    test('OFF: uses the guarded timestamp path, never the CAS (even with a '
        'base revision present)', () async {
      await seedAndEnqueue(revision: 5);
      final sink = _CasSink(serverRevision: 5);
      final r = await push(sink, casEnabled: false).push();
      expect(r.pushed, 1);
      expect(sink.casCalls, 0, reason: 'CAS must not run when the capability is off');
      expect(sink.guardedUpdateCalls, 1);
      expect(await goalStatus(), 'synced');
    });

    test('ON + matching revision: atomic CAS applies and the ack stores the new '
        'revision', () async {
      await seedAndEnqueue(revision: 5);
      final sink = _CasSink(serverRevision: 5);
      final r = await push(sink, casEnabled: true).push();
      expect(r.pushed, 1);
      expect(sink.casCalls, 1);
      expect(sink.guardedUpdateCalls, 0);
      expect(await goalStatus(), 'synced');
      expect(await goalRevision(), 6, reason: 'acknowledged new revision stored');
    });

    test('ON + stale revision: zero-row CAS becomes a typed conflict, no '
        'overwrite (also the crash-after-acceptance case)', () async {
      await seedAndEnqueue(revision: 5);
      // Server has already moved to revision 9 (another device, or our own
      // write that we crashed before acknowledging).
      final sink = _CasSink(serverRevision: 9);
      final r = await push(sink, casEnabled: true).push();
      expect(r.conflicts, 1);
      expect(r.pushed, 0);
      expect(sink.casCalls, 1);
      expect(sink.guardedUpdateCalls, 0, reason: 'never a blind fallback write');
      expect(await goalStatus(), 'conflict');
    });

    test('ON + null base revision (old payload): falls back to the guarded '
        'path, never a blind overwrite', () async {
      await seedAndEnqueue(revision: null); // pre-0068 row, revision unknown
      final sink = _CasSink(serverRevision: 5);
      final r = await push(sink, casEnabled: true).push();
      expect(r.pushed, 1);
      expect(sink.casCalls, 0, reason: 'no base revision → cannot CAS');
      expect(sink.guardedUpdateCalls, 1, reason: 'guarded compare, not blind');
      expect(await goalStatus(), 'synced');
    });

    test('ON-unsupported (server lacks the revision column): fails safe — the '
        'row is not marked synced and is not overwritten', () async {
      await seedAndEnqueue(revision: 5);
      final sink = _CasSink(serverRevision: 5, unsupported: true);
      final r = await push(sink, casEnabled: true).push();
      expect(r.failed, 1);
      expect(r.pushed, 0);
      expect(sink.guardedUpdateCalls, 0, reason: 'error must not fall through to a write');
      // The outbox item was dead-lettered as an unsupported-schema failure.
      final dead = (await db
              .customSelect(
                  "SELECT failure_class FROM planning_sync_outbox WHERE entity_id='g1';")
              .getSingle())
          .readNullable<String>('failure_class');
      expect(dead, OutboxFailureClass.unsupportedSchema.name);
      expect(await goalStatus(), isNot('synced'));
    });
  });

  group('accounts fail-safe (blind-overwrite fix)', () {
    test('OFF update of a synced account guards on updated_at instead of '
        'blindly upserting', () async {
      final repo = DriftAccountRepository(db, outboxQueue: queue);
      final now = DateTime.utc(2026, 7, 4, 12);
      await repo.create(AccountEntity(
        id: 'a1',
        name: 'Bank',
        currency: 'SAR',
        type: AccountType.bank,
        isDefault: false,
        sortOrder: 1,
        createdAt: now,
        updatedAt: now,
        initialBalanceMoney: Money.fromLegacyReal(100, 'SAR'),
        currentBalanceMoney: Money.fromLegacyReal(100, 'SAR'),
      ));
      // Mark it synced against a base the server has since moved past, then
      // enqueue an update (its payload captures the 'base-ts' base token).
      await db.customStatement('DELETE FROM planning_sync_outbox;');
      await db.customStatement(
        "UPDATE accounts SET server_id = 'srv-a1', server_updated_at = 'base-ts', "
        "sync_status = 'synced' WHERE id = 'a1';",
      );
      final a = await repo.getById('a1');
      await queue.enqueueAccount(PlanningSyncOperation.update, a!);

      // Server moved past our base — a blind upsert would clobber it; the
      // guarded path must flag a conflict instead.
      final sink = _CasAccountsSink(currentUpdatedAt: 'moved-ts');
      final r = await AccountsPushService(
        db: db,
        queue: queue,
        isEnabled: () => true,
        getAuthUserId: () async => 'user-1',
        remoteSink: sink,
        revisionCasEnabled: false,
      ).push();

      expect(r.conflicts, 1);
      expect(sink.upserts, 0, reason: 'an existing account must not be re-upserted');
      final status = (await db
              .customSelect("SELECT sync_status FROM accounts WHERE id='a1';")
              .getSingle())
          .readNullable<String>('sync_status');
      expect(status, 'conflict');
    });
  });
}

/// Accounts sink for the guarded-path fail-safe test.
class _CasAccountsSink implements AccountsRemoteSink {
  _CasAccountsSink({required this.currentUpdatedAt});
  final String currentUpdatedAt;
  int upserts = 0;

  @override
  Future<Map<String, dynamic>> upsertAccount(Map<String, dynamic> row) async {
    upserts++;
    return {'id': 'srv-${row['local_id']}', 'updated_at': currentUpdatedAt};
  }

  @override
  Future<Map<String, dynamic>?> findAccountByLocalId(String u, String id) async =>
      null;

  @override
  Future<void> tombstoneAccount(String s) async {}

  @override
  Future<String?> fetchAccountUpdatedAt(String s) async => currentUpdatedAt;

  @override
  Future<Map<String, dynamic>> updateAccountByServerId(
          String s, Map<String, dynamic> r) async =>
      {'id': s, 'updated_at': currentUpdatedAt};

  @override
  Future<Map<String, dynamic>?> casUpdateAccount(
          String s, int expectedRevision, Map<String, dynamic> r) async =>
      {'id': s, 'updated_at': currentUpdatedAt, 'revision': expectedRevision + 1};

  @override
  Future<void> setDefaultAccount(String s) async {}
}
