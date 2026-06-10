import 'dart:async';

class CaptureRuntime {
  CaptureRuntime._();

  static final CaptureRuntime instance = CaptureRuntime._();

  final StreamController<String> _confirmRequests =
      StreamController<String>.broadcast();
  String? _pendingInitialTransactionId;

  Stream<String> get confirmRequests => _confirmRequests.stream;

  void requestConfirmation(String transactionId) {
    _confirmRequests.add(transactionId);
  }

  void seedInitialConfirmation(String transactionId) {
    _pendingInitialTransactionId = transactionId;
  }

  String? takeInitialConfirmation() {
    final transactionId = _pendingInitialTransactionId;
    _pendingInitialTransactionId = null;
    return transactionId;
  }
}
