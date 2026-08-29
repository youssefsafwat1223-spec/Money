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
import 'package:money_companion/engine/parser/capture_money.dart';

/// Cross-model audit finding **C-2** — "تصدير كل بيانات قرش" corrupted planning
/// state on import.
///
/// `budgets`, `goals` and `goal_contributions` are canonical money tables
/// (registered in [kV30MinorColumns]), but the importer wrote only the legacy
/// REAL columns for them — leaving `*_minor` NULL. Every canonical read then
/// throws ("v30 read requires a minor value"), and the cutover marker ends up
/// covering non-canonical rows. The per-row currency was not exported either,
/// so recovery was impossible.
///
/// These tests assert the property that actually matters: **after an import, no
/// planning row may carry a NULL canonical minor**, and the value must be exact.
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

/// Every planning minor column the v30 registry declares canonical.
Iterable<({String table, String column})> get _planningMinorColumns =>
    kV30MinorColumns
        .where((c) =>
            const {'budgets', 'goals', 'goal_contributions'}.contains(c.table))
        .map((c) => (table: c.table, column: c.minorColumn));

Future<void> _expectNoNullPlanningMinors(AppDatabase db) async {
  for (final col in _planningMinorColumns) {
    // Only rows that actually carry money: a NULL REAL legitimately pairs with
    // a NULL minor (e.g. a goal with no auto-save).
    final real = col.column.substring(0, col.column.length - '_minor'.length);
    final rows = await db
        .customSelect(
          'SELECT COUNT(*) AS n FROM ${col.table} '
          'WHERE $real IS NOT NULL AND ${col.column} IS NULL;',
        )
        .getSingle();
    expect(rows.read<int>('n'), 0,
        reason: '${col.table}.${col.column} is NULL for a row that has money — '
            'canonical reads will throw (audit C-2)');
  }
}

Future<int?> _minor(
    AppDatabase db, String table, String column, String id) async {
  final row = await db
      .customSelect('SELECT $column AS v FROM $table WHERE id = \'$id\';')
      .getSingleOrNull();
  return row?.read<int?>('v');
}

void main() {
  test(
      'new package round-trips every exported canonical money field by exact minor units',
      () async {
    final source = await _database();
    final target = await _database();
    addTearDown(source.close);
    addTearDown(target.close);

    const now = '2026-08-01T00:00:00.000Z';
    const over2p53 = 9007199254740993;
    const maxInt64 = 9223372036854775807;
    const minInt64 = -9223372036854775808;
    final categoryId = (await source
            .customSelect(
                "SELECT id FROM categories WHERE key = 'other' LIMIT 1;")
            .getSingle())
        .read<String>('id');

    // The REAL shadows are deliberately divergent. Before this fix the package
    // exported those values as authority, so tx-exact imported as 2^53 instead
    // of 2^53+1. The exact minors below must win for every family.
    await source.customStatement('''
      INSERT INTO accounts(id,name,currency,type,initial_balance,initial_balance_minor,
        current_balance,current_balance_minor,credit_limit,credit_limit_minor,
        available_credit,available_credit_minor,is_default,sort_order,created_at,updated_at)
      VALUES('acc-exact','Exact','JPY','bank',9007199254740992.0,$over2p53,
        -1.0,$minInt64,1.0,$maxInt64,-1.0,-$over2p53,0,90,'$now','$now');
    ''');
    await source.customStatement('''
      INSERT INTO transactions(id,account_id,amount,amount_minor,currency,category_id,
        type,source,balance_after,balance_after_minor,occurred_at,raw_message,
        parse_confidence,status,created_at,updated_at,foreign_amount,
        foreign_amount_minor,foreign_currency,direction,comparison_timestamp_source,
        duplicate_status)
      VALUES('tx-exact','acc-exact',9007199254740992.0,$over2p53,'JPY','$categoryId',
        'payment','imported',-1.0,$minInt64,'$now','',1,'confirmed','$now','$now',
        1.0,$maxInt64,'KWD','debit','received_at','normal');
    ''');
    await source.customStatement('''
      INSERT INTO budgets(id,category_id,currency,amount,amount_minor,period,start_date,
        is_active,last_notified_spent_amount,last_notified_spent_amount_minor,
        last_notified_period_start,show_on_header)
      VALUES('budget-exact','$categoryId','SAR',1.0,$maxInt64,'monthly','$now',1,
        1.0,$over2p53,'$now',0);
    ''');
    await source.customStatement('''
      INSERT INTO merchants(id,raw_name,normalized_name,first_seen_at,last_seen_at)
      VALUES('merchant-exact','Exact merchant','exact merchant','$now','$now');
    ''');
    await source.customStatement('''
      INSERT INTO subscriptions(id,merchant_id,name,amount,amount_minor,currency,period,frequency,type,
        next_due_date,is_confirmed,reminder_on,created_at,status,manual_paid_amount,
        manual_paid_amount_minor,total_purchase_amount,total_purchase_amount_minor)
      VALUES('sub-exact','merchant-exact','Exact sub',1.0,$over2p53,'KWD','monthly','monthly',
        'subscription','$now',1,1,'$now','active',1.0,12345,1.0,$maxInt64);
    ''');
    await source.customStatement('''
      INSERT INTO bill_payments(id,bill_id,amount,amount_minor,currency,period_start,
        period_end,paid_at)
      VALUES('payment-exact','sub-exact',1.0,$maxInt64,'KWD','$now','$now','$now');
    ''');
    await source.customStatement('''
      INSERT INTO goals(id,name,currency,target_amount,target_amount_minor,saved_amount,
        saved_amount_minor,vault_skin,status,created_at,auto_save_amount,
        auto_save_amount_minor,auto_save_period,last_notified_saved_amount,
        last_notified_saved_amount_minor)
      VALUES('goal-exact','Exact goal','KWD',1.0,$maxInt64,1.0,$over2p53,
        'default','active','$now',1.0,12345,'monthly',1.0,54321);
    ''');
    await source.customStatement('''
      INSERT INTO goal_contributions(id,goal_id,amount,amount_minor,created_at)
      VALUES('contribution-exact','goal-exact',1.0,$over2p53,'$now');
    ''');
    await source.customStatement('''
      INSERT INTO plans(id,name,budget_amount,budget_amount_minor,currency,start_date,
        end_date,account_ids,card_last4s,status,created_at)
      VALUES('plan-exact','Exact plan',1.0,$maxInt64,'JPY','$now','$now','','',
        'active','$now');
    ''');

    final package = decodeQirshPackage(
      (await DriftFinancialExporter(source).exportFinancialPackage()).bytes,
    );
    final exportedContribution = package.tables['goal_contributions']!.rows
        .singleWhere((row) => row['record_id'] == 'contribution-exact');
    expect(exportedContribution['currency'], 'KWD',
        reason: 'a contribution must carry its parent currency in the package');

    final exportedTx = package.tables['transactions']!.rows
        .singleWhere((row) => row['record_id'] == 'tx-exact');
    expect(exportedTx['amount_minor'], '$over2p53');
    expect(exportedTx['amount'], isNot('$over2p53'),
        reason: 'non-vacuity: the legacy REAL shadow cannot carry 2^53+1');
    expect(
      legacyLossyNumberToMoney(num.parse(exportedTx['amount']!), 'JPY')
          .minorUnits,
      isNot(over2p53),
      reason: 'the pre-fix importer path reconstructs a different minor value',
    );

    await DriftFinancialImporter(target)
        .importPackage(package, ImportMode.merge);

    Future<void> expectMoney(
      String table,
      String id,
      Map<String, int> expected,
    ) async {
      final row = await target.customSelect(
        'SELECT ${expected.keys.join(', ')} FROM $table WHERE id = ?',
        variables: [Variable.withString(id)],
      ).getSingle();
      for (final entry in expected.entries) {
        expect(row.read<int>(entry.key), entry.value,
            reason: '$table.$id.${entry.key} must be exact');
      }
    }

    await expectMoney('accounts', 'acc-exact', {
      'initial_balance_minor': over2p53,
      'current_balance_minor': minInt64,
      'credit_limit_minor': maxInt64,
      'available_credit_minor': -over2p53,
    });
    await expectMoney('transactions', 'tx-exact', {
      'amount_minor': over2p53,
      'balance_after_minor': minInt64,
      'foreign_amount_minor': maxInt64,
    });
    await expectMoney('budgets', 'budget-exact', {
      'amount_minor': maxInt64,
      'last_notified_spent_amount_minor': over2p53,
    });
    await expectMoney('subscriptions', 'sub-exact', {
      'amount_minor': over2p53,
      'manual_paid_amount_minor': 12345,
      'total_purchase_amount_minor': maxInt64,
    });
    await expectMoney(
        'bill_payments', 'payment-exact', {'amount_minor': maxInt64});
    await expectMoney('goals', 'goal-exact', {
      'target_amount_minor': maxInt64,
      'saved_amount_minor': over2p53,
      'auto_save_amount_minor': 12345,
      'last_notified_saved_amount_minor': 54321,
    });
    await expectMoney(
        'goal_contributions', 'contribution-exact', {'amount_minor': over2p53});
    await expectMoney('plans', 'plan-exact', {'budget_amount_minor': maxInt64});

    final currencies = await target.customSelect('''
      SELECT
        (SELECT currency FROM accounts WHERE id='acc-exact') AS account_currency,
        (SELECT currency FROM transactions WHERE id='tx-exact') AS tx_currency,
        (SELECT foreign_currency FROM transactions WHERE id='tx-exact') AS fx_currency,
        (SELECT currency FROM budgets WHERE id='budget-exact') AS budget_currency,
        (SELECT currency FROM goals WHERE id='goal-exact') AS goal_currency
    ''').getSingle();
    expect(currencies.data, {
      'account_currency': 'JPY', // scale 0
      'tx_currency': 'JPY',
      'fx_currency': 'KWD', // scale 3
      'budget_currency': 'SAR', // scale 2
      'goal_currency': 'KWD',
    });
  });

  test(
      'merge quarantines contributions when the kept goal has another currency',
      () async {
    final source = await _database();
    final target = await _database();
    addTearDown(source.close);
    addTearDown(target.close);

    const now = '2026-08-01T00:00:00.000Z';
    await source.customStatement('''
      INSERT INTO goals(id,name,currency,target_amount,target_amount_minor,saved_amount,
        saved_amount_minor,vault_skin,status,created_at,last_notified_saved_amount,
        last_notified_saved_amount_minor)
      VALUES('same-goal','Package KWD goal','KWD',1000,1000000,0,0,
        'default','active','$now',0,0);
    ''');
    await source.customStatement('''
      INSERT INTO goal_contributions(id,goal_id,amount,amount_minor,created_at)
      VALUES('package-contribution','same-goal',12.345,12345,'$now');
    ''');

    // MERGE keeps this pre-existing goal. Its USD scale (2) must not be used to
    // reconstruct the package contribution, whose authoritative scale is KWD (3).
    await target.customStatement('''
      INSERT INTO goals(id,name,currency,target_amount,target_amount_minor,saved_amount,
        saved_amount_minor,vault_skin,status,created_at,last_notified_saved_amount,
        last_notified_saved_amount_minor)
      VALUES('same-goal','Local USD goal','USD',1000,100000,0,0,
        'default','active','$now',0,0);
    ''');
    await target.customStatement('''
      INSERT INTO goal_contributions(id,goal_id,amount,amount_minor,created_at,note)
      VALUES('local-contribution','same-goal',5,500,'$now','keep me');
    ''');

    final package = decodeQirshPackage(
      (await DriftFinancialExporter(source).exportFinancialPackage()).bytes,
    );
    final exported = package.tables['goal_contributions']!.rows.singleWhere(
      (row) => row['record_id'] == 'package-contribution',
    );
    expect(exported['currency'], 'KWD',
        reason: 'non-vacuity: the pre-fix export omitted this authority');
    expect(exported['amount_minor'], '12345');

    final importer = DriftFinancialImporter(target);
    final first = await importer.importPackage(package, ImportMode.merge);
    expect(first.skipped, 1,
        reason: 'the currency mismatch must be surfaced as quarantined');

    final keptGoal = await target
        .customSelect("SELECT name,currency FROM goals WHERE id='same-goal';")
        .getSingle();
    expect(keptGoal.read<String>('name'), 'Local USD goal');
    expect(keptGoal.read<String>('currency'), 'USD');

    final wrongScaleRow = await target.customSelect('''
      SELECT amount,amount_minor FROM goal_contributions
      WHERE id='package-contribution';
    ''').getSingleOrNull();
    expect(wrongScaleRow, isNull,
        reason: 'non-vacuity: the pre-fix importer writes this KWD minor under '
            'the preserved USD goal instead of quarantining it');
    final localContribution = await target.customSelect('''
      SELECT goal_id,amount,amount_minor,note FROM goal_contributions
      WHERE id='local-contribution';
    ''').getSingle();
    expect(localContribution.read<String>('goal_id'), 'same-goal');
    expect(localContribution.read<int>('amount_minor'), 500);
    expect(localContribution.read<double>('amount'), 5);
    expect(localContribution.read<String?>('note'), 'keep me');

    final second = await importer.importPackage(package, ImportMode.merge);
    expect(second.skipped, 1,
        reason: 'the persisted import result makes quarantine idempotent');
    final contributionCount = await target
        .customSelect(
          "SELECT COUNT(*) AS n FROM goal_contributions WHERE goal_id='same-goal';",
        )
        .getSingle();
    expect(contributionCount.read<int>('n'), 1,
        reason: 're-import must not leave a partial or ambiguous row');
  });

  test('matching-currency merge imports a contribution exactly', () async {
    final source = await _database();
    final target = await _database();
    addTearDown(source.close);
    addTearDown(target.close);

    const now = '2026-08-01T00:00:00.000Z';
    await source.customStatement('''
      INSERT INTO goals(id,name,currency,target_amount,target_amount_minor,saved_amount,
        saved_amount_minor,vault_skin,status,created_at,last_notified_saved_amount,
        last_notified_saved_amount_minor)
      VALUES('matching-goal','Package KWD goal','KWD',1000,1000000,0,0,
        'default','active','$now',0,0);
    ''');
    await source.customStatement('''
      INSERT INTO goal_contributions(id,goal_id,amount,amount_minor,created_at)
      VALUES('matching-contribution','matching-goal',12.345,12345,'$now');
    ''');
    await target.customStatement('''
      INSERT INTO goals(id,name,currency,target_amount,target_amount_minor,saved_amount,
        saved_amount_minor,vault_skin,status,created_at,last_notified_saved_amount,
        last_notified_saved_amount_minor)
      VALUES('matching-goal','Local KWD goal','KWD',500,500000,0,0,
        'default','active','$now',0,0);
    ''');

    final package = decodeQirshPackage(
      (await DriftFinancialExporter(source).exportFinancialPackage()).bytes,
    );
    final result = await DriftFinancialImporter(target)
        .importPackage(package, ImportMode.merge);
    expect(result.skipped, 0);

    final contribution = await target.customSelect('''
      SELECT amount,amount_minor FROM goal_contributions
      WHERE id='matching-contribution';
    ''').getSingle();
    expect(contribution.read<int>('amount_minor'), 12345);
    expect(contribution.read<double>('amount'), 12.345);
  });

  test('exported planning money survives import with exact canonical minors',
      () async {
    final source = await _database();
    final target = await _database();
    addTearDown(source.close);
    addTearDown(target.close);

    final category = await source
        .customSelect("SELECT id FROM categories WHERE key = 'other' LIMIT 1;")
        .getSingle();
    final categoryId = category.read<String>('id');

    // KWD (scale 3) makes the defect unmissable: a 2-decimal round-trip would
    // silently drop the third digit even if the minors were written at all.
    await source.customStatement(
      "UPDATE user_settings SET currency = 'KWD';",
    );
    await source.customStatement('''
      INSERT INTO budgets(id,category_id,currency,amount,amount_minor,period,start_date,
        is_active,last_notified_spent_amount,last_notified_spent_amount_minor,
        last_notified_period_start,show_on_header)
      VALUES('b1',?,'KWD',12.345,12345,'monthly','2026-01-01T00:00:00Z',1,
        1.5,1500,'2026-01-01T00:00:00Z',0);
    ''', [categoryId]);
    await source.customStatement('''
      INSERT INTO goals(id,name,currency,target_amount,target_amount_minor,
        saved_amount,saved_amount_minor,vault_skin,status,created_at,
        auto_save_amount,auto_save_amount_minor,auto_save_period,
        last_notified_saved_amount,last_notified_saved_amount_minor)
      VALUES('g1','هدف','KWD',1000.005,1000005,250.125,250125,'default','active',
        '2026-01-01T00:00:00Z',10.5,10500,'monthly',0,0);
    ''');
    await source.customStatement('''
      INSERT INTO goal_contributions(id,goal_id,amount,amount_minor,created_at)
      VALUES('c1','g1',0.125,125,'2026-01-01T00:00:00Z');
    ''');

    final exported =
        await DriftFinancialExporter(source).exportFinancialPackage();
    final package = decodeQirshPackage(exported.bytes);
    await DriftFinancialImporter(target)
        .importPackage(package, ImportMode.merge);

    await _expectNoNullPlanningMinors(target);

    // Exact identity, not "close enough".
    expect(await _minor(target, 'budgets', 'amount_minor', 'b1'), 12345);
    expect(
        await _minor(
            target, 'budgets', 'last_notified_spent_amount_minor', 'b1'),
        1500);
    expect(await _minor(target, 'goals', 'target_amount_minor', 'g1'), 1000005);
    expect(await _minor(target, 'goals', 'saved_amount_minor', 'g1'), 250125);
    expect(
        await _minor(target, 'goals', 'auto_save_amount_minor', 'g1'), 10500);
    expect(
        await _minor(target, 'goal_contributions', 'amount_minor', 'c1'), 125);

    // The currency authority must travel with the row, or the minors above are
    // meaningless (12345 means 12.345 KWD, but 123.45 in a 2-decimal currency).
    final budget = await target
        .customSelect("SELECT currency FROM budgets WHERE id = 'b1';")
        .getSingle();
    expect(budget.read<String?>('currency'), 'KWD');
    final goal = await target
        .customSelect("SELECT currency FROM goals WHERE id = 'g1';")
        .getSingle();
    expect(goal.read<String?>('currency'), 'KWD');
  });

  test('a pre-C-2 package (no currency column) still imports canonically',
      () async {
    // Backward compatibility: packages exported before the fix carry no
    // currency for these tables. The importer must fall back to the importing
    // device's base currency rather than leaving minors NULL.
    final source = await _database();
    final target = await _database();
    addTearDown(source.close);
    addTearDown(target.close);

    final category = await source
        .customSelect("SELECT id FROM categories WHERE key = 'other' LIMIT 1;")
        .getSingle();
    await source.customStatement('''
      INSERT INTO budgets(id,category_id,currency,amount,amount_minor,period,start_date,
        is_active,last_notified_spent_amount,last_notified_spent_amount_minor,
        last_notified_period_start,show_on_header)
      VALUES('b1',?,'SAR',1500.50,150050,'monthly','2026-01-01T00:00:00Z',1,
        0,0,'2026-01-01T00:00:00Z',0);
    ''', [category.read<String>('id')]);

    final exported =
        await DriftFinancialExporter(source).exportFinancialPackage();
    final full = decodeQirshPackage(exported.bytes);

    // Strip exact fields from every table and planning currency from the three
    // families that did not carry it, simulating a genuinely old package. This
    // intentionally exercises the documented lossy REAL fallback.
    final legacyTables = {
      for (final entry in full.tables.entries)
        entry.key: PortableCsvDocument(
          headers: entry.value.headers
              .where((h) => !h.endsWith('_minor'))
              .where((h) =>
                  h != 'currency' ||
                  !const {'budgets', 'goals', 'goal_contributions'}
                      .contains(entry.key))
              .toList(),
          rows: entry.value.rows
              .map((r) => {
                    for (final value in r.entries)
                      if (!value.key.endsWith('_minor') &&
                          (value.key != 'currency' ||
                              !const {'budgets', 'goals', 'goal_contributions'}
                                  .contains(entry.key)))
                        value.key: value.value,
                  })
              .toList(),
        ),
    };
    final legacy = QirshPackageData(
      packageId: full.packageId,
      exportedAt: full.exportedAt,
      tables: legacyTables,
    );

    await DriftFinancialImporter(target)
        .importPackage(legacy, ImportMode.merge);

    await _expectNoNullPlanningMinors(target);
    expect(await _minor(target, 'budgets', 'amount_minor', 'b1'), 150050,
        reason: 'base-currency fallback must still produce exact minors');
  });
}
