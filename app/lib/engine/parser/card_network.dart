/// شبكة البطاقة المكتشفة من نص رسالة البنك.
enum CardNetwork {
  mada,
  visa,
  mastercard,
  amex,
  unknown;

  // No `label` getter here on purpose. This file is pure Dart with no
  // BuildContext, so any display name it returned would be in ONE language —
  // and it returned Arabic, which reached English readers through the card
  // form's Network dropdown and the account-detail card row. The localized
  // name lives in `features/cards/card_network_label.dart`.
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
