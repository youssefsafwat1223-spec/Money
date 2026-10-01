import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/sync/sync_health.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/sync/exact_transport_capability.dart';
import 'package:money_companion/data/sync/sync_cursor.dart';
import 'package:money_companion/features/planning_sync/services/planning_child_sync_service.dart';
import 'package:money_companion/features/planning_sync/services/planning_outbox_queue.dart';

/// A-1b/A-1c — a child PULL held back by a capability (exact pull transport, or
/// the planning-currency gate for goal contributions) is an observable
/// `capabilityParked` state in SyncHealth, never a silent skip.
class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'test-key';
  @override
  Future<String?> readStoredKey() async => 'test-key';
}

class _EmptyRemote implements PlanningChildRemote {
  @override
  Future<List<Map<String, dynamic>>> fetchRows(String table,
          {required SyncCursor after, int limit = 200}) async =>
      const [];
  @override
  Future<Map<String, dynamic>> callRpc(
          String name, Map<String, dynamic> params) async =>
      throw StateError('unexpected RPC');
  @override
  Future<Map<String, dynamic>?> findPlanLink(
          {required String userId,
          required String planId,
          required String transactionId}) async =>
      throw StateError('unexpected');
  @override
  Future<void> tombstonePlanLink(String serverId) async =>
      throw StateError('unexpected');
  @override
  Future<Map<String, dynamic>> upsertPlanLink(Map<String, dynamic> row) async =>
      throw StateError('unexpected');
}

void main() {
  late AppDatabase db;
  late SyncHealth health;

  setUp(() async {
    db = await AppDatabase.open(
        executor: NativeDatabase.memory(), keyStore: _MemoryKeyStore());
    health = SyncHealth();
  });
  tearDown(() async => db.close());

  PlanningChildSyncService service({
    required ExactTransportCapability pullCap,
    required bool Function(String) pullEnabled,
  }) =>
      PlanningChildSyncService(
        db: db,
        queue: PlanningOutboxQueue(
          db: db,
          isSyncEnabled: (_) => true,
          getAuthUserId: () async => 'u1',
        ),
        isEnabled: (_) => true,
        isPullEnabled: pullEnabled,
        getAuthUserId: () async => 'u1',
        mayEgress: () async => true,
        remote: _EmptyRemote(),
        pullCapability: () => pullCap,
        health: health,
      );

  Future<void> run(PlanningChildSyncService s) => health.runPhase(
      SyncDomain.children, SyncDirection.push, () => s.sync());

  test('exact pull transport not verified => capabilityParked', () async {
    await run(service(
        pullCap: ExactTransportCapability.unknown, pullEnabled: (_) => true));
    expect(health.of(SyncDomain.children).lastErrorClass,
        SyncErrorClass.capabilityParked);
    expect(health.of(SyncDomain.children).consecutiveFailures, 0);
  });

  test('goal-contribution pull blocked by planning currency => capabilityParked',
      () async {
    await run(service(
      pullCap: ExactTransportCapability.verifiedExact,
      pullEnabled: (e) => e != PlanningOutboxQueue.goalContributionsEntityType,
    ));
    expect(health.of(SyncDomain.children).lastErrorClass,
        SyncErrorClass.capabilityParked);
  });

  test('everything verified => no parked state, success recorded', () async {
    await run(service(
        pullCap: ExactTransportCapability.verifiedExact,
        pullEnabled: (_) => true));
    expect(health.of(SyncDomain.children).lastErrorClass, isNull);
    expect(health.of(SyncDomain.children).lastPushSuccessAt, isNotNull);
  });
}
