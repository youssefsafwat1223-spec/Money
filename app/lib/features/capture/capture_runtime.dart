import 'dart:async';

import '../../core/session/admission_authority.dart';
import '../../domain/entities/sender_bank_mapping_entity.dart';

/// إجراء سريع من أزرار الإشعار (تأكيد ✓ / تجاهل) أثناء عمل التطبيق.
class CaptureQuickAction {
  const CaptureQuickAction(
      {required this.transactionId, required this.confirm, this.origin});

  final String transactionId;
  final bool confirm;

  /// O-LC-2: the account lifecycle the callback started in. A consumer acts only
  /// while it is current AND is the lifecycle the consumer itself belongs to; a
  /// listener that is merely mounted for a successor never inherits it. Null only
  /// for actions replayed from the consumer's own durable queue.
  final AdmissionAuthority? origin;
}

/// A confirmation sheet request bound to its originating lifecycle (O-LC-2).
class CaptureConfirmRequest {
  const CaptureConfirmRequest(this.transactionId, this.origin);
  final String transactionId;
  final AdmissionAuthority origin;
}

/// A navigation request bound to its originating lifecycle (O-LC-2).
class CaptureNavigationRequest {
  const CaptureNavigationRequest(this.route, this.origin);
  final String route;
  final AdmissionAuthority origin;
}

class CaptureRuntime {
  CaptureRuntime._();

  static final CaptureRuntime instance = CaptureRuntime._();

  final StreamController<CaptureConfirmRequest> _confirmRequests =
      StreamController<CaptureConfirmRequest>.broadcast();
  final StreamController<CaptureQuickAction> _quickActionRequests =
      StreamController<CaptureQuickAction>.broadcast();
  final StreamController<CaptureNavigationRequest> _navigationRequests =
      StreamController<CaptureNavigationRequest>.broadcast();
  final StreamController<SenderBankMappingEntity> _bankDiscoveryRequests =
      StreamController<SenderBankMappingEntity>.broadcast();
  String? _pendingInitialTransactionId;
  String? _pendingInitialRoute;

  Stream<String> get confirmRequests =>
      _confirmRequests.stream.map((r) => r.transactionId);
  Stream<CaptureConfirmRequest> get confirmEvents => _confirmRequests.stream;
  Stream<CaptureQuickAction> get quickActionRequests =>
      _quickActionRequests.stream;
  Stream<String> get navigationRequests =>
      _navigationRequests.stream.map((r) => r.route);
  Stream<CaptureNavigationRequest> get navigationEvents =>
      _navigationRequests.stream;
  Stream<SenderBankMappingEntity> get bankDiscoveryRequests =>
      _bankDiscoveryRequests.stream;

  void requestConfirmation(String transactionId,
      {required AdmissionAuthority origin}) {
    _confirmRequests.add(CaptureConfirmRequest(transactionId, origin));
  }

  void requestQuickAction(String transactionId,
      {required bool confirm, required AdmissionAuthority origin}) {
    _quickActionRequests.add(
      CaptureQuickAction(
          transactionId: transactionId, confirm: confirm, origin: origin),
    );
  }

  void requestBankDiscoveryConfirmation(SenderBankMappingEntity mapping) {
    _bankDiscoveryRequests.add(mapping);
  }

  void seedInitialConfirmation(String transactionId) {
    _pendingInitialTransactionId = transactionId;
  }

  void requestNavigation(String route, {required AdmissionAuthority origin}) {
    _navigationRequests.add(CaptureNavigationRequest(route, origin));
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
