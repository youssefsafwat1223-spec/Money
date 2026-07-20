import 'dart:typed_data';

import '../../data/db/app_database.dart';
import '../../core/utils/id_generator.dart';
import 'data_portability_models.dart';
import 'portable_csv.dart';
import 'qirsh_package_codec.dart';

class DriftFinancialExporter {
  const DriftFinancialExporter(this._db);

  final AppDatabase _db;

  Future<ExportedFile> exportTransactionsCsv() async {
    final rows = await _db.customSelect('''
      SELECT
        t.id AS record_id,
        t.occurred_at,
        t.amount,
        t.currency,
        COALESCE(t.direction, 'unknown') AS direction,
        t.type,
        t.source,
        t.status,
        t.raw_merchant AS merchant,
        c.key AS category_key,
        c.name_ar AS category,
        a.name AS account,
        t.card_last4,
        t.balance_after,
        t.foreign_amount,
        t.foreign_currency,
        t.note
      FROM transactions t
      LEFT JOIN accounts a ON a.id = t.account_id
      LEFT JOIN categories c ON c.id = t.category_id
      WHERE t.status != 'ignored'
      ORDER BY t.occurred_at ASC, t.id ASC;
    ''').get();
    final headers = rows.isEmpty
        ? _transactionExportHeaders
        : rows.first.data.keys.toList(growable: false);
    final bytes = _encodeRows(headers, rows.map((row) => row.data));
    return ExportedFile(
      name: 'qirsh-transactions-${_dateStamp()}.csv',
      mimeType: 'text/csv',
      bytes: bytes,
      recordCount: rows.length,
    );
  }

  Future<ExportedFile> exportFinancialPackage() async {
    final csvFiles = <String, Uint8List>{};
    var recordCount = 0;
    for (final spec in _tableSpecs) {
      final rows = await _db.customSelect(spec.sql).get();
      final headers = rows.isEmpty
          ? spec.headers
          : rows.first.data.keys.toList(growable: false);
      csvFiles['${spec.name}.csv'] =
          _encodeRows(headers, rows.map((row) => row.data));
      recordCount += rows.length;
    }
    final now = DateTime.now().toUtc();
    final bytes = encodeQirshPackage(
      packageId: IdGenerator.next(),
      exportedAt: now,
      csvFiles: csvFiles,
    );
    return ExportedFile(
      name: 'qirsh-data-${_dateStamp(now)}.zip',
      mimeType: 'application/zip',
      bytes: bytes,
      recordCount: recordCount,
    );
  }

  Uint8List _encodeRows(
    List<String> headers,
    Iterable<Map<String, Object?>> rows,
  ) {
    return encodePortableCsv(
      headers,
      rows.map((row) => [for (final header in headers) row[header]]),
    );
  }

  String _dateStamp([DateTime? value]) {
    final date = (value ?? DateTime.now()).toUtc();
    String two(int number) => number.toString().padLeft(2, '0');
    return '${date.year}-${two(date.month)}-${two(date.day)}';
  }
}

const _transactionExportHeaders = [
  'record_id',
  'occurred_at',
  'amount',
  'currency',
  'direction',
  'type',
  'source',
  'status',
  'merchant',
  'category_key',
  'category',
  'account',
  'card_last4',
  'balance_after',
  'foreign_amount',
  'foreign_currency',
  'note',
];

class _ExportTableSpec {
  const _ExportTableSpec(this.name, this.headers, this.sql);

  final String name;
  final List<String> headers;
  final String sql;
}

const _tableSpecs = <_ExportTableSpec>[
  _ExportTableSpec('accounts', [
    'record_id',
    'name',
    'currency',
    'type',
    'initial_balance',
    'current_balance',
    'is_default',
    'sort_order',
    'created_at',
    'updated_at',
  ], '''
    SELECT id AS record_id, name, currency, type, initial_balance,
           current_balance, is_default, sort_order, created_at, updated_at
    FROM accounts WHERE deleted_at IS NULL ORDER BY sort_order, id;
  '''),
  _ExportTableSpec('custom_categories', [
    'record_id',
    'key',
    'name_ar',
    'icon',
    'color',
    'is_income',
    'sort_order',
  ], '''
    SELECT id AS record_id, key, name_ar, icon, color, is_income, sort_order
    FROM categories
    WHERE key GLOB 'custom_*' AND deleted_at IS NULL
    ORDER BY sort_order, id;
  '''),
  _ExportTableSpec('transactions', [
    'record_id',
    'account_record_id',
    'amount',
    'currency',
    'merchant',
    'category_record_id',
    'category_key',
    'type',
    'source',
    'card_last4',
    'balance_after',
    'note',
    'occurred_at',
    'status',
    'created_at',
    'updated_at',
    'foreign_amount',
    'foreign_currency',
    'direction',
    'transaction_time_from_sms',
    'sms_received_at',
    'comparison_timestamp',
    'comparison_timestamp_source',
    'duplicate_status',
    'possible_duplicate_record_id',
    'duplicate_reason',
  ], '''
    SELECT t.id AS record_id, t.account_id AS account_record_id, t.amount,
           t.currency, t.raw_merchant AS merchant,
           t.category_id AS category_record_id, c.key AS category_key,
           t.type, t.source, t.card_last4, t.balance_after, t.note,
           t.occurred_at, t.status, t.created_at, t.updated_at,
           t.foreign_amount, t.foreign_currency, t.direction,
           t.transaction_time_from_sms, t.sms_received_at,
           t.comparison_timestamp, t.comparison_timestamp_source,
           t.duplicate_status,
           t.possible_duplicate_of_transaction_id AS possible_duplicate_record_id,
           t.duplicate_reason
    FROM transactions t
    LEFT JOIN categories c ON c.id = t.category_id
    WHERE t.status != 'ignored'
    ORDER BY t.occurred_at, t.id;
  '''),
  _ExportTableSpec('budgets', [
    'record_id',
    'account_record_id',
    'category_record_id',
    'category_key',
    'amount',
    'period',
    'start_date',
    'is_active',
    'last_notified_spent_amount',
    'last_notified_period_start',
    'show_on_header',
  ], '''
    SELECT b.id AS record_id, b.account_id AS account_record_id,
           b.category_id AS category_record_id, c.key AS category_key,
           b.amount, b.period, b.start_date, b.is_active,
           b.last_notified_spent_amount, b.last_notified_period_start, b.show_on_header
    FROM budgets b LEFT JOIN categories c ON c.id = b.category_id
    WHERE b.deleted_at IS NULL ORDER BY b.id;
  '''),
  _ExportTableSpec('subscriptions', [
    'record_id',
    'account_record_id',
    'merchant',
    'name',
    'amount',
    'currency',
    'period',
    'frequency',
    'type',
    'next_due_date',
    'is_confirmed',
    'reminder_on',
    'custom_interval_days',
    'note',
    'created_at',
    'status',
    'total_installments',
    'paid_count',
    'manual_paid_amount',
    'total_purchase_amount',
    'lender_name',
    'interest_rate',
  ], '''
    SELECT s.id AS record_id, s.account_id AS account_record_id,
           m.raw_name AS merchant, s.name, s.amount, s.currency, s.period,
           s.frequency, s.type, s.next_due_date, s.is_confirmed,
           s.reminder_on, s.custom_interval_days, s.note, s.created_at,
           s.status, s.total_installments, s.paid_count,
           s.manual_paid_amount, s.total_purchase_amount, s.lender_name,
           s.interest_rate
    FROM subscriptions s LEFT JOIN merchants m ON m.id = s.merchant_id
    WHERE s.deleted_at IS NULL ORDER BY s.id;
  '''),
  _ExportTableSpec('bill_payments', [
    'record_id',
    'subscription_record_id',
    'amount',
    'currency',
    'period_start',
    'period_end',
    'paid_at',
    'installment_index',
    'transaction_record_id',
    'note',
  ], '''
    SELECT id AS record_id, bill_id AS subscription_record_id, amount,
           currency, period_start, period_end, paid_at, installment_index,
           transaction_id AS transaction_record_id, note
    FROM bill_payments WHERE deleted_at IS NULL ORDER BY paid_at, id;
  '''),
  _ExportTableSpec('goals', [
    'record_id',
    'account_record_id',
    'name',
    'target_amount',
    'saved_amount',
    'deadline',
    'vault_skin',
    'status',
    'created_at',
    'auto_save_amount',
    'auto_save_period',
    'auto_save_last_run',
    'last_notified_saved_amount',
  ], '''
    SELECT id AS record_id, account_id AS account_record_id, name,
           target_amount, saved_amount, deadline, vault_skin, status,
           created_at, auto_save_amount, auto_save_period, auto_save_last_run,
           last_notified_saved_amount
    FROM goals WHERE deleted_at IS NULL ORDER BY id;
  '''),
  _ExportTableSpec('goal_contributions', [
    'record_id',
    'goal_record_id',
    'amount',
    'created_at',
    'note',
  ], '''
    SELECT id AS record_id, goal_id AS goal_record_id, amount, created_at, note
    FROM goal_contributions WHERE deleted_at IS NULL ORDER BY created_at, id;
  '''),
  _ExportTableSpec('plans', [
    'record_id',
    'name',
    'budget_amount',
    'currency',
    'start_date',
    'end_date',
    'account_record_ids',
    'card_last4s',
    'status',
    'icon',
    'created_at',
  ], '''
    SELECT id AS record_id, name, budget_amount, currency, start_date,
           end_date, account_ids AS account_record_ids, card_last4s,
           status, icon, created_at
    FROM plans WHERE deleted_at IS NULL ORDER BY id;
  '''),
  _ExportTableSpec('plan_transaction_links', [
    'plan_record_id',
    'transaction_record_id',
    'created_at',
  ], '''
    SELECT plan_id AS plan_record_id, transaction_id AS transaction_record_id,
           created_at
    FROM plan_transaction_links WHERE deleted_at IS NULL
    ORDER BY plan_id, transaction_id;
  '''),
];
