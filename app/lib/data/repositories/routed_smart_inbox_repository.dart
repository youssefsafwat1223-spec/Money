import '../../domain/entities/smart_inbox_item_entity.dart';
import '../../domain/repositories/smart_inbox_repository.dart';

/// S5: توجيه المرحلة-A أُزيل — غلاف رفيع يفوّض إلى Drift. الدفع للخادم يتم عبر
/// SmartInboxSyncService المتخصّص (server-authored)، لا من هنا.
class RoutedSmartInboxRepository implements SmartInboxRepository {
  const RoutedSmartInboxRepository({required SmartInboxRepository drift})
      : _drift = drift;

  final SmartInboxRepository _drift;

  @override
  Future<void> dismiss(String id) => _drift.dismiss(id);
  @override
  Future<List<SmartInboxItemEntity>> getOpen() => _drift.getOpen();
  @override
  Future<void> resolve(String id) => _drift.resolve(id);
}
