import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/data_portability/data_portability_models.dart';
import 'package:money_companion/core/data_portability/drift_financial_exporter.dart';
import 'package:money_companion/core/data_portability/drift_financial_importer.dart';
import 'package:money_companion/core/data_portability/qirsh_package_codec.dart';
import 'package:money_companion/core/sync/pending_sync_reconciler.dart';
import 'package:money_companion/core/sync/sync_health.dart';
import 'package:money_companion/domain/entities/transaction_entity.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/db/money_v30_backfill.dart';
import 'package:money_companion/data/db/sql_value_codec.dart';
import 'package:money_companion/data/repositories/drift_account_repository.dart';
import 'package:money_companion/domain/entities/account_entity.dart';
import 'package:money_companion/features/capture/services/ledger_outbox_queue.dart';
import 'package:money_companion/features/planning_sync/services/planning_outbox_queue.dart';

/// A-4b: raw-SQL bypass writers mark server-backed rows `pending`; the
/// PendingSyncReconciler records the intent through the normal queue APIs.
class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'test-key';
  @override
  Future<String?> readStoredKey() async => 'test-key';
}

Future<void> _tx(
  AppDatabase db,
  String id, {
  String? serverId,
  String syncStatus = 'synced',
  String type = 'payment',
  String status = 'confirmed',
  String? merchant,
  String? accountId,
}) async {
  final now = dateTimeToSql(DateTime.utc(2026, 6, 1));
  await db.customStatement('''
    INSERT INTO transactions(
      id, amount, currency, type, source, occurred_at, raw_message,
      parse_confidence, status, created_at, updated_at, server_id, sync_status,
      raw_merchant, account_id, direction
    ) VALUES (
      '$id', 10.0, 'SAR', '$type', 'bank', '$now', '', 0.9, '$status',
      '$now', '$now', ${serverId == null ? 'NULL' : "'$serverId'"},
      '$syncStatus', ${merchant == null ? 'NULL' : "'$merchant'"},
      ${accountId == null ? 'NULL' : "'$accountId'"}, 'debit'
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

/// Ledger queue whose enqueue throws for ids starting with `bad` (a row the
/// reconciler cannot map/enqueue).
class _SelectivelyFailingLedger extends LedgerOutboxQueue {
  _SelectivelyFailingLedger({
    required super.db,
    required super.isPushEnabled,
    required super.getAuthUserId,
    required super.getOwnerUid,
  });

  @override
  Future<void> enqueue(OutboxOperation op, TransactionEntity tx) {
    if (tx.id.startsWith('bad')) throw StateError('cannot map ${tx.id}');
    return super.enqueue(op, tx);
  }
}

void main() {
  late AppDatabase db;

  setUp(() async {
    db = await AppDatabase.open(
      executor: NativeDatabase.memory(),
      keyStore: _MemoryKeyStore(),
    );
  });
  tearDown(() async => db.close());

  PendingSyncReconciler reconciler({
    bool consent = true,
    String? owner = 'user-1',
    String? auth = 'user-1',
    int limit = 500,
    AppDatabase? on,
    bool failBad = false,
    SyncHealth? health,
  }) {
    final d = on ?? db;
    return PendingSyncReconciler(
      health: health,
      db: d,
      ledgerQueue:
          (failBad ? _SelectivelyFailingLedger.new : LedgerOutboxQueue.new)(
        db: d,
        isPushEnabled: () => true,
        getAuthUserId: () async => auth,
        getOwnerUid: () async => owner,
      ),
      planningQueue: PlanningOutboxQueue(
        db: d,
        isSyncEnabled: (_) => true,
        getAuthUserId: () async => auth,
        getOwnerUid: () async => owner,
      ),
      getOwnerUid: () async => owner,
      getAuthUserId: () async => auth,
      mayEgress: () async => consent,
      limit: limit,
    );
  }

  Future<List<Map<String, Object?>>> ledgerRows() async => [
        for (final r in await db
            .customSelect(
                'SELECT * FROM ledger_sync_outbox ORDER BY transaction_id;')
            .get())
          r.data
      ];
  Future<List<Map<String, Object?>>> planningRows([String? type]) async => [
        for (final r in await db
            .customSelect('SELECT * FROM planning_sync_outbox '
                "${type == null ? '' : "WHERE entity_type = '$type' "}"
                'ORDER BY entity_type, entity_id;')
            .get())
          r.data
      ];
  Future<String?> syncStatus(String table, String id) async => (await db
          .customSelect("SELECT sync_status AS s FROM $table WHERE id = '$id';")
          .getSingle())
      .readNullable<String>('s');

  group('reconciler', () {
    test('one update per server-backed pending row without an outbox row',
        () async {
      await _tx(db, 'needs', serverId: 'srv-1', syncStatus: 'pending');
      await _tx(db, 'queued', serverId: 'srv-2', syncStatus: 'pending');
      await _tx(db, 'never-synced', syncStatus: 'pending'); // no server_id
      await _tx(db, 'clean', serverId: 'srv-3', syncStatus: 'synced');
      await db.customStatement('''
        INSERT INTO ledger_sync_outbox(id, transaction_id, operation,
          payload_json, attempt_count, status, created_at, updated_at, op_seq)
        VALUES ('o1', 'queued', 'update', '{}', 12, 'dead_letter',
          '2026-06-01T00:00:00Z', '2026-06-01T00:00:00Z', 1);
      ''');

      expect(await reconciler().run(), 1);

      final rows = await ledgerRows();
      expect(rows.map((r) => r['transaction_id']), ['needs', 'queued']);
      final needs = rows.first;
      expect(needs['operation'], 'update');
      expect(needs['status'], 'pending');
      expect(needs['owner_uid'], 'user-1'); // owner stamped per A-2
      expect(rows.last['status'], 'dead_letter', reason: 'untouched');
    });

    test('a second run is a no-op (no duplicate rows)', () async {
      await _tx(db, 'a', serverId: 'srv-1', syncStatus: 'pending');
      final acct = await DriftAccountRepository(db).create(_acct('main'));
      await db.customStatement(
          "UPDATE accounts SET server_id = 'srv-a', sync_status = 'pending' "
          "WHERE id = '${acct.id}';");
      await db.customStatement('DELETE FROM planning_sync_outbox;');

      expect(await reconciler().run(), 2);
      final ledgerBefore = await ledgerRows();
      final planningBefore = await planningRows();
      expect(await reconciler().run(), 0);
      expect(await ledgerRows(), ledgerBefore);
      expect(await planningRows(), planningBefore);
      expect(planningBefore.single['entity_type'], 'account');
    });

    test('a tombstoned server-backed row records a delete', () async {
      await _tx(db, 'gone',
          serverId: 'srv-1', syncStatus: 'pending', status: 'ignored');
      await reconciler().run();
      expect((await ledgerRows()).single['operation'], 'delete');
    });

    test('planning tables: budget, goal, plan, category, settings', () async {
      final cat = (await db
              .customSelect(
                  "SELECT id FROM categories WHERE key = 'groceries';")
              .getSingle())
          .read<String>('id');
      final acct = await DriftAccountRepository(db).create(_acct('main'));
      await db.customStatement('''
        INSERT INTO budgets(id, category_id, currency, amount, amount_minor,
          period, start_date, is_active, last_notified_spent_amount,
          last_notified_spent_amount_minor, last_notified_period_start,
          server_id, sync_status)
        VALUES ('bud', '$cat', 'SAR', 10.0, 1000, 'monthly',
          '2026-07-01T00:00:00Z', 1, 0.0, 0, '2000-01-01T00:00:00Z',
          'srv-bud', 'pending');
      ''');
      await db.customStatement('''
        INSERT INTO goals(id, name, target_amount, saved_amount, currency,
          target_amount_minor, saved_amount_minor,
          last_notified_saved_amount_minor, vault_skin, status, created_at,
          server_id, sync_status)
        VALUES ('goal', 'G', 100, 0, 'SAR', 10000, 0, 0, 'classic', 'active',
          '2026-07-01T00:00:00Z', 'srv-goal', 'pending');
      ''');
      await db.customStatement('''
        INSERT INTO plans(id, name, budget_amount, budget_amount_minor, currency, start_date,
          end_date, account_ids, card_last4s, status, created_at, server_id,
          sync_status)
        VALUES ('plan', 'P', 1000, 100000, 'SAR', '2026-07-01T00:00:00Z',
          '2026-08-01T00:00:00Z', '', '', 'active', '2026-07-01T00:00:00Z',
          'srv-plan', 'pending');
      ''');
      await db.customStatement('''
        INSERT INTO categories(id, key, name_ar, icon, color, is_income,
          sort_order, server_id, sync_status)
        VALUES ('cat-x', 'custom_x', 'x', 'i', '#000000', 0, 99, 'srv-cat',
          'pending');
      ''');
      await db.customStatement(
          "UPDATE user_settings SET server_id = 'srv-set', sync_status = 'pending';");
      await db.customStatement('DELETE FROM planning_sync_outbox;');

      await reconciler().run();

      final types = (await planningRows()).map((r) => r['entity_type']).toSet();
      expect(types,
          containsAll(['budget', 'goal', 'plan', 'category', 'settings']));
      expect(acct.id, isNotEmpty);
    });

    test('consent off: does nothing, the pending marker is kept', () async {
      await _tx(db, 'a', serverId: 'srv-1', syncStatus: 'pending');
      expect(await reconciler(consent: false).run(), 0);
      expect(await ledgerRows(), isEmpty);
      expect(await syncStatus('transactions', 'a'), 'pending');
      // later, consent granted: nothing was lost.
      expect(await reconciler().run(), 1);
    });

    test('guest and owner/auth mismatch record nothing', () async {
      await _tx(db, 'a', serverId: 'srv-1', syncStatus: 'pending');
      expect(await reconciler(owner: null, auth: null).run(), 0);
      expect(await reconciler(owner: 'user-1', auth: 'user-2').run(), 0);
      expect(await ledgerRows(), isEmpty);
    });

    test('no owner marker but a live session records an unstamped intent',
        () async {
      await _tx(db, 'a', serverId: 'srv-1', syncStatus: 'pending');
      expect(await reconciler(owner: null, auth: 'user-1').run(), 1);
      expect((await ledgerRows()).single['owner_uid'], isNull);
    });

    test('bounded per run with continuation next cycle', () async {
      for (var i = 0; i < 5; i++) {
        await _tx(db, 't$i', serverId: 'srv-$i', syncStatus: 'pending');
      }
      final r = reconciler(limit: 2);
      expect(await r.run(), 2);
      expect(await r.run(), 2);
      expect(await r.run(), 1);
      expect(await r.run(), 0);
      expect(await ledgerRows(), hasLength(5));
    });
  });

  group('reconciler starvation (failing rows)', () {
    Future<void> bulkBadTxs(int n) => db.customStatement('''
      WITH RECURSIVE seq(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM seq WHERE i < $n)
      INSERT INTO transactions(
        id, amount, currency, type, source, occurred_at, raw_message,
        parse_confidence, status, created_at, updated_at, server_id,
        sync_status, direction)
      SELECT 'bad' || printf('%04d', i), 10.0, 'SAR', 'payment', 'bank',
        '2026-06-01T00:00:00Z', '', 0.9, 'confirmed', '2026-06-01T00:00:00Z',
        '2026-06-01T00:00:00Z', 'srv-bad-' || i, 'pending', 'debit' FROM seq;
    ''');

    Future<void> pendingAccount() async {
      final acct = await DriftAccountRepository(db).create(_acct('main'));
      await db.customStatement(
          "UPDATE accounts SET server_id = 'srv-a', sync_status = 'pending' "
          "WHERE id = '${acct.id}';");
      await db.customStatement('DELETE FROM planning_sync_outbox;');
    }

    test('600 unmappable rows do not stop later rows or later tables',
        () async {
      await bulkBadTxs(600);
      await _tx(db, 'good1', serverId: 'srv-g1', syncStatus: 'pending');
      await _tx(db, 'good2', serverId: 'srv-g2', syncStatus: 'pending');
      await pendingAccount();
      final health = SyncHealth();

      final r = reconciler(failBad: true, health: health);
      expect(await r.run(), 3, reason: '2 good tx + 1 account in ONE run');
      expect((await ledgerRows()).map((x) => x['transaction_id']),
          ['good1', 'good2']);
      expect((await planningRows('account')), hasLength(1));
      expect(await syncStatus('transactions', 'bad0001'), 'pending',
          reason: 'failed rows stay pending (visible), never marked synced');
      expect(health.of(SyncDomain.ledger).consecutiveFailures, greaterThan(0),
          reason: 'coarse failure recorded');

      // Idempotent: nothing new, no duplicates.
      expect(await r.run(), 0);
      expect(await ledgerRows(), hasLength(2));
      expect(await planningRows('account'), hasLength(1));
    });

    test('a failing table does not consume the shared budget (fairness)',
        () async {
      await bulkBadTxs(30);
      await pendingAccount();
      // limit 2: pre-fix the 30 failures would eat the whole budget.
      expect(await reconciler(failBad: true, limit: 2).run(), 1);
      expect(await planningRows('account'), hasLength(1));
    });

    test('budget counts only recorded rows: a hot table cannot starve others',
        () async {
      for (var i = 0; i < 6; i++) {
        await _tx(db, 'ok$i', serverId: 'srv-$i', syncStatus: 'pending');
      }
      await pendingAccount();
      // limit 4 with 6 ready transactions: the account still gets a slot in
      // the same run.
      expect(await reconciler(limit: 4).run(), 4);
      expect(await planningRows('account'), hasLength(1));
    });
  });

  group('bypass writers mark server-backed rows pending', () {
    test('open-time system backfills (category, merchant, direction)',
        () async {
      final dir = await Directory.systemTemp.createTemp('qirsh-a4b');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/app.db');
      var d = await AppDatabase.open(
          executor: NativeDatabase(file), keyStore: _MemoryKeyStore());
      await _tx(d, 'income-sb',
          type: 'income', serverId: 'srv-1', merchant: 'ACME');
      await _tx(d, 'income-local', type: 'income', merchant: 'ACME');
      await _tx(d, 'clean',
          type: 'payment', serverId: 'srv-2', merchant: 'Shop');
      await d.customStatement(
          "UPDATE transactions SET direction = NULL WHERE id = 'clean';");
      await d.close();

      d = await AppDatabase.open(
          executor: NativeDatabase(file), keyStore: _MemoryKeyStore());
      addTearDown(d.close);
      Future<String?> st(String id) async => (await d
              .customSelect(
                  "SELECT sync_status AS s FROM transactions WHERE id = '$id';")
              .getSingle())
          .readNullable<String>('s');
      expect(await st('income-sb'), 'pending');
      expect(await st('income-local'), 'synced',
          reason: 'never-synced rows keep their state');
      expect(await st('clean'), 'pending', reason: 'direction backfilled');

      // The merchant clean-up is idempotent: once settled, a reopen touches
      // nothing and the settled row stays synced.
      await d.customStatement(
          "UPDATE transactions SET sync_status = 'synced' WHERE id = 'income-sb';");
      await d.close();
      d = await AppDatabase.open(
          executor: NativeDatabase(file), keyStore: _MemoryKeyStore());
      addTearDown(d.close);
      expect(await st('income-sb'), 'synced');
    });

    test('post-restore default-account promotion marks the account pending',
        () async {
      final acct = await DriftAccountRepository(db).create(_acct('first'));
      await db.customStatement(
          "UPDATE accounts SET server_id = 'srv-a', sync_status = 'synced', "
          'is_default = 0;');
      await db.runPostRestoreSetup();
      expect(await syncStatus('accounts', acct.id), 'pending');
    });

    test(
        'importer: replace marks hidden + overwritten server-backed rows '
        'pending, merge leaves duplicates alone', () async {
      final source = await AppDatabase.open(
          executor: NativeDatabase.memory(), keyStore: _MemoryKeyStore());
      addTearDown(source.close);
      final srcAcct =
          await DriftAccountRepository(source).create(_acct('main'));
      await source.customStatement(
          "UPDATE accounts SET id = 'acct-1' WHERE id = '${srcAcct.id}';");
      final package = decodeQirshPackage(
          (await DriftFinancialExporter(source).exportFinancialPackage())
              .bytes);

      final acct = await DriftAccountRepository(db).create(_acct('mine'));
      await db.customStatement(
          "UPDATE accounts SET id = 'acct-1' WHERE id = '${acct.id}';");
      await db.customStatement(
          "UPDATE accounts SET server_id = 'srv-a', sync_status = 'synced';");
      await _tx(db, 'hide-me', serverId: 'srv-t', accountId: 'acct-1');
      await db.customStatement('''
        INSERT INTO categories(id, key, name_ar, icon, color, is_income,
          sort_order, server_id, sync_status)
        VALUES ('cat-c', 'custom_c', 'c', 'i', '#000000', 0, 99, 'srv-c', 'synced');
      ''');

      await DriftFinancialImporter(db).importPackage(package, ImportMode.merge);
      expect(await syncStatus('accounts', 'acct-1'), 'synced');

      await DriftFinancialImporter(db).importPackage(
          decodeQirshPackage(
              (await DriftFinancialExporter(source).exportFinancialPackage())
                  .bytes),
          ImportMode.replace);
      expect(await syncStatus('accounts', 'acct-1'), 'pending');
      expect(await syncStatus('transactions', 'hide-me'), 'pending');
      expect(await syncStatus('categories', 'cat-c'), 'pending');

      // …and the reconciler turns them into intents (delete for the hidden tx).
      await reconciler().run();
      final tx = (await ledgerRows())
          .singleWhere((r) => r['transaction_id'] == 'hide-me');
      expect(tx['operation'], 'delete');
    });
  });

  group('B17: child tables', () {
    Future<void> seedChildren() async {
      const now = '2026-07-23T09:00:00.000Z';
      await db.customStatement('''
        INSERT INTO merchants(id,raw_name,normalized_name,first_seen_at,last_seen_at)
        VALUES ('merchant-1','m','m','$now','$now');
      ''');
      await db.customStatement('''
        INSERT INTO goals(id,name,target_amount,saved_amount,currency,
          target_amount_minor,saved_amount_minor,last_notified_saved_amount_minor,
          vault_skin,status,created_at,server_id,sync_status)
        VALUES ('goal-1','g',100,0,'EGP',10000,0,0,'classic','active','$now',
          'srv-goal','synced');
      ''');
      await db.customStatement('''
        INSERT INTO subscriptions(id,merchant_id,amount,period,next_due_date,
          is_confirmed,reminder_on,name,type,currency,frequency,created_at,status,
          server_id,sync_status)
        VALUES ('bill-1','merchant-1',10,'monthly','$now',1,1,'n','subscription',
          'EGP','monthly','$now','active','srv-bill','synced');
      ''');
      await db.customStatement('''
        INSERT INTO plans(id,name,budget_amount,currency,start_date,end_date,
          account_ids,card_last4s,status,created_at,server_id,sync_status)
        VALUES ('plan-1','p',1000,'EGP','$now','2026-08-01T00:00:00Z','','',
          'active','$now','srv-plan','synced');
      ''');
      await _tx(db, 'tx-1', serverId: 'srv-tx');
      await db.customStatement('''
        INSERT INTO goal_contributions(id,goal_id,amount,amount_minor,created_at,
          server_id,sync_status)
        VALUES ('gc-live','goal-1',25,2500,'$now','srv-gc1','pending'),
               ('gc-dead','goal-1',5,500,'$now','srv-gc2','pending');
      ''');
      await db.customStatement(
          "UPDATE goal_contributions SET deleted_at = '$now' WHERE id = 'gc-dead';");
      await db.customStatement('''
        INSERT INTO bill_payments(id,bill_id,amount,currency,period_start,
          period_end,paid_at,transaction_id,server_id,sync_status)
        VALUES ('bp-live','bill-1',10,'EGP','2026-07-01','2026-07-31','2026-07-23',
                'tx-1','srv-bp1','pending'),
               ('bp-dead','bill-1',10,'EGP','2026-06-01','2026-06-30','2026-06-23',
                NULL,'srv-bp2','pending'),
               ('bp-clean','bill-1',10,'EGP','2026-05-01','2026-05-31','2026-05-23',
                NULL,'srv-bp3','synced'),
               ('bp-local','bill-1',10,'EGP','2026-04-01','2026-04-30','2026-04-23',
                NULL,NULL,'pending');
      ''');
      await backfillNonPlanningMoneyV30(db);
      await db.customStatement(
          "UPDATE bill_payments SET deleted_at = '$now' WHERE id = 'bp-dead';");
      await db.customStatement('''
        INSERT INTO plan_transaction_links(plan_id,transaction_id,created_at,
          server_id,sync_status)
        VALUES ('plan-1','tx-1','$now','srv-link','pending');
      ''');
      await db.customStatement('DELETE FROM planning_sync_outbox;');
    }

    test('pending server-backed children without an outbox row are re-enqueued with the right op',
        () async {
      await seedChildren();
      // D1: a tombstoned contribution is a delete now (0116 endpoint) -> all 5.
      expect(await reconciler().run(), 5);

      final bp = await planningRows('bill_payment');
      expect({for (final r in bp) r['entity_id']: r['operation']},
          {'bp-live': 'create', 'bp-dead': 'delete'});
      final gc = await planningRows('goal_contribution');
      expect({for (final r in gc) r['entity_id']: r['operation']},
          {'gc-live': 'create', 'gc-dead': 'delete'},
          reason: 'D1: a tombstoned contribution has a delete endpoint (0116)');
      final links = await planningRows('plan_transaction_link');
      expect({for (final r in links) r['entity_id']: r['operation']},
          {'plan-1:tx-1': 'create'});
      expect(bp.first['owner_uid'], 'user-1');
    });

    test('children: second run is a no-op; rows without server_id or already queued are untouched',
        () async {
      await seedChildren();
      await reconciler().run();
      final before = await planningRows();
      expect(await reconciler().run(), 0);
      expect(await planningRows(), before);
      expect(await planningRows('bill_payment'), hasLength(2),
          reason: 'bp-local (no server_id) and bp-clean (synced) never queued');
    });
  });
}
