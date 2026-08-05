enum CapturedMessageSource {
  androidShare,
  iosShare,
  iosShortcut,
  manualPaste,
  unknown,
}

class CapturedMessage {
  const CapturedMessage({
    required this.text,
    required this.source,
    required this.receivedAt,
    this.senderId,
  });

  final String text;
  final String? senderId;
  final CapturedMessageSource source;

  /// MALI-068n §11 — the native receipt time, or null when genuinely unknown
  /// (a corrupt/absent queue timestamp). Never silently substituted with `now`
  /// upstream: AddTransactionUseCase derives occurredAt from the SMS-parsed date
  /// first and only falls back to `now` as its single documented last resort.
  final DateTime? receivedAt;
}
