import '../../domain/entities/engagement_entities.dart';

class CelebrationRuntime {
  CelebrationRuntime._();

  static final CelebrationRuntime instance = CelebrationRuntime._();

  final List<CelebrationEvent> _queue = [];

  void pushAll(List<CelebrationEvent> events) {
    if (events.isEmpty) {
      return;
    }
    _queue.addAll(events);
  }

  CelebrationEvent? takeNext() {
    if (_queue.isEmpty) {
      return null;
    }
    return _queue.removeAt(0);
  }
}
