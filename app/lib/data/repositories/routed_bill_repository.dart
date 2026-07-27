import '../../domain/entities/bill_entity.dart';
import '../../domain/repositories/bill_repository.dart';

/// S5: توجيه المرحلة-A أُزيل — غلاف رفيع يفوّض إلى Drift. المزامنة خلفية فقط.
class RoutedBillRepository implements BillRepository {
  const RoutedBillRepository({required BillRepository drift}) : _drift = drift;

  final BillRepository _drift;

  @override
  Future<void> delete(String id) => _drift.delete(id);
  @override
  Future<void> deletePayment(String paymentId) =>
      _drift.deletePayment(paymentId);
  @override
  Future<List<String>> deletePaymentForTransaction(String transactionId) =>
      _drift.deletePaymentForTransaction(transactionId);
  @override
  Future<List<BillEntity>> getAll() => _drift.getAll();
  @override
  Future<BillEntity?> getById(String id) => _drift.getById(id);
  @override
  Future<List<BillEntity>> getDueBetween(
          {required DateTime from, required DateTime to}) =>
      _drift.getDueBetween(from: from, to: to);
  @override
  Future<List<BillPaymentEntity>> getPayments(String billId) =>
      _drift.getPayments(billId);
  @override
  Future<BillPaymentEntity> recordPayment(BillPaymentEntity payment) =>
      _drift.recordPayment(payment);
  @override
  Future<BillPaymentEntity> createAndRecordPayment({
    required BillEntity bill,
    required BillPaymentEntity payment,
  }) =>
      _drift.createAndRecordPayment(bill: bill, payment: payment);
  @override
  Future<BillEntity> save(BillEntity bill) => _drift.save(bill);
}
