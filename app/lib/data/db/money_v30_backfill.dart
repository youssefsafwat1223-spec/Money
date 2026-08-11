import '../../domain/finance/currency_scale.dart';
import '../../domain/finance/decimal_minor.dart';
import 'app_database.dart';

/// MALI-026 (Phase-8 B8-3 §5/§6/§7) — the v30 NON-PLANNING money backfill:
/// legacy REAL -> checked int64 minor, run inside the v30 upgrade transaction.
///
/// Only the 13 fields whose currency authority is unambiguous (each row carries
/// its own `currency`, or `foreign_currency` for the foreign leg) are converted
/// here. Planning money (budgets/goals/goal_contributions) is STRUCTURAL ONLY at
/// upgrade (§8) and is converted later by the app-level cutover executor.

class V30MoneyBackfillField {
  const V30MoneyBackfillField({
    required this.table,
    required this.realColumn,
    required this.minorColumn,
    required this.currencyColumn,
    required this.nullable,
  });
  final String table;
  final String realColumn;
  final String minorColumn;
  final String currencyColumn;
  final bool nullable;
}

/// The 13 non-planning money fields (currency in-row; no external authority).
const List<V30MoneyBackfillField> kV30NonPlanningBackfill = [
  V30MoneyBackfillField(
      table: 'transactions',
      realColumn: 'amount',
      minorColumn: 'amount_minor',
      currencyColumn: 'currency',
      nullable: false),
  V30MoneyBackfillField(
      table: 'transactions',
      realColumn: 'balance_after',
      minorColumn: 'balance_after_minor',
      currencyColumn: 'currency',
      nullable: true),
  V30MoneyBackfillField(
      table: 'transactions',
      realColumn: 'foreign_amount',
      minorColumn: 'foreign_amount_minor',
      currencyColumn: 'foreign_currency',
      nullable: true),
  V30MoneyBackfillField(
      table: 'accounts',
      realColumn: 'initial_balance',
      minorColumn: 'initial_balance_minor',
      currencyColumn: 'currency',
      nullable: true),
  V30MoneyBackfillField(
      table: 'accounts',
      realColumn: 'current_balance',
      minorColumn: 'current_balance_minor',
      currencyColumn: 'currency',
      nullable: true),
  V30MoneyBackfillField(
      table: 'accounts',
      realColumn: 'credit_limit',
      minorColumn: 'credit_limit_minor',
      currencyColumn: 'currency',
      nullable: true),
  V30MoneyBackfillField(
      table: 'accounts',
      realColumn: 'available_credit',
      minorColumn: 'available_credit_minor',
      currencyColumn: 'currency',
      nullable: true),
  V30MoneyBackfillField(
      table: 'subscriptions',
      realColumn: 'amount',
      minorColumn: 'amount_minor',
      currencyColumn: 'currency',
      nullable: false),
  V30MoneyBackfillField(
      table: 'subscriptions',
      realColumn: 'manual_paid_amount',
      minorColumn: 'manual_paid_amount_minor',
      currencyColumn: 'currency',
      nullable: true),
  V30MoneyBackfillField(
      table: 'subscriptions',
      realColumn: 'total_purchase_amount',
      minorColumn: 'total_purchase_amount_minor',
      currencyColumn: 'currency',
      nullable: true),
  V30MoneyBackfillField(
      table: 'bill_payments',
      realColumn: 'amount',
      minorColumn: 'amount_minor',
      currencyColumn: 'currency',
      nullable: false),
  V30MoneyBackfillField(
      table: 'plans',
      realColumn: 'budget_amount',
      minorColumn: 'budget_amount_minor',
      currencyColumn: 'currency',
      nullable: false),
  V30MoneyBackfillField(
      table: 'suspected_duplicates',
      realColumn: 'amount',
      minorColumn: 'amount_minor',
      currencyColumn: 'currency',
      nullable: false),
];

/// (table, minorColumn) for ALL 20 persisted money fields — the additive column
/// set added at v30 (13 non-planning above + the 7 planning fields, which are
/// structural-only at upgrade). Kept in lockstep with `kMoneyFields`.
class V30MinorColumn {
  const V30MinorColumn(this.table, this.minorColumn);
  final String table;
  final String minorColumn;
}

const List<V30MinorColumn> kV30MinorColumns = [
  V30MinorColumn('transactions', 'amount_minor'),
  V30MinorColumn('transactions', 'balance_after_minor'),
  V30MinorColumn('transactions', 'foreign_amount_minor'),
  V30MinorColumn('accounts', 'initial_balance_minor'),
  V30MinorColumn('accounts', 'current_balance_minor'),
  V30MinorColumn('accounts', 'credit_limit_minor'),
  V30MinorColumn('accounts', 'available_credit_minor'),
  V30MinorColumn('subscriptions', 'amount_minor'),
  V30MinorColumn('subscriptions', 'manual_paid_amount_minor'),
  V30MinorColumn('subscriptions', 'total_purchase_amount_minor'),
  V30MinorColumn('bill_payments', 'amount_minor'),
  V30MinorColumn('plans', 'budget_amount_minor'),
  V30MinorColumn('suspected_duplicates', 'amount_minor'),
  // Planning (structural-only at upgrade; filled by the cutover executor):
  V30MinorColumn('budgets', 'amount_minor'),
  V30MinorColumn('budgets', 'last_notified_spent_amount_minor'),
  V30MinorColumn('goals', 'target_amount_minor'),
  V30MinorColumn('goals', 'saved_amount_minor'),
  V30MinorColumn('goals', 'last_notified_saved_amount_minor'),
  V30MinorColumn('goals', 'auto_save_amount_minor'),
  V30MinorColumn('goal_contributions', 'amount_minor'),
];

/// Thrown when a non-planning row cannot be safely canonicalized — aborts the
/// whole v30 upgrade transaction (§6). Privacy-safe: identifies the field, never
/// the amount.
class V30MigrationException implements Exception {
  const V30MigrationException(this.message);
  final String message;
  @override
  String toString() => 'V30MigrationException: $message';
}

/// §6 preflight + §5 backfill in one pass: every non-null legacy REAL in a
/// non-planning money column is validated (currency present + supported, REAL
/// finite via [legacyRealToMinor], fits int64) and written to its `_minor`
/// column. Any invalid row THROWS — rolling the upgrade transaction back. Only
/// rows whose minor is still NULL are touched (idempotent / repeatable).
Future<void> backfillNonPlanningMoneyV30(AppDatabase db) async {
  for (final f in kV30NonPlanningBackfill) {
    final rows = await db.customSelect(
      'SELECT id AS id, ${f.realColumn} AS real, ${f.currencyColumn} AS cur '
      'FROM ${f.table} '
      'WHERE ${f.realColumn} IS NOT NULL AND ${f.minorColumn} IS NULL;',
    ).get();
    for (final row in rows) {
      final real = row.read<double>('real');
      final cur = row.readNullable<String>('cur');
      if (cur == null || cur.isEmpty) {
        throw V30MigrationException(
            '${f.table}.${f.realColumn}: missing ${f.currencyColumn} authority');
      }
      if (!isSupportedCurrency(cur)) {
        throw V30MigrationException(
            '${f.table}.${f.realColumn}: unsupported currency "$cur"');
      }
      // Throws DecimalFormatException (non-finite) / MoneyOverflowException
      // (outside int64) — both abort the migration. NEVER round(real*scale).
      final int minor;
      try {
        minor = legacyRealToMinor(real, currencyScale(cur));
      } on Object catch (e) {
        throw V30MigrationException('${f.table}.${f.realColumn}: $e');
      }
      await db.customStatement(
        'UPDATE ${f.table} SET ${f.minorColumn} = ? WHERE id = ?;',
        [minor, row.read<String>('id')],
      );
    }
  }
}

/// §7 postflight (no epsilon): for every non-planning money field prove
///   legacyRealToMinor(oldReal, resolvedCurrency) == storedMinor  (exactly),
/// and  legacy NULL <-> minor NULL, and required non-null values -> non-null
/// minor. Any mismatch THROWS before the version bump commits.
Future<void> verifyNonPlanningMoneyV30(AppDatabase db) async {
  for (final f in kV30NonPlanningBackfill) {
    final rows = await db.customSelect(
      'SELECT ${f.realColumn} AS real, ${f.minorColumn} AS minor, '
      '${f.currencyColumn} AS cur FROM ${f.table};',
    ).get();
    for (final row in rows) {
      final real = row.readNullable<double>('real');
      final minor = row.readNullable<int>('minor');
      if (real == null) {
        if (minor != null) {
          throw V30MigrationException(
              '${f.table}.${f.minorColumn}: minor non-null for NULL REAL');
        }
        continue; // legacy NULL <-> minor NULL
      }
      if (minor == null) {
        throw V30MigrationException(
            '${f.table}.${f.minorColumn}: required minor is NULL');
      }
      final cur = row.readNullable<String>('cur');
      if (cur == null || !isSupportedCurrency(cur)) {
        throw V30MigrationException(
            '${f.table}.${f.realColumn}: currency authority invalid at postflight');
      }
      final expected = legacyRealToMinor(real, currencyScale(cur));
      if (minor != expected) {
        throw V30MigrationException(
            '${f.table}.${f.minorColumn}: round-trip mismatch (stored=$minor expected=$expected)');
      }
    }
  }
}
