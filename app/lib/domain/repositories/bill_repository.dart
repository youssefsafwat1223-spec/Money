import '../entities/bill_entity.dart';

abstract class BillRepository {
  Future<List<BillEntity>> getAll();

  Future<List<BillEntity>> getDueBetween({
    required DateTime from,
    required DateTime to,
  });

  Future<BillEntity?> getById(String id);

  Future<BillEntity> save(BillEntity bill);

  Future<List<BillPaymentEntity>> getPayments(String billId);

  Future<BillPaymentEntity> recordPayment(BillPaymentEntity payment);

  Future<List<String>> deletePaymentForTransaction(String transactionId);

  Future<void> delete(String id);
}
