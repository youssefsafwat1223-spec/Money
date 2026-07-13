import '../../data/catalog/feature_flag_service.dart';
import '../../data/db/app_database.dart';
import '../../data/db/financial_cache_health.dart';
import '../../domain/entities/account_entity.dart';
import '../../domain/repositories/account_repository.dart';

/// يوجّه كل استدعاء لـ AccountRepository إلى Drift أو Supabase حسب علامة
/// accounts_supabase_primary — تُفحص العلامة داخل كل دالة (وليس مرّة واحدة
/// عند إنشاء الـ provider)، حتى ينعكس أي تغيير في العلامة على الاستدعاء
/// التالي مباشرة دون إعادة تشغيل التطبيق كاملاً (أنظر توثيق تحديث العلامة).
class RoutedAccountRepository implements AccountRepository {
  RoutedAccountRepository({
    required AccountRepository drift,
    required AccountRepository supabase,
    required FeatureFlagService Function() flags,
    required AppDatabase db,
  })  : _drift = drift,
        _supabase = supabase,
        _flags = flags,
        _db = db;

  final AccountRepository _drift;
  final AccountRepository _supabase;
  // دالة (وليس مرجعًا مباشرًا) لأن _featureFlagInstance العام يُستبدَل بكائن
  // جديد كل مرة يعاد فيها تشغيل initFeatureFlagService — أي مرجع محفوظ عند
  // إنشاء الـ provider يتجمّد على نسخة قديمة منقطعة الصلة بالتحديثات.
  final FeatureFlagService Function() _flags;
  final AppDatabase _db;

  bool get _useSupabase => _flags().getBool('accounts_supabase_primary');

  Future<T> _route<T>(
    Future<T> Function() supabase,
    Future<T> Function() drift,
  ) =>
      routeFinancialOperation(
        db: _db,
        entityType: accountsCacheEntityType,
        useSupabase: _useSupabase,
        supabase: supabase,
        drift: drift,
      );

  @override
  Future<List<AccountEntity>> getAll() =>
      _route(_supabase.getAll, _drift.getAll);

  @override
  Future<AccountEntity?> getById(String id) =>
      _route(() => _supabase.getById(id), () => _drift.getById(id));

  @override
  Future<AccountEntity?> getDefault() =>
      _route(_supabase.getDefault, _drift.getDefault);

  @override
  Future<AccountEntity> create(AccountEntity account) =>
      _route(() => _supabase.create(account), () => _drift.create(account));

  @override
  Future<AccountEntity> update(AccountEntity account) =>
      _route(() => _supabase.update(account), () => _drift.update(account));

  @override
  Future<void> delete(String id) =>
      _route(() => _supabase.delete(id), () => _drift.delete(id));

  @override
  Future<void> setDefault(String id) =>
      _route(() => _supabase.setDefault(id), () => _drift.setDefault(id));
}
