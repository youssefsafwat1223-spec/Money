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
  final DateTime receivedAt;
}
