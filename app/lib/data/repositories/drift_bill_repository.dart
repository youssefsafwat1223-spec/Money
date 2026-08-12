import 'package:drift/drift.dart';

import '../../core/utils/id_generator.dart';
import '../../domain/entities/bill_entity.dart';
import '../../domain/repositories/bill_repository.dart';
import '../../features/planning_sync/services/planning_outbox_queue.dart';
import '../db/app_database.dart';
import '../db/money_codec.dart';
import '../db/sql_value_codec.dart';

class DriftBillRepository implements BillRepository {
  DriftBillRepository(this._db, {PlanningOutboxQueue? outboxQueue})
      : _outboxQueue = outboxQueue;

  final AppDatabase _db;
  final PlanningOutboxQueue? _outboxQueue;

  @override
  Future<void> delete(String id) async {
    await _db.transaction(() async {
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
    });
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
    return _db.transaction(() async {
      final existing = await getById(bill.id);
      final merchantId = bill.merchantId ?? await _merchantIdForName(bill.name);
      if (existing == null) {
        await _db.customInsert(
          '''
          INSERT INTO subscriptions(
            id, merchant_id, name, amount, amount_minor, currency, period, frequency, type,
            next_due_date, is_confirmed, reminder_on, custom_interval_days,
            note, created_at, status, account_id,
            total_installments, paid_count, manual_paid_amount, manual_paid_amount_minor,
            total_purchase_amount, total_purchase_amount_minor,
            lender_name, interest_rate
          )
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        ''',
          variables: [
            Variable.withString(bill.id),
            Variable.withString(merchantId),
            Variable.withString(bill.name),
            kMoneyCodec.realVar(bill.amountMoney),
            kMoneyCodec.minorVar(bill.amountMoney),
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
            kMoneyCodec.realVarOrNull(bill.manualPaidMoney),
            kMoneyCodec.minorVarOrNull(bill.manualPaidMoney),
            kMoneyCodec.realVarOrNull(bill.totalPurchaseMoney),
            kMoneyCodec.minorVarOrNull(bill.totalPurchaseMoney),
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
          SET merchant_id = ?, name = ?, amount = ?, amount_minor = ?, currency = ?,
              period = ?, frequency = ?, type = ?, next_due_date = ?,
              is_confirmed = ?, reminder_on = ?, custom_interval_days = ?,
              note = ?, status = ?, account_id = ?,
              total_installments = ?, paid_count = ?, manual_paid_amount = ?,
              manual_paid_amount_minor = ?, total_purchase_amount = ?,
              total_purchase_amount_minor = ?,
              lender_name = ?, interest_rate = ?
          WHERE id = ?;
        ''',
          variables: [
            Variable.withString(merchantId),
            Variable.withString(bill.name),
            kMoneyCodec.realVar(bill.amountMoney),
            kMoneyCodec.minorVar(bill.amountMoney),
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
            kMoneyCodec.realVarOrNull(bill.manualPaidMoney),
            kMoneyCodec.minorVarOrNull(bill.manualPaidMoney),
            kMoneyCodec.realVarOrNull(bill.totalPurchaseMoney),
            kMoneyCodec.minorVarOrNull(bill.totalPurchaseMoney),
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
    });
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
    return _db.transaction(() async {
      await _db.customInsert(
        '''
        INSERT INTO bill_payments(
          id, bill_id, amount, amount_minor, currency, period_start, period_end, paid_at,
          installment_index, transaction_id, note
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
      ''',
        variables: [
          Variable.withString(payment.id),
          Variable.withString(payment.billId),
          kMoneyCodec.realVar(payment.amountMoney),
          kMoneyCodec.minorVar(payment.amountMoney),
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

      await _recomputeInstallmentPaidCount(payment.billId);

      final rows = await getPayments(payment.billId);
      final saved = rows.firstWhere((item) => item.id == payment.id);
      await _outboxQueue?.enqueueBillPayment(
        PlanningSyncOperation.create,
        saved,
      );
      return saved;
    });
  }

  @override
  Future<BillPaymentEntity> createAndRecordPayment({
    required BillEntity bill,
    required BillPaymentEntity payment,
  }) async {
    return _db.transaction(() async {
      final saved = await save(bill);
      return recordPayment(
        BillPaymentEntity(
          id: payment.id,
          billId: saved.id,
          amountMoney: payment.amountMoney,
          currency: payment.currency,
          periodStart: payment.periodStart,
          periodEnd: payment.periodEnd,
          paidAt: payment.paidAt,
          installmentIndex: payment.installmentIndex,
          transactionId: payment.transactionId,
          note: payment.note,
        ),
      );
    });
  }

  @override
  Future<List<String>> deletePaymentForTransaction(String transactionId) async {
    return _db.transaction(() async {
      var rows = await _db.customSelect(
        '''
        SELECT *
        FROM bill_payments
        WHERE transaction_id = ?
          AND deleted_at IS NULL;
      ''',
        variables: [Variable.withString(transactionId)],
      ).get();

      if (rows.isEmpty) {
        rows = await _db.customSelect(
          '''
          SELECT bp.*
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

      final billIds = rows
          .map((row) => row.read<String>('bill_id'))
          .toList(growable: false);
      if (billIds.isEmpty) return const [];
      final payments = rows.map(_paymentFromRow).toList(growable: false);
      final paymentIds =
          payments.map((item) => item.id).toList(growable: false);

      for (final paymentId in paymentIds) {
        await _db.customUpdate(
          'UPDATE bill_payments SET deleted_at = ? WHERE id = ?;',
          variables: [
            Variable.withString(dateTimeToSql(DateTime.now().toUtc())),
            Variable.withString(paymentId),
          ],
        );
      }

      for (final payment in payments) {
        await _outboxQueue?.enqueueBillPayment(
          PlanningSyncOperation.delete,
          payment,
        );
      }

      for (final billId in billIds) {
        await _recomputeInstallmentPaidCount(billId);
      }

      return billIds;
    });
  }

  @override
  Future<void> deletePayment(String paymentId) async {
    await _db.transaction(() async {
      final row = await _db.customSelect(
        'SELECT * FROM bill_payments WHERE id = ? LIMIT 1;',
        variables: [Variable.withString(paymentId)],
      ).getSingleOrNull();
      final payment = row == null ? null : _paymentFromRow(row);
      await _db.customUpdate(
        'UPDATE bill_payments SET deleted_at = ? WHERE id = ?;',
        variables: [
          Variable.withString(dateTimeToSql(DateTime.now().toUtc())),
          Variable.withString(paymentId),
        ],
      );
      if (payment != null) {
        await _outboxQueue?.enqueueBillPayment(
          PlanningSyncOperation.delete,
          payment,
        );
        await _recomputeInstallmentPaidCount(payment.billId);
      }
    });
  }

  /// MALI-074n — the authoritative installment paid count: the number of
  /// DISTINCT settled installments in the ledger, for the bill's own currency,
  /// derived from `bill_payments` (never `MAX(installment_index)`, which
  /// fabricated 1..N from a single high index, and never a monotonic running
  /// counter). Duplicate-index rows collapse to one; deleted / foreign-currency
  /// payments never count; out-of-order indexes are safe (paying installment 5
  /// alone = 1). Called after every settle/delete so `paid_count` always mirrors
  /// the ledger.
  Future<void> _recomputeInstallmentPaidCount(String billId) async {
    final bill = await getById(billId);
    if (bill == null || bill.type != BillType.installment) return;
    final row = await _db.customSelect(
      '''
        SELECT
          (SELECT COUNT(DISTINCT installment_index) FROM bill_payments
             WHERE bill_id = ? AND deleted_at IS NULL
               AND installment_index IS NOT NULL
               AND UPPER(currency) = UPPER(?))
          +
          (SELECT COUNT(*) FROM bill_payments
             WHERE bill_id = ? AND deleted_at IS NULL
               AND installment_index IS NULL
               AND UPPER(currency) = UPPER(?)) AS paid;
      ''',
      variables: [
        Variable.withString(billId),
        Variable.withString(bill.currency),
        Variable.withString(billId),
        Variable.withString(bill.currency),
      ],
    ).getSingle();
    var paid = row.read<int>('paid');
    final total = bill.totalInstallments;
    if (total != null) paid = paid.clamp(0, total).toInt();
    await _db.customUpdate(
      "UPDATE subscriptions SET paid_count = ? WHERE id = ? AND type = 'installment';",
      variables: [Variable.withInt(paid), Variable.withString(billId)],
    );
  }

  BillEntity _fromRow(QueryRow row) {
    final name = row.readNullable<String>('name');
    final merchantName = row.readNullable<String>('merchant_name');
    final due = row.readNullable<String>('next_due_date');
    final created = row.readNullable<String>('created_at');
    final currency = row.read<String>('currency');
    final period = row.readNullable<String>('frequency') ??
        row.readNullable<String>('period') ??
        'monthly';
    return BillEntity(
      id: row.read<String>('id'),
      merchantId: row.readNullable<String>('merchant_id'),
      name: (name == null || name.isEmpty) ? (merchantName ?? 'فاتورة') : name,
      amountMoney: kMoneyCodec.readColumn(row, 'amount', currency),
      currency: currency,
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
      manualPaidMoney:
          kMoneyCodec.readColumnNullable(row, 'manual_paid_amount', currency),
      totalPurchaseMoney: kMoneyCodec.readColumnNullable(
          row, 'total_purchase_amount', currency),
      lenderName: row.readNullable<String>('lender_name'),
      interestRate: row.readNullable<double>('interest_rate'),
    );
  }

  BillPaymentEntity _paymentFromRow(QueryRow row) {
    final currency = row.read<String>('currency');
    return BillPaymentEntity(
      id: row.read<String>('id'),
      billId: row.read<String>('bill_id'),
      amountMoney: kMoneyCodec.readColumn(row, 'amount', currency),
      currency: currency,
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
