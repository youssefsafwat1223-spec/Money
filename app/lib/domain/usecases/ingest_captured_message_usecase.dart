import 'add_transaction_usecase.dart';

enum CapturedMessageDisposition {
  ignored,
  notifyOnly,
  requestConfirmation,
}

class CapturedMessageResult {
  const CapturedMessageResult({
    required this.disposition,
    required this.addTransactionResult,
  });

  final CapturedMessageDisposition disposition;
  final AddTransactionResult addTransactionResult;

  String? get transactionId => addTransactionResult.transaction?.id;
}

class IngestCapturedMessageUseCase {
  const IngestCapturedMessageUseCase(this._addTransactionUseCase);

  final AddTransactionUseCase _addTransactionUseCase;

  Future<CapturedMessageResult> call({
    required String rawMessage,
    String? senderId,
  }) async {
    final result = await _addTransactionUseCase(
      rawMessage: rawMessage,
      senderId: senderId,
    );

    switch (result.outcome) {
      case AddTransactionOutcome.duplicate:
      case AddTransactionOutcome.notTransaction:
        return CapturedMessageResult(
          disposition: CapturedMessageDisposition.ignored,
          addTransactionResult: result,
        );
      case AddTransactionOutcome.added:
        return CapturedMessageResult(
          disposition: result.requiresConfirmation
              ? CapturedMessageDisposition.requestConfirmation
              : CapturedMessageDisposition.notifyOnly,
          addTransactionResult: result,
        );
    }
  }
}
