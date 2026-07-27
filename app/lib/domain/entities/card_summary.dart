import '../../engine/parser/card_network.dart';

/// ملخّص بطاقة: آخر 4 أرقام + الشبكة + إجمالي الداخل/الخارج.
class CardSummary {
  const CardSummary({
    required this.last4,
    required this.network,
    required this.totalOut,
    required this.totalIn,
    required this.count,
    this.colorTheme,
    this.accentHex,
  });

  final String last4;
  final CardNetwork network;
  final double totalOut;
  final double totalIn;
  final int count;

  /// تصميم البطاقة اليدوية المطابقة (جدول cards) — null للبطاقات المشتقّة فقط.
  final String? colorTheme;
  final String? accentHex;

  CardSummary copyWith({
    String? colorTheme,
    String? accentHex,
  }) {
    return CardSummary(
      last4: last4,
      network: network,
      totalOut: totalOut,
      totalIn: totalIn,
      count: count,
      colorTheme: colorTheme ?? this.colorTheme,
      accentHex: accentHex ?? this.accentHex,
    );
  }
}
