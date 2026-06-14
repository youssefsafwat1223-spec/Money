import 'package:drift/drift.dart';

import '../../core/utils/id_generator.dart';
import '../../domain/entities/bill_entity.dart';
import '../../domain/repositories/bill_repository.dart';
import '../db/app_database.dart';
import '../db/sql_value_codec.dart';

class DriftBillRepository implements BillRepository {
  DriftBillRepository(this._db);

  final AppDatabase _db;

  @override
  Future<void> delete(String id) async {
    await _db.customUpdate(
      'DELETE FROM subscriptions WHERE id = ?;',
      variables: [Variable.withString(id)],
    );
  }

  @override
  Future<List<BillEntity>> getAll() async {
    final rows = await _db.customSelect(
      '''
        SELECT s.*, m.raw_name AS merchant_name
        FROM subscriptions s
        LEFT JOIN merchants m ON m.id = s.merchant_id
        ORDER BY s.next_due_date ASC, s.amount DESC;
      ''',
    ).get();
    return rows.map(_fromRow).toList();
  }

  @override
  Future<BillEntity?> getById(String id) async {
    final row = await _db.customSelect(
      '''
        SELECT s.*, m.raw_name AS merchant_name
        FROM subscriptions s
        LEFT JOIN merchants m ON m.id = s.merchant_id
        WHERE s.id = ?
        LIMIT 1;
      ''',
      variables: [Variable.withString(id)],
    ).getSingleOrNull();
    return row == null ? null : _fromRow(row);
  }

  @override
  Future<List<BillEntity>> getDueBetween({
    required DateTime from,
    required DateTime to,
  }) async {
    final rows = await _db.customSelect(
      '''
        SELECT s.*, m.raw_name AS merchant_name
        FROM subscriptions s
        LEFT JOIN merchants m ON m.id = s.merchant_id
        WHERE s.next_due_date IS NOT NULL
          AND s.next_due_date BETWEEN ? AND ?
        ORDER BY s.next_due_date ASC, s.amount DESC;
      ''',
      variables: [
        Variable.withString(dateTimeToSql(from.toUtc())),
        Variable.withString(dateTimeToSql(to.toUtc())),
      ],
    ).get();
    return rows.map(_fromRow).toList();
  }

  @override
  Future<BillEntity> save(BillEntity bill) async {
    final existing = await getById(bill.id);
    final merchantId = bill.merchantId ?? await _merchantIdForName(bill.name);
    if (existing == null) {
      await _db.customInsert(
        '''
          INSERT INTO subscriptions(
            id, merchant_id, name, amount, currency, period, frequency, type,
            next_due_date, is_confirmed, reminder_on, custom_interval_days,
            note, created_at, status, account_id,
            total_installments, paid_count, total_purchase_amount,
            lender_name, interest_rate
          )
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        ''',
        variables: [
          Variable.withString(bill.id),
          Variable.withString(merchantId),
          Variable.withString(bill.name),
          Variable.withReal(bill.amount),
          Variable.withString(bill.currency),
          Variable.withString(bill.frequency.name),
          Variable.withString(bill.frequency.name),
          Variable.withString(bill.type.name),
          Variable.withString(dateTimeToSql(bill.nextDueDate.toUtc())),
          Variable.withInt(boolToSql(bill.isConfirmed)),
          Variable.withInt(boolToSql(bill.reminderOn)),
          bill.customIntervalDays == null ? const Variable<int>(null) : Variable.withInt(bill.customIntervalDays!),
          bill.note == null ? const Variable<String>(null) : Variable.withString(bill.note!),
          Variable.withString(dateTimeToSql(bill.createdAt.toUtc())),
          Variable.withString(bill.status.name),
          bill.accountId == null ? const Variable<String>(null) : Variable.withString(bill.accountId!),
          bill.totalInstallments == null ? const Variable<int>(null) : Variable.withInt(bill.totalInstallments!),
          bill.paidCount == null ? const Variable<int>(null) : Variable.withInt(bill.paidCount!),
          bill.totalPurchaseAmount == null ? const Variable<double>(null) : Variable.withReal(bill.totalPurchaseAmount!),
          bill.lenderName == null ? const Variable<String>(null) : Variable.withString(bill.lenderName!),
          bill.interestRate == null ? const Variable<double>(null) : Variable.withReal(bill.interestRate!),
        ],
      );
    } else {
      await _db.customUpdate(
        '''
          UPDATE subscriptions
          SET merchant_id = ?, name = ?, amount = ?, currency = ?,
              period = ?, frequency = ?, type = ?, next_due_date = ?,
              is_confirmed = ?, reminder_on = ?, custom_interval_days = ?,
              note = ?, status = ?, account_id = ?,
              total_installments = ?, paid_count = ?, total_purchase_amount = ?,
              lender_name = ?, interest_rate = ?
          WHERE id = ?;
        ''',
        variables: [
          Variable.withString(merchantId),
          Variable.withString(bill.name),
          Variable.withReal(bill.amount),
          Variable.withString(bill.currency),
          Variable.withString(bill.frequency.name),
          Variable.withString(bill.frequency.name),
          Variable.withString(bill.type.name),
          Variable.withString(dateTimeToSql(bill.nextDueDate.toUtc())),
          Variable.withInt(boolToSql(bill.isConfirmed)),
          Variable.withInt(boolToSql(bill.reminderOn)),
          bill.customIntervalDays == null ? const Variable<int>(null) : Variable.withInt(bill.customIntervalDays!),
          bill.note == null ? const Variable<String>(null) : Variable.withString(bill.note!),
          Variable.withString(bill.status.name),
          bill.accountId == null ? const Variable<String>(null) : Variable.withString(bill.accountId!),
          bill.totalInstallments == null ? const Variable<int>(null) : Variable.withInt(bill.totalInstallments!),
          bill.paidCount == null ? const Variable<int>(null) : Variable.withInt(bill.paidCount!),
          bill.totalPurchaseAmount == null ? const Variable<double>(null) : Variable.withReal(bill.totalPurchaseAmount!),
          bill.lenderName == null ? const Variable<String>(null) : Variable.withString(bill.lenderName!),
          bill.interestRate == null ? const Variable<double>(null) : Variable.withReal(bill.interestRate!),
          Variable.withString(bill.id),
        ],
      );
    }
    final saved = await getById(bill.id);
    if (saved == null) {
      throw StateError('Failed to save bill: ${bill.id}');
    }
    return saved;
  }

  BillEntity _fromRow(QueryRow row) {
    final name = row.readNullable<String>('name');
    final merchantName = row.readNullable<String>('merchant_name');
    final due = row.readNullable<String>('next_due_date');
    final created = row.readNullable<String>('created_at');
    final period = row.readNullable<String>('frequency') ??
        row.readNullable<String>('period') ??
        'monthly';
    return BillEntity(
      id: row.read<String>('id'),
      merchantId: row.readNullable<String>('merchant_id'),
      name: (name == null || name.isEmpty) ? (merchantName ?? 'فاتورة') : name,
      amount: row.read<double>('amount'),
      currency: row.readNullable<String>('currency') ?? 'SAR',
      type: _parseType(row.readNullable<String>('type')),
      frequency: _parseFrequency(period),
      nextDueDate: due == null ? DateTime.now().toUtc() : dateTimeFromSql(due),
      reminderOn: sqlToBool(row.read<int>('reminder_on')),
      isConfirmed: sqlToBool(row.read<int>('is_confirmed')),
      customIntervalDays: row.readNullable<int>('custom_interval_days'),
      note: row.readNullable<String>('note'),
      createdAt: created == null ? DateTime.now().toUtc() : dateTimeFromSql(created),
      status: _parseStatus(row.readNullable<String>('status')),
      accountId: row.readNullable<String>('account_id'),
      totalInstallments: row.readNullable<int>('total_installments'),
      paidCount: row.readNullable<int>('paid_count'),
      totalPurchaseAmount: row.readNullable<double>('total_purchase_amount'),
      lenderName: row.readNullable<String>('lender_name'),
      interestRate: row.readNullable<double>('interest_rate'),
    );
  }

  BillType _parseType(String? value) => BillType.values.firstWhere(
        (type) => type.name == value,
        orElse: () => BillType.subscription,
      );

  BillFrequency _parseFrequency(String? value) => BillFrequency.values.firstWhere(
        (frequency) => frequency.name == value,
        orElse: () => BillFrequency.monthly,
      );

  BillStatus _parseStatus(String? value) => BillStatus.values.firstWhere(
        (s) => s.name == value,
        orElse: () => BillStatus.active,
      );

  Future<String> _merchantIdForName(String name) async {
    final normalized = AppDatabase.normalizeMerchant(name);
    final existing = await _db.customSelect(
      'SELECT id FROM merchants WHERE normalized_name = ? LIMIT 1;',
      variables: [Variable.withString(normalized)],
    ).getSingleOrNull();
    if (existing != null) {
      return existing.read<String>('id');
    }
    final now = DateTime.now().toUtc();
    final id = IdGenerator.next();
    await _db.customInsert(
      '''
        INSERT INTO merchants(id, raw_name, normalized_name, first_seen_at, last_seen_at)
        VALUES (?, ?, ?, ?, ?);
      ''',
      variables: [
        Variable.withString(id),
        Variable.withString(name),
        Variable.withString(normalized),
        Variable.withString(dateTimeToSql(now)),
        Variable.withString(dateTimeToSql(now)),
      ],
    );
    return id;
  }
}
