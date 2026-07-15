import 'dart:async';

import '../../domain/entities/sender_bank_mapping_entity.dart';

/// إجراء سريع من أزرار الإشعار (تأكيد ✓ / تجاهل) أثناء عمل التطبيق.
class CaptureQuickAction {
  const CaptureQuickAction(
      {required this.transactionId, required this.confirm});

  final String transactionId;
  final bool confirm;
}

class CaptureRuntime {
  CaptureRuntime._();

  static final CaptureRuntime instance = CaptureRuntime._();

  final StreamController<String> _confirmRequests =
      StreamController<String>.broadcast();
  final StreamController<CaptureQuickAction> _quickActionRequests =
      StreamController<CaptureQuickAction>.broadcast();
  final StreamController<String> _navigationRequests =
      StreamController<String>.broadcast();
  final StreamController<SenderBankMappingEntity> _bankDiscoveryRequests =
      StreamController<SenderBankMappingEntity>.broadcast();
  String? _pendingInitialTransactionId;
  String? _pendingInitialRoute;

  Stream<String> get confirmRequests => _confirmRequests.stream;
  Stream<CaptureQuickAction> get quickActionRequests =>
      _quickActionRequests.stream;
  Stream<String> get navigationRequests => _navigationRequests.stream;
  Stream<SenderBankMappingEntity> get bankDiscoveryRequests =>
      _bankDiscoveryRequests.stream;

  void requestConfirmation(String transactionId) {
    _confirmRequests.add(transactionId);
  }

  void requestQuickAction(String transactionId, {required bool confirm}) {
    _quickActionRequests.add(
      CaptureQuickAction(transactionId: transactionId, confirm: confirm),
    );
  }

  void requestBankDiscoveryConfirmation(SenderBankMappingEntity mapping) {
    _bankDiscoveryRequests.add(mapping);
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
