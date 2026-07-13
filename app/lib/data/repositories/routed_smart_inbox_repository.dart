import '../../data/catalog/feature_flag_service.dart';
import '../../data/db/app_database.dart';
import '../../data/db/financial_cache_health.dart';
import '../../domain/entities/smart_inbox_item_entity.dart';
import '../../domain/repositories/smart_inbox_repository.dart';

class RoutedSmartInboxRepository implements SmartInboxRepository {
  const RoutedSmartInboxRepository({
    required SmartInboxRepository drift,
    required SmartInboxRepository supabase,
    required FeatureFlagService Function() flags,
    required AppDatabase db,
  })  : _drift = drift,
        _supabase = supabase,
        _flags = flags,
        _db = db;

  final SmartInboxRepository _drift;
  final SmartInboxRepository _supabase;
  final FeatureFlagService Function() _flags;
  final AppDatabase _db;
  bool get _useSupabase => _flags().getBool('smart_inbox_supabase_primary');
  Future<T> _route<T>(
    Future<T> Function() supabase,
    Future<T> Function() drift,
  ) =>
      routeFinancialOperation(
        db: _db,
        entityType: smartInboxCacheEntityType,
        useSupabase: _useSupabase,
        supabase: supabase,
        drift: drift,
      );

  @override
  Future<void> dismiss(String id) =>
      _route(() => _supabase.dismiss(id), () => _drift.dismiss(id));
  @override
  Future<List<SmartInboxItemEntity>> getOpen() =>
      _route(_supabase.getOpen, _drift.getOpen);
  @override
  Future<void> resolve(String id) =>
      _route(() => _supabase.resolve(id), () => _drift.resolve(id));
}
