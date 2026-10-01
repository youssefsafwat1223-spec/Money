import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/sync/sync_health.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/repositories/drift_dedup_store.dart';
import 'package:money_companion/data/repositories/drift_transaction_repository.dart';
import 'package:money_companion/features/capture/services/ledger_sync_service.dart';
import 'package:money_companion/features/planning_sync/services/accounts_pull_service.dart';
import 'package:money_companion/features/planning_sync/services/planning_pull_service.dart';

/// A-1b — a pull blocked by an unverified/unsupported capability is an
/// OBSERVABLE state (`capabilityParked`), not a silent no-op. A-1a recorded
/// only the push side.
class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'memory-key';
  @override
  Future<String?> readStoredKey() async => 'memory-key';
}

void main() {
  late AppDatabase db;
  late SyncHealth health;

  setUp(() async {
    db = await AppDatabase.open(
      executor: NativeDatabase.memory(),
      keyStore: _MemoryKeyStore(),
    );
    health = SyncHealth();
  });
  tearDown(() async => db.close());

  test('accounts pull blocked by capability records capabilityParked', () async {
    final service = AccountsPullService(
      db: db,
      isEnabled: () => false,
      mayEgress: () async => true,
      getAuthUserId: () async => 'u1',
      health: health,
    );
    await health.runPhase(
        SyncDomain.accounts, SyncDirection.pull, () => service.pull());
    expect(health.of(SyncDomain.accounts).lastErrorClass,
        SyncErrorClass.capabilityParked);
    expect(health.of(SyncDomain.accounts).consecutiveFailures, 0);
  });

  test('ledger pull blocked by capability records capabilityParked', () async {
    final service = LedgerSyncService(
      db: db,
      transactionRepository: DriftTransactionRepository(db),
      dedupStore: DriftDedupStore(db),
      isPullEnabled: () => false,
      mayEgress: () async => true,
      getAuthUserId: () async => 'u1',
      health: health,
    );
    await health.runPhase(
        SyncDomain.ledger, SyncDirection.pull, () => service.pull());
    expect(health.of(SyncDomain.ledger).lastErrorClass,
        SyncErrorClass.capabilityParked);
  });

  test('planning pull blocked by capability records capabilityParked',
      () async {
    final service = PlanningPullService(
      db: db,
      isEnabled: (_) => false,
      mayEgress: () async => true,
      mayEgressProfile: () async => true,
      getAuthUserId: () async => 'u1',
      health: health,
    );
    await health.runPhase(
        SyncDomain.planning, SyncDirection.pull, () => service.pull());
    expect(health.of(SyncDomain.planning).lastErrorClass,
        SyncErrorClass.capabilityParked);
  });

  test('consent OFF still wins over capability parking', () async {
    final service = AccountsPullService(
      db: db,
      isEnabled: () => false,
      mayEgress: () async => false,
      getAuthUserId: () async => 'u1',
      health: health,
    );
    await health.runPhase(
        SyncDomain.accounts, SyncDirection.pull, () => service.pull());
    expect(health.of(SyncDomain.accounts).lastErrorClass,
        SyncErrorClass.consentBlocked);
  });
}
