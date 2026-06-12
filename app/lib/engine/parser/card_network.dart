/// شبكة البطاقة المكتشفة من نص رسالة البنك.
enum CardNetwork {
  mada,
  visa,
  mastercard,
  amex,
  unknown;

  /// تسمية للعرض.
  String get label => switch (this) {
        CardNetwork.mada => 'مدى',
        CardNetwork.visa => 'Visa',
        CardNetwork.mastercard => 'Mastercard',
        CardNetwork.amex => 'Amex',
        CardNetwork.unknown => 'بطاقة',
      };
}

/// يكتشف شبكة البطاقة من نص الرسالة (Dart نقي، قابل للاختبار).
class CardNetworkDetector {
  CardNetworkDetector._();

  static CardNetwork detect(String text) {
    final t = text.toLowerCase();
    if (t.contains('مدى') || t.contains('mada')) return CardNetwork.mada;
    if (t.contains('visa') || t.contains('فيزا')) return CardNetwork.visa;
    if (t.contains('mastercard') ||
        t.contains('master card') ||
        t.contains('ماستر')) {
      return CardNetwork.mastercard;
    }
    if (t.contains('amex') || t.contains('american express')) {
      return CardNetwork.amex;
    }
    return CardNetwork.unknown;
  }
}
