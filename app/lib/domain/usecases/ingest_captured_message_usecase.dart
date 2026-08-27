import '../entities/captured_message.dart';
import 'add_transaction_usecase.dart';

enum CapturedMessageDisposition {
  ignored,
  notifyOnly,
  requestConfirmation,
  suspiciousDuplicate,

  /// A bank-like message was received but could not be parsed (not OTP/promo).
  /// The user should be prompted to add it manually.
  unprocessable,
}

class CapturedMessageResult {
  const CapturedMessageResult({
    required this.disposition,
    required this.addTransactionResult,
    required this.notificationStableId,
  });

  final CapturedMessageDisposition disposition;
  final AddTransactionResult addTransactionResult;

  /// MALI-061n §3 — a stable logical identity for this capture's notification,
  /// generated BEFORE the first notify attempt. It is the transaction id when
  /// one exists, otherwise a fingerprint of the IMMUTABLE capture content
  /// (source|sender|raw text) — never the localized/mutable display title/body.
  /// Callers pass this to showLightCaptureNotification so a re-rendered banner
  /// keeps the same OS id (replace, not duplicate).
  final String notificationStableId;

  String? get transactionId => addTransactionResult.transaction?.id;
}

class IngestCapturedMessageUseCase {
  const IngestCapturedMessageUseCase(this._addTransactionUseCase);

  final AddTransactionUseCase _addTransactionUseCase;

  Future<CapturedMessageResult> call({
    required String rawMessage,
    String? senderId,
  }) async {
    return fromCapturedMessage(
      CapturedMessage(
        text: rawMessage,
        senderId: senderId,
        source: CapturedMessageSource.unknown,
        receivedAt: DateTime.now().toUtc(),
      ),
    );
  }

  Future<CapturedMessageResult> fromCapturedMessage(
    CapturedMessage message, {
    bool onDeviceOnly = false,
  }) async {
    final result = await _addTransactionUseCase(
      rawMessage: message.text,
      senderId: message.senderId,
      smsReceivedAt: message.receivedAt,
      onDeviceOnly: onDeviceOnly,
    );

    // Prefer the transaction business key; otherwise a stable fingerprint of the
    // immutable capture content (never the display text). Generated here, once,
    // before any notification is shown.
    final notificationStableId = result.transaction?.id ??
        'capture:${message.source.name}:${message.senderId ?? ''}:${message.text}';

    switch (result.outcome) {
      case AddTransactionOutcome.duplicate:
        return CapturedMessageResult(
          disposition: CapturedMessageDisposition.ignored,
          addTransactionResult: result,
          notificationStableId: notificationStableId,
        );
      case AddTransactionOutcome.suspiciousDuplicate:
        return CapturedMessageResult(
          disposition: CapturedMessageDisposition.suspiciousDuplicate,
          addTransactionResult: result,
          notificationStableId: notificationStableId,
        );
      case AddTransactionOutcome.notTransaction:
        return CapturedMessageResult(
          disposition: result.droppedByParser
              ? CapturedMessageDisposition.unprocessable
              : CapturedMessageDisposition.ignored,
          addTransactionResult: result,
          notificationStableId: notificationStableId,
        );
      case AddTransactionOutcome.added:
        return CapturedMessageResult(
          disposition: result.requiresConfirmation
              ? CapturedMessageDisposition.requestConfirmation
              : CapturedMessageDisposition.notifyOnly,
          addTransactionResult: result,
          notificationStableId: notificationStableId,
        );
    }
  }
}
