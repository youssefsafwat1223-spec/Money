import '../entities/smart_inbox_item_entity.dart';

abstract class SmartInboxRepository {
  Future<List<SmartInboxItemEntity>> getOpen();
  Future<void> dismiss(String id);
  Future<void> resolve(String id);
}
