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

/// A-5: process-local signal that an AUTHENTICATED session is (again) valid —
/// emitted by AppSession after a sign-in / initial session / token refresh has
/// been admitted. Rows parked `auth_required` re-arm on it. Carries no payload.
class AuthSessionValid {
  AuthSessionValid._();

  static final StreamController<void> _controller =
      StreamController<void>.broadcast(sync: true);

  static Stream<void> get events => _controller.stream;

  static void notify() {
    if (!_controller.isClosed) _controller.add(null);
  }
}
