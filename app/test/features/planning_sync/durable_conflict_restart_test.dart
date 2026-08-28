// MALI-026 (Phase-9M §12/§13/§14/§16) — restore the premise that failed LIVE in
// 9L: a real zero-row guarded CAS must become a DURABLE sync_status='conflict'
// (outbox CONSUMED, NOT dead-lettered), survive a file-backed restart, and be
// resolvable by keep-mine (rebase → success) / keep-theirs. The conflict
// ORIGINATES from the actual zero-row result (a shared-server fake returns null
// on a revision mismatch), never a hand-set status.
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/sync/conflict_policy.dart';
import 'package:money_companion/core/sync/conflict_resolver.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/repositories/drift_goal_repository.dart';
import 'package:money_companion/domain/entities/goal_entity.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/features/planning_sync/services/planning_outbox_queue.dart';
import 'package:money_companion/features/planning_sync/services/planning_push_service.dart';

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'test-key';
  @override
  Future<String?> readStoredKey() async => 'test-key';
}

/// The single shared server row A and B race on.
class _Server {
  int revision = 5;
  String updatedAt = 'base-ts';
  String? deletedAt;
  bool exists = true;
}

/// A sink over the shared [_Server] with real revision-CAS cardinality: a
/// mismatch returns null (the 0-row branch), exactly as `guardedAck([])` does.
class _SharedSink implements PlanningRemoteSink {
  _SharedSink(this.s);
  final _Server s;

  @override
  Future<Map<String, dynamic>?> casUpdateByServerId(
      String t, String sid, int expected, Map<String, dynamic> row) async {
    if (!s.exists || expected != s.revision) return null;
    s.revision += 1;
    s.updatedAt = 'u-${s.revision}';
    return {'id': sid, 'updated_at': s.updatedAt, 'revision': s.revision};
  }

  @override
  Future<Map<String, dynamic>?> casTombstone(
      String t, String sid, int expected) async {
    if (!s.exists || expected != s.revision) return null;
    s.revision += 1;
    s.deletedAt = 'del-${s.revision}';
    s.updatedAt = 'u-${s.revision}';
    return {'id': sid, 'updated_at': s.updatedAt, 'revision': s.revision};
  }

  @override
  Future<Map<String, dynamic>?> guardedTombstone(
      String t, String sid, String? expectedUpdatedAt) async {
    if (!s.exists) return null;
    if (expectedUpdatedAt != null && expectedUpdatedAt != s.updatedAt) {
      return null;
    }
    if (expectedUpdatedAt == null && s.deletedAt != null) return null;
    s.revision += 1;
    s.deletedAt = 'del-${s.revision}';
    return {'id': sid, 'updated_at': s.updatedAt};
  }

  @override
  Future<Map<String, dynamic>?> fetchRowState(String t, String sid) async =>
      s.exists ? {'deleted_at': s.deletedAt} : null;
  @override
  Future<Map<String, dynamic>?> findByLocalId(
          String t, String u, String l) async =>
      null;
  @override
  Future<String?> fetchServerUpdatedAt(String t, String sid) async =>
      s.updatedAt;
  @override
  Future<Map<String, dynamic>?> guardedUpdateByServerId(
    String table,
    String serverId,
    String expectedUpdatedAt,
    Map<String, dynamic> row,
  ) async {
    // C-6: no concurrent writer modelled; rejection is covered in
    // planning_guarded_update_atomicity_test.dart.
    return updateByServerId(table, serverId, row);
  }

  @override
  Future<Map<String, dynamic>?> updateByServerId(
          String t, String sid, Map<String, dynamic> row) async =>
      s.exists
          ? {'id': sid, 'updated_at': s.updatedAt, 'revision': s.revision}


          : null;
  @override
  Future<Map<String, dynamic>> upsert(
          String t, Map<String, dynamic> row) async =>
      {
        'id': 'srv-${row['local_id']}',
        'updated_at': s.updatedAt,
        'revision': s.revision
      };
}

GoalEntity _goal(int savedMinor) => GoalEntity(
      id: 'g1',
      name: 'Travel',
      currency: 'SAR',
      targetMoney: Money.parse('5000', 'SAR'),
      savedMoney: Money(savedMinor, 'SAR'),
      lastNotifiedSavedMoney: Money(0, 'SAR'),
      vaultSkin: 'classic',
      status: 'active',
      createdAt: DateTime.utc(2026, 7, 1),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  PlanningOutboxQueue queueOf(AppDatabase db) => PlanningOutboxQueue(
      db: db, isSyncEnabled: (_) => true, getAuthUserId: () async => 'user-1');
  PlanningPushService push(AppDatabase db, PlanningOutboxQueue q, _Server s) =>
      PlanningPushService(
        db: db,
        queue: q,
        isEnabled: (_) => true,
        getAuthUserId: () async => 'user-1',
        remoteSink: _SharedSink(s),
        revisionCasEnabled: true,
      );
  UniversalConflictResolver resolverOf(
          AppDatabase db, PlanningOutboxQueue q, _Server s) =>
      UniversalConflictResolver(
        db: db,
        reEnqueue: {
          ConflictEntities.goal: (id) async {
            final g = await DriftGoalRepository(db, outboxQueue: q).getById(id);
            if (g != null) await q.enqueueGoal(PlanningSyncOperation.update, g);
          },
        },
        baseFetcher: (table, sid) async =>
            ConflictBase(updatedAt: s.updatedAt, revision: s.revision),
      );

  // Seed a goal synced at revision 5, then enqueue [op] carrying that base.
  Future<void> seed(
      AppDatabase db, PlanningOutboxQueue q, PlanningSyncOperation op,
      {int saved = 30000}) async {
    final repo = DriftGoalRepository(db, outboxQueue: q);
    await repo.save(_goal(saved));
    await db.customStatement('DELETE FROM planning_sync_outbox;');
    await db.customStatement(
      "UPDATE goals SET server_id='srv-g1', server_updated_at='base-ts', "
      "server_revision=5, sync_status='synced' WHERE id='g1';",
    );
    final g = await repo.getById('g1');
    await q.enqueueGoal(op, g!); // captures base revision 5
    if (op == PlanningSyncOperation.delete) {
      // Mirror repo.delete: the goal is soft-deleted locally (deleted_at set),
      // so the resolver recognises keep-mine as a DELETE intent.
      await db.customStatement(
        "UPDATE goals SET deleted_at='2026-08-02T00:00:00.000Z', "
        "status='archived' WHERE id='g1';",
      );
    }
  }

  Future<String?> statusOf(AppDatabase db) async => (await db
          .customSelect("SELECT sync_status FROM goals WHERE id='g1';")
          .getSingle())
      .readNullable<String>('sync_status');
  Future<int> outboxN(AppDatabase db) async => (await db
          .customSelect("SELECT COUNT(*) n FROM planning_sync_outbox "
              "WHERE entity_id='g1' AND status='pending';")
          .getSingle())
      .read<int>('n');
  Future<int> deadN(AppDatabase db) async => (await db
          .customSelect("SELECT COUNT(*) n FROM planning_sync_outbox "
              "WHERE entity_id='g1' AND status='dead_letter';")
          .getSingle())
      .read<int>('n');

  test(
      'zero-row CAS update → DURABLE conflict (consumed, not dead-lettered), '
      'survives file-backed restart, then keep-mine rebases → success',
      () async {
    final server = _Server(); // revision 5
    final dir = Directory.systemTemp.createTempSync('9m_dur');
    final path = '${dir.path}/b.db';
    try {
      // Device A advanced the server to revision 6 (modelled directly).
      server.revision = 6;
      server.updatedAt = 'u-6';

      var db = await AppDatabase.open(
          executor: NativeDatabase(File(path)), keyStore: _MemoryKeyStore());
      var q = queueOf(db);
      await seed(db, q, PlanningSyncOperation.update,
          saved: 40000); // B's local edit
      final r = await push(db, q, server).push();

      expect(r.conflicts, 1, reason: 'a real 0-row CAS is a conflict');
      expect(await statusOf(db), 'conflict');
      expect(await deadN(db), 0, reason: 'NEVER dead-lettered');
      expect(await outboxN(db), 0,
          reason: 'the conflict consumed the outbox row');
      await db.close();

      // Restart: reopen the SAME file — the conflict + local edit persist, and
      // nothing auto-re-pushes.
      db = await AppDatabase.open(
          executor: NativeDatabase(File(path)), keyStore: _MemoryKeyStore());
      q = queueOf(db);
      expect(await statusOf(db), 'conflict', reason: 'durable across restart');
      final savedMinor = (await db
              .customSelect(
                  "SELECT saved_amount_minor m FROM goals WHERE id='g1';")
              .getSingle())
          .read<int>('m');
      expect(savedMinor, 40000, reason: 'B local edit survived');
      expect(await outboxN(db), 0, reason: 'no stale mutation re-armed');

      // keep-mine: rebase onto the current server revision (6) and re-push.
      await resolverOf(db, q, server)
          .resolveKeepLocal(ConflictEntities.goal, 'g1');
      final r2 = await push(db, q, server).push();
      expect(r2.pushed, 1, reason: 'rebased CAS matches → success');
      expect(server.revision, 7);
      expect(await statusOf(db), 'synced');
      await db.close();
    } finally {
      dir.deleteSync(recursive: true);
    }
  });

  test('zero-row CAS update conflict → keep-theirs adopts remote, no push',
      () async {
    final server = _Server()
      ..revision = 6
      ..updatedAt = 'u-6';
    final db = await AppDatabase.open(
        executor: NativeDatabase.memory(), keyStore: _MemoryKeyStore());
    addTearDown(db.close);
    final q = queueOf(db);
    await seed(db, q, PlanningSyncOperation.update, saved: 40000);
    await push(db, q, server).push(); // conflict
    expect(await statusOf(db), 'conflict');
    await resolverOf(db, q, server)
        .resolveKeepRemote(ConflictEntities.goal, 'g1');
    expect(await statusOf(db), 'synced');
    expect(server.revision, 6, reason: 'keep-theirs pushes nothing');
    expect(await outboxN(db), 0);
  });

  test(
      'DELETE conflict from a real zero-row tombstone → durable conflict; '
      'keep-mine re-enqueues a rebased delete that succeeds', () async {
    final server = _Server()
      ..revision = 6
      ..updatedAt = 'u-6'; // device A already updated
    final db = await AppDatabase.open(
        executor: NativeDatabase.memory(), keyStore: _MemoryKeyStore());
    addTearDown(db.close);
    final q = queueOf(db);
    await seed(db, q, PlanningSyncOperation.delete); // B stale delete at base 5
    final r = await push(db, q, server).push();
    expect(r.conflicts, 1, reason: '0-row tombstone → conflict');
    expect(await statusOf(db), 'conflict');
    expect(server.deletedAt, isNull, reason: 'server not tombstoned');
    expect(await deadN(db), 0);

    // keep-mine on the locally-deleted goal → rebased delete → succeeds.
    await resolverOf(db, q, server)
        .resolveKeepLocal(ConflictEntities.goal, 'g1');
    final r2 = await push(db, q, server).push();
    expect(r2.pushed, 1);
    expect(server.deletedAt, isNotNull,
        reason: 'now tombstoned at the rebased rev');
    expect(server.revision, 7);
  });
}
