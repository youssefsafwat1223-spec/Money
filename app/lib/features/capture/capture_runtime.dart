import 'dart:async';

class CaptureRuntime {
  CaptureRuntime._();

  static final CaptureRuntime instance = CaptureRuntime._();

  final StreamController<String> _confirmRequests =
      StreamController<String>.broadcast();
  final StreamController<String> _navigationRequests =
      StreamController<String>.broadcast();
  String? _pendingInitialTransactionId;
  String? _pendingInitialRoute;

  Stream<String> get confirmRequests => _confirmRequests.stream;
  Stream<String> get navigationRequests => _navigationRequests.stream;

  void requestConfirmation(String transactionId) {
    _confirmRequests.add(transactionId);
  }

  void seedInitialConfirmation(String transactionId) {
    _pendingInitialTransactionId = transactionId;
  }

  void requestNavigation(String route) {
    _navigationRequests.add(route);
  }

  void seedInitialNavigation(String route) {
    _pendingInitialRoute = route;
  }

  String? takeInitialConfirmation() {
    final transactionId = _pendingInitialTransactionId;
    _pendingInitialTransactionId = null;
    return transactionId;
  }

  String? takeInitialNavigation() {
    final route = _pendingInitialRoute;
    _pendingInitialRoute = null;
    return route;
  }
}
