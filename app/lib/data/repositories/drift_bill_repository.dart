import 'package:drift/drift.dart';

import '../../core/utils/id_generator.dart';
import '../../domain/entities/bill_entity.dart';
import '../../domain/repositories/bill_repository.dart';
import '../../features/planning_sync/services/planning_outbox_queue.dart';
import '../db/app_database.dart';
import '../db/sql_value_codec.dart';

class DriftBillRepository implements BillRepository {
  DriftBillRepository(this._db, {PlanningOutboxQueue? outboxQueue})
      : _outboxQueue = outboxQueue;

  final AppDatabase _db;
  final PlanningOutboxQueue? _outboxQueue;

  @override
  Future<void> delete(String id) async {
    final existing = await getById(id);
    final now = dateTimeToSql(DateTime.now().toUtc());
    await _db.customUpdate(
      '''
      UPDATE subscriptions
      SET deleted_at = ?, status = 'cancelled'
      WHERE id = ?;
      ''',
      variables: [
        Variable.withString(now),
        Variable.withString(id),
      ],
    );
    if (existing != null) {
      await _outboxQueue?.enqueueSubscription(
        PlanningSyncOperation.delete,
        existing,
      );
    }
  }

  @override
  Future<List<BillEntity>> getAll() async {
    final rows = await _db.customSelect(
      '''
        SELECT s.*, m.raw_name AS merchant_name
        FROM subscriptions s
        LEFT JOIN merchants m ON m.id = s.merchant_id
        WHERE s.deleted_at IS NULL
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
          AND s.deleted_at IS NULL
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
          AND s.deleted_at IS NULL
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
            total_installments, paid_count, manual_paid_amount,
            total_purchase_amount,
            lender_name, interest_rate
          )
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
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
          bill.customIntervalDays == null
              ? const Variable<int>(null)
              : Variable.withInt(bill.customIntervalDays!),
          bill.note == null
              ? const Variable<String>(null)
              : Variable.withString(bill.note!),
          Variable.withString(dateTimeToSql(bill.createdAt.toUtc())),
          Variable.withString(bill.status.name),
          bill.accountId == null
              ? const Variable<String>(null)
              : Variable.withString(bill.accountId!),
          bill.totalInstallments == null
              ? const Variable<int>(null)
              : Variable.withInt(bill.totalInstallments!),
          bill.paidCount == null
              ? const Variable<int>(null)
              : Variable.withInt(bill.paidCount!),
          bill.manualPaidAmount == null
              ? const Variable<double>(null)
              : Variable.withReal(bill.manualPaidAmount!),
          bill.totalPurchaseAmount == null
              ? const Variable<double>(null)
              : Variable.withReal(bill.totalPurchaseAmount!),
          bill.lenderName == null
              ? const Variable<String>(null)
              : Variable.withString(bill.lenderName!),
          bill.interestRate == null
              ? const Variable<double>(null)
              : Variable.withReal(bill.interestRate!),
        ],
      );
      final saved = await getById(bill.id);
      if (saved != null) {
        await _outboxQueue?.enqueueSubscription(
          PlanningSyncOperation.create,
          saved,
        );
      }
    } else {
      await _db.customUpdate(
        '''
          UPDATE subscriptions
          SET merchant_id = ?, name = ?, amount = ?, currency = ?,
              period = ?, frequency = ?, type = ?, next_due_date = ?,
              is_confirmed = ?, reminder_on = ?, custom_interval_days = ?,
              note = ?, status = ?, account_id = ?,
              total_installments = ?, paid_count = ?, manual_paid_amount = ?,
              total_purchase_amount = ?,
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
          bill.customIntervalDays == null
              ? const Variable<int>(null)
              : Variable.withInt(bill.customIntervalDays!),
          bill.note == null
              ? const Variable<String>(null)
              : Variable.withString(bill.note!),
          Variable.withString(bill.status.name),
          bill.accountId == null
              ? const Variable<String>(null)
              : Variable.withString(bill.accountId!),
          bill.totalInstallments == null
              ? const Variable<int>(null)
              : Variable.withInt(bill.totalInstallments!),
          bill.paidCount == null
              ? const Variable<int>(null)
              : Variable.withInt(bill.paidCount!),
          bill.manualPaidAmount == null
              ? const Variable<double>(null)
              : Variable.withReal(bill.manualPaidAmount!),
          bill.totalPurchaseAmount == null
              ? const Variable<double>(null)
              : Variable.withReal(bill.totalPurchaseAmount!),
          bill.lenderName == null
              ? const Variable<String>(null)
              : Variable.withString(bill.lenderName!),
          bill.interestRate == null
              ? const Variable<double>(null)
              : Variable.withReal(bill.interestRate!),
          Variable.withString(bill.id),
        ],
      );
      final saved = await getById(bill.id);
      if (saved != null) {
        await _outboxQueue?.enqueueSubscription(
          PlanningSyncOperation.update,
          saved,
        );
      }
    }
    final saved = await getById(bill.id);
    if (saved == null) {
      throw StateError('Failed to save bill: ${bill.id}');
    }
    return saved;
  }

  @override
  Future<List<BillPaymentEntity>> getPayments(String billId) async {
    final rows = await _db.customSelect(
      '''
        SELECT * FROM bill_payments
        WHERE bill_id = ? AND deleted_at IS NULL
        ORDER BY paid_at DESC, period_start DESC;
      ''',
      variables: [Variable.withString(billId)],
    ).get();
    return rows.map(_paymentFromRow).toList(growable: false);
  }

  @override
  Future<BillPaymentEntity> recordPayment(BillPaymentEntity payment) async {
    await _db.customInsert(
      '''
        INSERT INTO bill_payments(
          id, bill_id, amount, currency, period_start, period_end, paid_at,
          installment_index, transaction_id, note
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
      ''',
      variables: [
        Variable.withString(payment.id),
        Variable.withString(payment.billId),
        Variable.withReal(payment.amount),
        Variable.withString(payment.currency),
        Variable.withString(dateTimeToSql(payment.periodStart.toUtc())),
        Variable.withString(dateTimeToSql(payment.periodEnd.toUtc())),
        Variable.withString(dateTimeToSql(payment.paidAt.toUtc())),
        payment.installmentIndex == null
            ? const Variable<int>(null)
            : Variable.withInt(payment.installmentIndex!),
        payment.transactionId == null
            ? const Variable<String>(null)
            : Variable.withString(payment.transactionId!),
        payment.note == null
            ? const Variable<String>(null)
            : Variable.withString(payment.note!),
      ],
    );

    final bill = await getById(payment.billId);
    if (bill?.type == BillType.installment) {
      final currentPaid = bill!.paidCount ?? 0;
      final requestedPaid = payment.installmentIndex ?? currentPaid + 1;
      final cappedPaid = bill.totalInstallments == null
          ? requestedPaid
          : requestedPaid.clamp(0, bill.totalInstallments!).toInt();
      final nextPaidCount = cappedPaid < currentPaid ? currentPaid : cappedPaid;
      await _db.customUpdate(
        '''
          UPDATE subscriptions
          SET paid_count = ?
          WHERE id = ?;
        ''',
        variables: [
          Variable.withInt(nextPaidCount),
          Variable.withString(payment.billId),
        ],
      );
    }

    final rows = await getPayments(payment.billId);
    return rows.firstWhere((item) => item.id == payment.id);
  }

  @override
  Future<BillPaymentEntity> createAndRecordPayment({
    required BillEntity bill,
    required BillPaymentEntity payment,
  }) async {
    final saved = await save(bill);
    return recordPayment(
      BillPaymentEntity(
        id: payment.id,
        billId: saved.id,
        amount: payment.amount,
        currency: payment.currency,
        periodStart: payment.periodStart,
        periodEnd: payment.periodEnd,
        paidAt: payment.paidAt,
        installmentIndex: payment.installmentIndex,
        transactionId: payment.transactionId,
        note: payment.note,
      ),
    );
  }

  @override
  Future<List<String>> deletePaymentForTransaction(String transactionId) async {
    var rows = await _db.customSelect(
      '''
        SELECT id, bill_id
        FROM bill_payments
        WHERE transaction_id = ?
          AND deleted_at IS NULL;
      ''',
      variables: [Variable.withString(transactionId)],
    ).get();

    if (rows.isEmpty) {
      rows = await _db.customSelect(
        '''
          SELECT bp.id, bp.bill_id
          FROM bill_payments bp
          JOIN subscriptions s ON s.id = bp.bill_id
          JOIN transactions t ON t.id = ?
          WHERE bp.transaction_id IS NULL
            AND bp.deleted_at IS NULL
            AND bp.amount = t.amount
            AND bp.currency = t.currency
            AND bp.paid_at = t.occurred_at
            AND (
              s.name = t.raw_merchant OR
              t.note LIKE '%' || s.name || '%'
            );
        ''',
        variables: [Variable.withString(transactionId)],
      ).get();
    }

    final billIds =
        rows.map((row) => row.read<String>('bill_id')).toList(growable: false);
    if (billIds.isEmpty) return const [];
    final paymentIds =
        rows.map((row) => row.read<String>('id')).toList(growable: false);

    for (final paymentId in paymentIds) {
      await _db.customUpdate(
        'UPDATE bill_payments SET deleted_at = ? WHERE id = ?;',
        variables: [
          Variable.withString(dateTimeToSql(DateTime.now().toUtc())),
          Variable.withString(paymentId),
        ],
      );
    }

    for (final billId in billIds) {
      final paidRow = await _db.customSelect(
        '''
          SELECT MAX(installment_index) AS paid_count
          FROM bill_payments
          WHERE bill_id = ?
            AND deleted_at IS NULL;
        ''',
        variables: [Variable.withString(billId)],
      ).getSingle();
      final paidCount = paidRow.readNullable<int>('paid_count') ?? 0;
      await _db.customUpdate(
        '''
          UPDATE subscriptions
          SET paid_count = ?
          WHERE id = ? AND type = 'installment';
        ''',
        variables: [
          Variable.withInt(paidCount),
          Variable.withString(billId),
        ],
      );
    }

    return billIds;
  }

  @override
  Future<void> deletePayment(String paymentId) async {
    await _db.customUpdate(
      'UPDATE bill_payments SET deleted_at = ? WHERE id = ?;',
      variables: [
        Variable.withString(dateTimeToSql(DateTime.now().toUtc())),
        Variable.withString(paymentId),
      ],
    );
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
      createdAt:
          created == null ? DateTime.now().toUtc() : dateTimeFromSql(created),
      status: _parseStatus(row.readNullable<String>('status')),
      accountId: row.readNullable<String>('account_id'),
      totalInstallments: row.readNullable<int>('total_installments'),
      paidCount: row.readNullable<int>('paid_count'),
      manualPaidAmount: row.readNullable<double>('manual_paid_amount'),
      totalPurchaseAmount: row.readNullable<double>('total_purchase_amount'),
      lenderName: row.readNullable<String>('lender_name'),
      interestRate: row.readNullable<double>('interest_rate'),
    );
  }

  BillPaymentEntity _paymentFromRow(QueryRow row) {
    return BillPaymentEntity(
      id: row.read<String>('id'),
      billId: row.read<String>('bill_id'),
      amount: row.read<double>('amount'),
      currency: row.read<String>('currency'),
      periodStart: dateTimeFromSql(row.read<String>('period_start')),
      periodEnd: dateTimeFromSql(row.read<String>('period_end')),
      paidAt: dateTimeFromSql(row.read<String>('paid_at')),
      installmentIndex: row.readNullable<int>('installment_index'),
      transactionId: row.readNullable<String>('transaction_id'),
      note: row.readNullable<String>('note'),
    );
  }

  BillType _parseType(String? value) => BillType.values.firstWhere(
        (type) => type.name == value,
        orElse: () => BillType.subscription,
      );

  BillFrequency _parseFrequency(String? value) =>
      BillFrequency.values.firstWhere(
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
