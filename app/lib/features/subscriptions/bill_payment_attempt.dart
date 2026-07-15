import '../../core/utils/id_generator.dart';
import '../../domain/entities/bill_entity.dart';
import '../../domain/entities/transaction_entity.dart';

/// Keeps one logical bill-payment attempt stable across double taps, timeouts,
/// and explicit retries while its dialog remains open.
class BillPaymentAttempt {
  BillPaymentAttempt({String? requestId, DateTime? paidAt})
      : requestId = requestId ?? IdGenerator.next(),
        paidAt = paidAt ?? DateTime.now().toUtc();

  final String requestId;
  final DateTime paidAt;

  BillPaymentEntity? _payment;
  TransactionEntity? _transaction;
  Future<void>? _inFlight;

  BillPaymentEntity? get payment => _payment;
  bool get hasTransaction => _transaction != null;

  Future<void> submit({
    required BillPaymentEntity Function(String requestId, DateTime paidAt)
        buildPayment,
    required Future<TransactionEntity> Function(BillPaymentEntity payment)
        createTransaction,
    required Future<void> Function(BillPaymentEntity payment) recordPayment,
  }) {
    return _inFlight ??= _run(
      buildPayment: buildPayment,
      createTransaction: createTransaction,
      recordPayment: recordPayment,
    ).whenComplete(() => _inFlight = null);
  }

  Future<void> submitAtomic({
    required BillPaymentEntity Function(String requestId, DateTime paidAt)
        buildPayment,
    required Future<void> Function(BillPaymentEntity payment) recordPayment,
  }) {
    return _inFlight ??= _runAtomic(
      buildPayment: buildPayment,
      recordPayment: recordPayment,
    ).whenComplete(() => _inFlight = null);
  }

  Future<void> _run({
    required BillPaymentEntity Function(String requestId, DateTime paidAt)
        buildPayment,
    required Future<TransactionEntity> Function(BillPaymentEntity payment)
        createTransaction,
    required Future<void> Function(BillPaymentEntity payment) recordPayment,
  }) async {
    final payment = _payment ??= buildPayment(requestId, paidAt);
    final transaction = _transaction ??= await createTransaction(payment);
    await recordPayment(payment.copyWith(transactionId: transaction.id));
  }

  Future<void> _runAtomic({
    required BillPaymentEntity Function(String requestId, DateTime paidAt)
        buildPayment,
    required Future<void> Function(BillPaymentEntity payment) recordPayment,
  }) async {
    final payment = _payment ??= buildPayment(requestId, paidAt);
    await recordPayment(payment);
  }
}
