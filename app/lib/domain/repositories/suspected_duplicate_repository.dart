import '../entities/suspected_duplicate_entity.dart';

abstract class SuspectedDuplicateRepository {
  Future<void> save(SuspectedDuplicateEntity entity);
  Future<List<SuspectedDuplicateEntity>> getAll();
  Future<SuspectedDuplicateEntity?> getByExistingTransactionId(String txId);
  Future<void> delete(String id);
}
