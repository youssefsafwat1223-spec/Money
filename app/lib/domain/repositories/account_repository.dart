import '../entities/account_entity.dart';

abstract class AccountRepository {
  Future<List<AccountEntity>> getAll();
  Future<AccountEntity?> getById(String id);
  Future<AccountEntity?> getDefault();
  Future<AccountEntity> create(AccountEntity account);
  Future<AccountEntity> update(AccountEntity account);
  Future<void> delete(String id);
  Future<void> setDefault(String id);
}
