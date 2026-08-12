import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/data_portability/data_portability_models.dart';
import 'package:money_companion/core/data_portability/drift_financial_exporter.dart';
import 'package:money_companion/core/data_portability/drift_financial_importer.dart';
import 'package:money_companion/core/data_portability/portable_csv.dart';
import 'package:money_companion/core/data_portability/qirsh_package_codec.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/db/money_v30_backfill.dart';

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'test-key';

  @override
  Future<String?> readStoredKey() async => 'test-key';
}

Future<AppDatabase> _database() => AppDatabase.open(
      executor: NativeDatabase.memory(),
      keyStore: _MemoryKeyStore(),
    );

void main() {
  test('package merge preserves relationships and is idempotent', () async {
    final source = await _database();
    final target = await _database();
    addTearDown(source.close);
    addTearDown(target.close);

    final account = await source
        .customSelect(
          'SELECT id FROM accounts ORDER BY is_default DESC LIMIT 1;',
        )
        .getSingle();
    final category = await source
        .customSelect(
          "SELECT id FROM categories WHERE key = 'other' LIMIT 1;",
        )
        .getSingle();
    await source.customStatement('''
      INSERT INTO transactions(
        id,account_id,amount,currency,category_id,type,source,occurred_at,
        raw_message,parse_confidence,status,created_at,updated_at,
        comparison_timestamp_source,duplicate_status
      ) VALUES('portable-tx',?,12.5,'EGP',?,'payment','imported',
        '2026-07-18T10:00:00.000Z','private sms',1,'confirmed',
        '2026-07-18T10:00:00.000Z','2026-07-18T10:00:00.000Z',
        'received_at','normal');
    ''', [account.read<String>('id'), category.read<String>('id')]);
    await backfillNonPlanningMoneyV30(source);

    final bytes =
        (await DriftFinancialExporter(source).exportFinancialPackage()).bytes;
    final package = decodeQirshPackage(bytes);
    final importer = DriftFinancialImporter(target);
    final first = await importer.importPackage(package, ImportMode.merge);
    final second = await importer.importPackage(package, ImportMode.merge);

    expect(first.imported, greaterThan(0));
    expect(second.imported, first.imported);
    final rows = await target
        .customSelect(
          "SELECT raw_message,account_id FROM transactions WHERE id='portable-tx';",
        )
        .get();
    expect(rows, hasLength(1));
    expect(rows.single.read<String>('raw_message'), isEmpty);
    expect(rows.single.readNullable<String>('account_id'), isNotNull);
  });

  test(
      'MALI-039: a hostile record_id is bound as a literal — no SQL injection '
      'through the importer', () async {
    final source = await _database();
    final target = await _database();
    addTearDown(source.close);
    addTearDown(target.close);

    // A classic injection payload as the transaction primary key. It flows
    // seed -> export (CSV) -> decode -> import; the importer binds every value
    // (customStatement(sql, [args])), so it must be stored as data, never
    // executed. If any layer interpolated it, `DROP TABLE transactions` would
    // run during import.
    const hostileId = "robert'); DROP TABLE transactions;--";
    final account = await source
        .customSelect('SELECT id FROM accounts ORDER BY is_default DESC LIMIT 1;')
        .getSingle();
    await source.customStatement('''
      INSERT INTO transactions(
        id,account_id,amount,currency,type,source,occurred_at,
        raw_message,parse_confidence,status,created_at,updated_at,
        comparison_timestamp_source,duplicate_status
      ) VALUES(?,?,7.5,'EGP','payment','imported',
        '2026-07-18T10:00:00.000Z','',1,'confirmed',
        '2026-07-18T10:00:00.000Z','2026-07-18T10:00:00.000Z',
        'received_at','normal');
    ''', [hostileId, account.read<String>('id')]);
    await backfillNonPlanningMoneyV30(source);

    final bytes =
        (await DriftFinancialExporter(source).exportFinancialPackage()).bytes;
    final package = decodeQirshPackage(bytes);
    await DriftFinancialImporter(target).importPackage(package, ImportMode.merge);

    // The table survived (the DROP never executed) ...
    final tableExists = await target
        .customSelect(
          "SELECT COUNT(*) AS n FROM sqlite_master "
          "WHERE type='table' AND name='transactions';",
        )
        .map((r) => r.read<int>('n'))
        .getSingle();
    expect(tableExists, 1, reason: 'injection must not drop the table');

    // ... and the payload was stored verbatim as a data value.
    final stored = await target
        .customSelect(
          'SELECT COUNT(*) AS n FROM transactions WHERE id = ?;',
          variables: [Variable.withString(hostileId)],
        )
        .map((r) => r.read<int>('n'))
        .getSingle();
    expect(stored, 1, reason: 'the hostile id is bound as a literal, not executed');
  });

  test('full package restores every supported financial relationship',
      () async {
    final source = await _database();
    final target = await _database();
    addTearDown(source.close);
    addTearDown(target.close);

    const createdAt = '2026-07-18T10:00:00.000Z';
    await source.customStatement('''
      INSERT INTO accounts(id,name,currency,type,is_default,sort_order,created_at,updated_at)
      VALUES('portable-account','حساب مستورد','EGP','bank',0,99,?,?);
    ''', [createdAt, createdAt]);
    await source.customStatement('''
      INSERT INTO categories(id,key,name_ar,icon,color,is_income,sort_order,sync_status)
      VALUES('portable-category','custom_portable','اختبار','category','#64748B',0,99,'local_only');
    ''');
    await source.customStatement('''
      INSERT INTO merchants(id,raw_name,normalized_name,first_seen_at,last_seen_at)
      VALUES('portable-merchant','خدمة اختبار','خدمة اختبار',?,?);
    ''', [createdAt, createdAt]);
    await source.customStatement('''
      INSERT INTO transactions(
        id,account_id,amount,currency,merchant_id,raw_merchant,category_id,type,
        source,occurred_at,raw_message,parse_confidence,status,created_at,
        updated_at,comparison_timestamp,comparison_timestamp_source,duplicate_status
      ) VALUES('portable-transaction','portable-account',25,'EGP',
        'portable-merchant','خدمة اختبار','portable-category','payment','imported',
        ?,'private sms',1,'confirmed',?,?,?,'received_at','normal');
    ''', [createdAt, createdAt, createdAt, createdAt]);
    await source.customStatement('''
      INSERT INTO budgets(id,account_id,category_id,amount,period,start_date,
        is_active,last_notified_spent_amount,last_notified_period_start,show_on_header)
      VALUES('portable-budget','portable-account','portable-category',500,
        'monthly',?,1,0,'2000-01-01T00:00:00Z',1);
    ''', [createdAt]);
    await source.customStatement('''
      INSERT INTO subscriptions(id,account_id,merchant_id,name,amount,currency,
        period,frequency,type,next_due_date,is_confirmed,reminder_on,created_at,status)
      VALUES('portable-subscription','portable-account','portable-merchant',
        'اشتراك اختبار',50,'EGP','monthly','monthly','subscription',?,1,1,?,'active');
    ''', [createdAt, createdAt]);
    await source.customStatement('''
      INSERT INTO bill_payments(id,bill_id,amount,currency,period_start,period_end,
        paid_at,transaction_id,note)
      VALUES('portable-payment','portable-subscription',25,'EGP',?,?,?,
        'portable-transaction','دفعة اختبار');
    ''', [createdAt, createdAt, createdAt]);
    await source.customStatement('''
      INSERT INTO goals(id,account_id,name,target_amount,saved_amount,vault_skin,
        status,created_at)
      VALUES('portable-goal','portable-account','هدف اختبار',1000,100,
        'default','active',?);
    ''', [createdAt]);
    await source.customStatement('''
      INSERT INTO goal_contributions(id,goal_id,amount,created_at,note)
      VALUES('portable-contribution','portable-goal',100,?,'مساهمة اختبار');
    ''', [createdAt]);
    await source.customStatement('''
      INSERT INTO plans(id,name,budget_amount,currency,start_date,end_date,
        account_ids,status,created_at)
      VALUES('portable-plan','خطة اختبار',2000,'EGP',?,?,
        'portable-account','active',?);
    ''', [createdAt, '2026-08-18T10:00:00.000Z', createdAt]);
    await source.customStatement('''
      INSERT INTO plan_transaction_links(plan_id,transaction_id,created_at)
      VALUES('portable-plan','portable-transaction',?);
    ''', [createdAt]);
    await backfillNonPlanningMoneyV30(source);

    final package = decodeQirshPackage(
      (await DriftFinancialExporter(source).exportFinancialPackage()).bytes,
    );
    await DriftFinancialImporter(target)
        .importPackage(package, ImportMode.merge);

    final relationshipChecks = <String, String>{
      'budgets':
          "id='portable-budget' AND account_id='portable-account' AND category_id='portable-category'",
      'subscriptions':
          "id='portable-subscription' AND account_id='portable-account'",
      'bill_payments':
          "id='portable-payment' AND bill_id='portable-subscription' AND transaction_id='portable-transaction'",
      'goals': "id='portable-goal' AND account_id='portable-account'",
      'goal_contributions':
          "id='portable-contribution' AND goal_id='portable-goal'",
      'plans': "id='portable-plan' AND account_ids='portable-account'",
      'plan_transaction_links':
          "plan_id='portable-plan' AND transaction_id='portable-transaction'",
    };
    for (final entry in relationshipChecks.entries) {
      final row = await target
          .customSelect(
            'SELECT COUNT(*) AS total FROM ${entry.key} WHERE ${entry.value};',
          )
          .getSingle();
      expect(row.read<int>('total'), 1, reason: entry.key);
    }
  });

  test('failed replace rolls back the soft-hide stage', () async {
    final db = await _database();
    addTearDown(db.close);
    final exported = await DriftFinancialExporter(db).exportFinancialPackage();
    final package = decodeQirshPackage(exported.bytes);
    final brokenTables = Map<String, PortableCsvDocument>.from(package.tables);
    final transactionTable = package.tables['transactions']!;
    brokenTables['transactions'] = PortableCsvDocument(
      headers: transactionTable.headers,
      rows: [
        {
          for (final header in transactionTable.headers) header: '',
          'record_id': 'broken',
          'amount': '-1',
          'currency': 'EGP',
        },
      ],
    );
    final broken = QirshPackageData(
      packageId: 'broken-package',
      exportedAt: package.exportedAt,
      tables: brokenTables,
    );
    final before = await db
        .customSelect(
          'SELECT COUNT(*) AS total FROM accounts WHERE deleted_at IS NULL;',
        )
        .getSingle();

    await expectLater(
      DriftFinancialImporter(db).importPackage(broken, ImportMode.replace),
      throwsA(isA<DataPortabilityException>()),
    );
    final after = await db
        .customSelect(
          'SELECT COUNT(*) AS total FROM accounts WHERE deleted_at IS NULL;',
        )
        .getSingle();
    expect(after.read<int>('total'), before.read<int>('total'));
  });

  test('same package cannot silently switch import mode', () async {
    final db = await _database();
    addTearDown(db.close);
    final package = decodeQirshPackage(
      (await DriftFinancialExporter(db).exportFinancialPackage()).bytes,
    );
    final importer = DriftFinancialImporter(db);

    await importer.importPackage(package, ImportMode.merge);

    await expectLater(
      importer.importPackage(package, ImportMode.replace),
      throwsA(isA<DataPortabilityException>()),
    );
  });
}
