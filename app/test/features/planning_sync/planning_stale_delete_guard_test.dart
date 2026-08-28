import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
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

// MALI-026 (Phase-9K) — planning + accounts parent tombstones must be GUARDED,
// never an unconditional id-only overwrite. A stale delete replayed against a
// row a newer update advanced past our base must NOT tombstone it. The
// capability ships OFF (kServerRevisionCas=false); injected ON where noted.

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'test-key';
  @override
  Future<String?> readStoredKey() async => 'test-key';
}

/// A sink modelling the server's revision + deleted_at + updated_at semantics
/// for a single row, with call counters. bump_revision fires once per applied
/// tombstone; a mismatched CAS / moved updated_at matches zero rows.
class _DeleteSink implements PlanningRemoteSink {
  _DeleteSink({
    this.exists = true,
    this.revision = 5,
    this.updatedAt = 'base-ts',
    this.deletedAt,
  });

  bool exists;
  int revision;
  String updatedAt;
  String? deletedAt;
  int casTombstones = 0;
  int guardedTombstones = 0;
  int stateFetches = 0;

  @override
  Future<Map<String, dynamic>?> casTombstone(
      String t, String s, int expected) async {
    casTombstones++;
    // WHERE revision=eq → 0 rows when the base moved.
    if (!exists || expected != revision) return null;
    revision += 1; // bump_revision trigger, exactly once
    deletedAt = 'del-ts';
    updatedAt = 'del-ts';
    return {'id': s, 'updated_at': updatedAt, 'revision': revision};
  }

  @override
  Future<Map<String, dynamic>?> guardedTombstone(
      String t, String s, String? expectedUpdatedAt) async {
    guardedTombstones++;
    if (!exists) return null;
    if (expectedUpdatedAt != null) {
      if (updatedAt != expectedUpdatedAt) {
        return null; // advanced
      }
    } else if (deletedAt != null) {
      return null; // deleted_at IS NULL filter fails → already tombstoned
    }
    deletedAt = 'del-ts';
    updatedAt = 'del-ts';
    return {'id': s, 'updated_at': updatedAt};
  }

  @override
  Future<Map<String, dynamic>?> fetchRowState(String t, String s) async {
    stateFetches++;
    if (!exists) return null;
    return {'deleted_at': deletedAt};
  }

  @override
  Future<Map<String, dynamic>?> findByLocalId(
          String t, String u, String l) async =>
      null;
  @override
  Future<String?> fetchServerUpdatedAt(String t, String s) async => updatedAt;
  @override
  Future<Map<String, dynamic>> updateByServerId(
          String t, String s, Map<String, dynamic> r) async =>
      {'id': s, 'updated_at': updatedAt, 'revision': revision};
  @override
  Future<Map<String, dynamic>?> casUpdateByServerId(
          String t, String s, int e, Map<String, dynamic> r) async =>
      null;
  @override
  Future<Map<String, dynamic>> upsert(String t, Map<String, dynamic> r) async =>
      {
        'id': 'srv-${r['local_id']}',
        'updated_at': updatedAt,
        'revision': revision
      };
}

class _DeleteAccountSink implements AccountsRemoteSink {
  _DeleteAccountSink({this.revision = 5});

  bool exists = true;
  int revision;
  String updatedAt = 'base-ts';
  String? deletedAt;

  @override
  Future<Map<String, dynamic>?> casTombstoneAccount(
      String s, int expected) async {
    if (!exists || expected != revision) return null;
    revision += 1;
    deletedAt = 'del-ts';
    updatedAt = 'del-ts';
    return {'id': s, 'updated_at': updatedAt, 'revision': revision};
  }

  @override
  Future<Map<String, dynamic>?> guardedTombstoneAccount(
      String s, String? expectedUpdatedAt) async {
    if (!exists) return null;
    if (expectedUpdatedAt != null) {
      if (updatedAt != expectedUpdatedAt) {
        return null;
      }
    } else if (deletedAt != null) {
      return null;
    }
    deletedAt = 'del-ts';
    updatedAt = 'del-ts';
    return {'id': s, 'updated_at': updatedAt};
  }

  @override
  Future<Map<String, dynamic>?> fetchAccountState(String s) async =>
      exists ? {'deleted_at': deletedAt} : null;

  @override
  Future<Map<String, dynamic>?> findAccountByLocalId(
          String u, String id) async =>
      null;
  @override
  Future<String?> fetchAccountUpdatedAt(String s) async => updatedAt;
  @override
  Future<Map<String, dynamic>?> guardedUpdateAccount(
    String serverId,
    String expectedUpdatedAt,
    Map<String, dynamic> row,
  ) =>
      // C-6: the fake has no concurrent writer, so the atomic guarded update
      // and the targeted update are equivalent here. The ATOMICITY itself is
      // asserted structurally in guarded_update_atomicity_test.dart.
      updateAccountByServerId(serverId, row);

  @override
  Future<Map<String, dynamic>> updateAccountByServerId(
          String s, Map<String, dynamic> r) async =>
      {'id': s, 'updated_at': updatedAt, 'revision': revision};
  @override
  Future<Map<String, dynamic>?> casUpdateAccount(
          String s, int e, Map<String, dynamic> r) async =>
      null;
  @override
  Future<Map<String, dynamic>> upsertAccount(Map<String, dynamic> row) async =>
      {'id': 'srv-${row['local_id']}', 'updated_at': updatedAt};
  @override
  Future<void> setDefaultAccount(String s) async {}
}

GoalEntity _goal() => GoalEntity(
      id: 'g1',
      name: 'Travel',
      currency: 'SAR',
      targetMoney: Money.parse('5000', 'SAR'),
      savedMoney: Money.parse('300', 'SAR'),
      lastNotifiedSavedMoney: Money(0, 'SAR'),
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

  // A synced goal at [revision] with a known base, then deleted (delete
  // enqueued; the payload captures both base tokens).
  Future<void> seedDelete({int? revision = 5}) async {
    await DriftGoalRepository(db, outboxQueue: queue).save(_goal());
    await db.customStatement('DELETE FROM planning_sync_outbox;');
    await db.customStatement(
      "UPDATE goals SET server_id='srv-g1', server_updated_at='base-ts', "
      "server_revision=${revision ?? 'NULL'}, sync_status='synced' WHERE id='g1';",
    );
    final g = await DriftGoalRepository(db, outboxQueue: queue).getById('g1');
    await queue.enqueueGoal(PlanningSyncOperation.delete, g!);
  }

  Future<String?> goalStatus() async => (await db
          .customSelect("SELECT sync_status FROM goals WHERE id='g1';")
          .getSingle())
      .readNullable<String>('sync_status');

  PlanningPushService push(_DeleteSink sink, {required bool casEnabled}) =>
      PlanningPushService(
        db: db,
        queue: queue,
        isEnabled: (_) => true,
        getAuthUserId: () async => 'user-1',
        remoteSink: sink,
        revisionCasEnabled: casEnabled,
      );

  group('planning (goal) guarded tombstone', () {
    test('A CAS-on + matching revision: tombstones and bumps revision once',
        () async {
      await seedDelete(revision: 5);
      final sink = _DeleteSink(revision: 5);
      final r = await push(sink, casEnabled: true).push();
      expect(r.pushed, 1);
      expect(sink.casTombstones, 1);
      expect(sink.revision, 6, reason: 'bump_revision fires exactly once');
      expect(sink.deletedAt, isNotNull);
      expect(await goalStatus(), 'synced');
    });

    test(
        'B UPDATE→stale-delete (CAS-on, revision advanced): CONFLICT, server '
        'row is NOT tombstoned', () async {
      await seedDelete(revision: 5);
      final sink = _DeleteSink(revision: 9); // a newer accepted update
      final r = await push(sink, casEnabled: true).push();
      expect(r.conflicts, 1);
      expect(r.pushed, 0);
      expect(sink.deletedAt, isNull, reason: 'the newer update must survive');
      expect(sink.revision, 9, reason: 'no bump — nothing was written');
      expect(sink.stateFetches, 1, reason: 'classified, never blindly deleted');
      expect(await goalStatus(), 'conflict');
    });

    test(
        'C two-delete idempotency (CAS-on, already tombstoned): benign success',
        () async {
      await seedDelete(revision: 5);
      final sink = _DeleteSink(revision: 9, deletedAt: 'earlier-ts');
      final r = await push(sink, casEnabled: true).push();
      expect(r.pushed, 1, reason: 'already gone → converged');
      expect(r.conflicts, 0);
      expect(sink.revision, 9, reason: 'no second bump');
      expect(await goalStatus(), 'synced');
    });

    test('D absent (CAS-on): fail-closed conflict, never a silent success',
        () async {
      await seedDelete(revision: 5);
      final sink = _DeleteSink(exists: false);
      final r = await push(sink, casEnabled: true).push();
      expect(r.conflicts, 1);
      expect(r.pushed, 0);
      expect(await goalStatus(), 'conflict');
    });

    test('E CAS-off + matching base: guards on updated_at (never id-only)',
        () async {
      await seedDelete(revision: 5);
      final sink = _DeleteSink(updatedAt: 'base-ts');
      final r = await push(sink, casEnabled: false).push();
      expect(r.pushed, 1);
      expect(sink.casTombstones, 0, reason: 'CAS off');
      expect(sink.guardedTombstones, 1);
      expect(sink.deletedAt, isNotNull);
      expect(await goalStatus(), 'synced');
    });

    test('F CAS-off + moved base: a zero-row guarded tombstone is a conflict',
        () async {
      await seedDelete(revision: 5);
      final sink = _DeleteSink(updatedAt: 'moved-ts'); // server advanced
      final r = await push(sink, casEnabled: false).push();
      expect(r.conflicts, 1);
      expect(r.pushed, 0);
      expect(sink.deletedAt, isNull);
      expect(await goalStatus(), 'conflict');
    });

    test(
        'DELETE→stale-update (no resurrection): a stale update against a '
        'tombstoned server row conflicts, never revives it', () async {
      await DriftGoalRepository(db, outboxQueue: queue).save(_goal());
      await db.customStatement('DELETE FROM planning_sync_outbox;');
      await db.customStatement(
        "UPDATE goals SET server_id='srv-g1', server_updated_at='base-ts', "
        "server_revision=5, sync_status='synced' WHERE id='g1';",
      );
      final g = await DriftGoalRepository(db, outboxQueue: queue).getById('g1');
      await queue.enqueueGoal(PlanningSyncOperation.update, g!);
      // The server row was tombstoned + advanced by another device.
      final sink = _DeleteSink(revision: 9, deletedAt: 'del-ts');
      final r = await push(sink, casEnabled: true).push();
      expect(r.conflicts, 1);
      expect(r.pushed, 0);
      expect(sink.deletedAt, 'del-ts',
          reason: 'the server tombstone is never cleared by a stale update');
      expect(await goalStatus(), 'conflict');
    });

    test(
        'G two deletes total bump the revision exactly once (restart-safe '
        'idempotency)', () async {
      await seedDelete(revision: 5);
      final sink = _DeleteSink(revision: 5);
      await push(sink, casEnabled: true).push(); // first: 5 → 6, tombstoned
      expect(sink.revision, 6);
      // A durable replay at the same stale base (outbox survived a restart).
      final g = await DriftGoalRepository(db, outboxQueue: queue).getById('g1');
      await queue.enqueueGoal(PlanningSyncOperation.delete, g!);
      final r2 = await push(sink, casEnabled: true).push();
      expect(r2.pushed, 1, reason: 'idempotent — already tombstoned');
      expect(sink.revision, 6, reason: 'never a second bump');
    });
  });

  group('accounts guarded tombstone', () {
    Future<void> seedAccountDelete({int? revision = 5}) async {
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
      await db.customStatement('DELETE FROM planning_sync_outbox;');
      await db.customStatement(
        "UPDATE accounts SET server_id='srv-a1', server_updated_at='base-ts', "
        "server_revision=${revision ?? 'NULL'}, sync_status='synced' WHERE id='a1';",
      );
      final a = await repo.getById('a1');
      await queue.enqueueAccount(PlanningSyncOperation.delete, a!);
    }

    Future<String?> accountStatus() async => (await db
            .customSelect("SELECT sync_status FROM accounts WHERE id='a1';")
            .getSingle())
        .readNullable<String>('sync_status');

    AccountsPushService accountsPush(_DeleteAccountSink sink,
            {required bool casEnabled}) =>
        AccountsPushService(
          db: db,
          queue: queue,
          isEnabled: () => true,
          getAuthUserId: () async => 'user-1',
          remoteSink: sink,
          revisionCasEnabled: casEnabled,
        
      // C-3: these cover push MECHANICS; consent enforcement is asserted
      // separately in financial_push_consent_test.dart.
      mayEgress: () async => true,
    );

    test('A CAS-on + matching revision: tombstones, bumps once', () async {
      await seedAccountDelete(revision: 5);
      final sink = _DeleteAccountSink(revision: 5);
      final r = await accountsPush(sink, casEnabled: true).push();
      expect(r.pushed, 1);
      expect(sink.revision, 6);
      expect(sink.deletedAt, isNotNull);
      expect(await accountStatus(), 'synced');
    });

    test('B UPDATE→stale-delete (CAS-on): CONFLICT, account NOT tombstoned',
        () async {
      await seedAccountDelete(revision: 5);
      final sink = _DeleteAccountSink(revision: 9);
      final r = await accountsPush(sink, casEnabled: true).push();
      expect(r.conflicts, 1);
      expect(r.pushed, 0);
      expect(sink.deletedAt, isNull);
      expect(await accountStatus(), 'conflict');
    });
  });
}
