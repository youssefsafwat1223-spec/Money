import '../../domain/entities/account_entity.dart';
import '../../domain/repositories/account_repository.dart';

/// S5: طبقة توجيه المرحلة-A أُزيلت — لم تعد هناك قراءة/كتابة على Supabase من
/// الواجهة. غلاف رفيع يفوّض كل شيء إلى Drift (الكاش المحلي المصدر). المزامنة
/// تتم في الخلفية عبر outbox/push/pull فقط. يُبقى كحدّ DI مستقر.
class RoutedAccountRepository implements AccountRepository {
  const RoutedAccountRepository({required AccountRepository drift})
      : _drift = drift;

  final AccountRepository _drift;

  @override
  Future<List<AccountEntity>> getAll() => _drift.getAll();
  @override
  Future<AccountEntity?> getById(String id) => _drift.getById(id);
  @override
  Future<AccountEntity?> getDefault() => _drift.getDefault();
  @override
  Future<AccountEntity> create(AccountEntity account) => _drift.create(account);
  @override
  Future<AccountEntity> update(AccountEntity account) => _drift.update(account);
  @override
  Future<void> delete(String id) => _drift.delete(id);
  @override
  Future<void> setDefault(String id) => _drift.setDefault(id);
}
