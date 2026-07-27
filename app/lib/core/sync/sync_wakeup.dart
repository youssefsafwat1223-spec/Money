import 'dart:async';

/// Process-local signal emitted after a durable outbox write.
///
/// Repositories remain unaware of the application shell: queues publish only
/// after the local transaction/outbox row is committed, and the shell decides
/// when to run the background workers. The stream intentionally carries no
/// financial payload.
class SyncWakeup {
  SyncWakeup._();

  static final StreamController<void> _controller =
      StreamController<void>.broadcast(sync: true);

  static Stream<void> get events => _controller.stream;

  static void notify() {
    if (!_controller.isClosed) _controller.add(null);
  }
}
