import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/data_portability/data_portability_models.dart';
import 'package:money_companion/core/data_portability/drift_financial_exporter.dart';
import 'package:money_companion/core/data_portability/qirsh_package_codec.dart';
import 'package:money_companion/core/data_portability/drift_financial_importer.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/db/money_v30_backfill.dart';
import 'package:money_companion/data/db/sql_value_codec.dart';
import 'package:money_companion/data/repositories/drift_account_repository.dart';
import 'package:money_companion/data/repositories/drift_budget_repository.dart';
import 'package:money_companion/data/repositories/drift_category_repository.dart';
import 'package:money_companion/data/repositories/drift_goal_repository.dart';
import 'package:money_companion/data/repositories/drift_transaction_repository.dart';
import 'package:money_companion/domain/entities/account_entity.dart';
import 'package:money_companion/domain/entities/budget_entity.dart';
import 'package:money_companion/domain/entities/goal_entity.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/features/capture/services/ledger_outbox_queue.dart';
import 'package:money_companion/features/capture/services/local_notification_service.dart';
import 'package:money_companion/features/planning_sync/services/planning_outbox_queue.dart';

/// A-4 (G6): every writer that used to mutate synced rows with raw SQL now
/// records sync intent for each affected row in the same local transaction.
class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'test-key';
  @override
  Future<String?> readStoredKey() async => 'test-key';
}

Future<void> _tx(
  AppDatabase db,
  String id, {
  String? categoryId,
  String? accountId,
  String? serverId,
  String status = 'confirmed',
}) async {
  final now = dateTimeToSql(DateTime.now().toUtc());
  await db.customStatement('''
    INSERT INTO transactions(
      id, amount, currency, type, source, occurred_at, raw_message,
      parse_confidence, status, created_at, updated_at,
      category_id, account_id, server_id
    ) VALUES (
      '$id', 10.0, 'SAR', 'payment', 'bank', '$now', '', 0.9, '$status',
      '$now', '$now', ${categoryId == null ? 'NULL' : "'$categoryId'"},
      ${accountId == null ? 'NULL' : "'$accountId'"},
      ${serverId == null ? 'NULL' : "'$serverId'"}
    );
  ''');
  await backfillNonPlanningMoneyV30(db);
}

AccountEntity _acct(String name) => AccountEntity(
      id: '',
      name: name,
      currency: 'SAR',
      type: AccountType.bank,
      isDefault: false,
      sortOrder: 0,
      createdAt: DateTime.utc(2026),
      updatedAt: DateTime.utc(2026),
    );

void main() {
  late AppDatabase db;
  late LedgerOutboxQueue ledger;
  late PlanningOutboxQueue planning;

  setUp(() async {
    db = await AppDatabase.open(
      executor: NativeDatabase.memory(),
      keyStore: _MemoryKeyStore(),
    );
    ledger = LedgerOutboxQueue(
      db: db,
      isPushEnabled: () => true,
      getAuthUserId: () async => 'user-1',
    );
    planning = PlanningOutboxQueue(
      db: db,
      isSyncEnabled: (_) => true,
      getAuthUserId: () async => 'user-1',
    );
  });
  tearDown(() async => db.close());

  Future<List<Map<String, Object?>>> ledgerRows() async => [
        for (final r in await db
            .customSelect(
                'SELECT * FROM ledger_sync_outbox ORDER BY transaction_id;')
            .get())
          r.data
      ];

  Future<List<Map<String, Object?>>> planningRows(String type) async => [
        for (final r in await db
            .customSelect(
                "SELECT * FROM planning_sync_outbox WHERE entity_type = '$type' "
                'ORDER BY entity_id;')
            .get())
          r.data
      ];

  Future<String> catId(String key) async => (await db
          .customSelect("SELECT id FROM categories WHERE key = '$key';")
          .getSingle())
      .read<String>('id');

  test('category delete: remapped transactions and budgets record intent',
      () async {
    final repo = DriftCategoryRepository(db,
        outboxQueue: planning, ledgerOutboxQueue: ledger);
    final custom = await repo.createCategory(
        nameAr: 'مخصص', icon: 'x', color: '#000000', isIncome: false);
    await _tx(db, 'tx-synced', categoryId: custom.id, serverId: 'srv-1');
    await _tx(db, 'tx-other', categoryId: await catId('groceries'));
    await _tx(db, 'tx-ignored',
        categoryId: custom.id, serverId: 'srv-2', status: 'ignored');
    await DriftBudgetRepository(db, outboxQueue: planning).save(BudgetEntity(
      id: 'bud-1',
      categoryId: custom.id,
      currency: 'SAR',
      amountMoney: Money.parse('100', 'SAR'),
      period: BudgetPeriod.monthly,
      startDate: DateTime(2026, 7),
      isActive: true,
      lastNotifiedSpentMoney: Money(0, 'SAR'),
      lastNotifiedPeriodStart: DateTime(2026, 7),
    ));
    await db.customStatement('DELETE FROM ledger_sync_outbox;');
    await db.customStatement(
        "DELETE FROM planning_sync_outbox WHERE entity_type = 'budget';");

    await repo.deleteCategory(custom.id);

    final rows = await ledgerRows();
    expect(rows.map((r) => r['transaction_id']), ['tx-synced']);
    expect(rows.single['operation'], 'update');
    expect(
        (await db
                .customSelect(
                    "SELECT sync_status AS s FROM transactions WHERE id = 'tx-synced';")
                .getSingle())
            .read<String>('s'),
        'pending');
    final budgets = await planningRows('budget');
    expect(budgets.map((r) => r['entity_id']), ['bud-1']);
    expect(budgets.single['operation'], 'update');
  });

  test('category delete folds into an existing pending create (no 2nd row)',
      () async {
    final repo = DriftCategoryRepository(db,
        outboxQueue: planning, ledgerOutboxQueue: ledger);
    final custom = await repo.createCategory(
        nameAr: 'مخصص2', icon: 'x', color: '#000000', isIncome: false);
    await _tx(db, 'tx-new', categoryId: custom.id);
    final entity = (await DriftTransactionRepository(db).getById('tx-new'))!;
    await ledger.enqueue(OutboxOperation.create, entity);

    await repo.deleteCategory(custom.id);

    final rows = await ledgerRows();
    expect(rows, hasLength(1));
    expect(rows.single['operation'], 'create');
  });

  test('account delete: unlinked transactions record intent', () async {
    final repo = DriftAccountRepository(db,
        outboxQueue: planning, ledgerOutboxQueue: ledger);
    final keep = await repo.create(_acct('keep'));
    final gone = await repo.create(_acct('gone'));
    await _tx(db, 'tx-a', accountId: gone.id, serverId: 'srv-a');
    await _tx(db, 'tx-b', accountId: keep.id, serverId: 'srv-b');
    await db.customStatement('DELETE FROM ledger_sync_outbox;');

    await repo.delete(gone.id);

    final rows = await ledgerRows();
    expect(rows.map((r) => r['transaction_id']), ['tx-a']);
    expect(rows.single['operation'], 'update');
    expect(
        (await db
                .customSelect(
                    "SELECT account_id FROM transactions WHERE id = 'tx-a';")
                .getSingle())
            .readNullable<String>('account_id'),
        isNull);
  });

  test('goal orphan re-point records an update per goal (and is idempotent)',
      () async {
    final accounts = DriftAccountRepository(db, outboxQueue: planning);
    final acct = await accounts.create(_acct('main'));
    await accounts.setDefault(acct.id);
    final goals = DriftGoalRepository(db, outboxQueue: planning);
    await goals.save(GoalEntity(
      id: 'goal-1',
      name: 'g',
      currency: 'SAR',
      targetMoney: Money.parse('100', 'SAR'),
      savedMoney: Money(0, 'SAR'),
      lastNotifiedSavedMoney: Money(0, 'SAR'),
      vaultSkin: '',
      status: 'active',
      createdAt: DateTime.utc(2026),
    ));
    await db.customStatement('UPDATE goals SET account_id = NULL;');
    await db.customStatement(
        "DELETE FROM planning_sync_outbox WHERE entity_type = 'goal';");

    expect(await goals.repointOrphanGoalsToDefaultAccount(), 1);
    final rows = await planningRows('goal');
    expect(rows.single['entity_id'], 'goal-1');
    expect(rows.single['operation'], 'update');
    expect(await goals.repointOrphanGoalsToDefaultAccount(), 0);
  });

  test('migration/open no longer re-points goals behind the outbox', () async {
    final accounts = DriftAccountRepository(db, outboxQueue: planning);
    final acct = await accounts.create(_acct('main'));
    await accounts.setDefault(acct.id);
    await DriftGoalRepository(db, outboxQueue: planning).save(GoalEntity(
      id: 'goal-2',
      name: 'g',
      currency: 'SAR',
      targetMoney: Money.parse('100', 'SAR'),
      savedMoney: Money(0, 'SAR'),
      lastNotifiedSavedMoney: Money(0, 'SAR'),
      vaultSkin: '',
      status: 'active',
      createdAt: DateTime.utc(2026),
    ));
    await db.customStatement('UPDATE goals SET account_id = NULL;');
    await db.runPostRestoreSetup();
    expect(
        (await db
                .customSelect("SELECT account_id FROM goals WHERE id = 'goal-2';")
                .getSingle())
            .readNullable<String>('account_id'),
        isNull,
        reason: 'the raw schema-layer backfill is gone; the repository owns it');
  });

  group('importer', () {
    Future<QirshPackageData> sourcePackage(List<String> txIds) async {
      final source = await AppDatabase.open(
        executor: NativeDatabase.memory(),
        keyStore: _MemoryKeyStore(),
      );
      addTearDown(source.close);
      final acct = await DriftAccountRepository(source).create(_acct('main'));
      for (final id in txIds) {
        await _tx(source, id, accountId: acct.id);
      }
      return decodeQirshPackage(
          (await DriftFinancialExporter(source).exportFinancialPackage())
              .bytes);
    }

    test('replace import: hidden rows get a delete, written rows an update',
        () async {
      final acct = await DriftAccountRepository(db).create(_acct('mine'));
      await _tx(db, 'old-only', accountId: acct.id, serverId: 'srv-old');
      await _tx(db, 'both', accountId: acct.id, serverId: 'srv-both');
      await db.customStatement('DELETE FROM ledger_sync_outbox;');
      final package = await sourcePackage(['both', 'fresh']);

      await DriftFinancialImporter(db, ledgerOutbox: ledger)
          .importPackage(package, ImportMode.replace);

      final byId = {
        for (final r in await ledgerRows()) r['transaction_id']: r['operation']
      };
      expect(byId['old-only'], 'delete');
      expect(byId['both'], 'update');
      expect(byId['fresh'], 'create');
    });

    test('merge import: a new transaction records a create, a duplicate none',
        () async {
      final acct = await DriftAccountRepository(db).create(_acct('mine'));
      await _tx(db, 'dup', accountId: acct.id, serverId: 'srv-dup');
      await db.customStatement('DELETE FROM ledger_sync_outbox;');
      final package = await sourcePackage(['dup', 'fresh']);

      await DriftFinancialImporter(db, ledgerOutbox: ledger)
          .importPackage(package, ImportMode.merge);

      final rows = await ledgerRows();
      expect(rows.map((r) => r['transaction_id']), ['fresh']);
      expect(rows.single['operation'], 'create');
    });
  });

  group('background notification action', () {
    Future<DriftTransactionRepository> fg() async =>
        DriftTransactionRepository(db, outboxQueue: ledger);

    test('confirm produces the same outbox state as the foreground confirm',
        () async {
      await _tx(db, 'bg', status: 'pending', serverId: 'srv-bg');
      await _tx(db, 'fgtx', status: 'pending', serverId: 'srv-fg');
      await LocalNotificationService.applyBackgroundActionToDb(db, 'bg',
          confirm: true, queue: ledger);
      await (await fg()).confirm('fgtx');

      final rows = {
        for (final r in await ledgerRows()) r['transaction_id']: r
      };
      expect(rows['bg']!['operation'], rows['fgtx']!['operation']);
      expect(rows['bg']!['operation'], 'update');
      expect(rows['bg']!['status'], 'pending');
      expect(
          (await db
                  .customSelect("SELECT status FROM transactions WHERE id='bg';")
                  .getSingle())
              .read<String>('status'),
          'confirmed');
    });

    test('dismiss of a never-sent capture cancels the create (like foreground)',
        () async {
      await _tx(db, 'bg', status: 'pending');
      final entity = (await DriftTransactionRepository(db).getById('bg'))!;
      await ledger.enqueue(OutboxOperation.create, entity);

      await LocalNotificationService.applyBackgroundActionToDb(db, 'bg',
          confirm: false, queue: ledger);

      expect(await ledgerRows(), isEmpty);
    });

    test('dismiss with an in-flight create enqueues a delete, never drops it',
        () async {
      await _tx(db, 'bg', status: 'pending');
      final entity = (await DriftTransactionRepository(db).getById('bg'))!;
      await ledger.enqueue(OutboxOperation.create, entity);
      await ledger.pendingItems(); // hands out + sets in_flight_seq

      await LocalNotificationService.applyBackgroundActionToDb(db, 'bg',
          confirm: false, queue: ledger);

      final rows = await ledgerRows();
      expect(rows, hasLength(1));
      expect(rows.single['operation'], 'delete');
      expect(rows.single['status'], 'pending');
      // no invented base token: the payload only carries what the row has.
      expect(rows.single['payload_json'].toString(),
          isNot(contains('server_revision')));
    });

    test('dismiss of a synced capture enqueues a delete carrying its server id',
        () async {
      await _tx(db, 'bg', status: 'pending', serverId: 'srv-bg');

      await LocalNotificationService.applyBackgroundActionToDb(db, 'bg',
          confirm: false, queue: ledger);

      final rows = await ledgerRows();
      expect(rows.single['operation'], 'delete');
      expect(rows.single['payload_json'].toString(), contains('srv-bg'));
    });

    test('a non-pending transaction is left untouched (idempotent replay)',
        () async {
      await _tx(db, 'done', status: 'confirmed', serverId: 'srv-d');
      await LocalNotificationService.applyBackgroundActionToDb(db, 'done',
          confirm: false, queue: ledger);
      expect(await ledgerRows(), isEmpty);
      expect(
          (await db
                  .customSelect("SELECT status FROM transactions WHERE id='done';")
                  .getSingle())
              .read<String>('status'),
          'confirmed');
    });
  });
}
