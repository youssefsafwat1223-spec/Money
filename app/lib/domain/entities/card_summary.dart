import '../../engine/parser/card_network.dart';

/// ملخّص بطاقة: آخر 4 أرقام + الشبكة + إجمالي الداخل/الخارج.
class CardSummary {
  const CardSummary({
    required this.last4,
    required this.network,
    required this.totalOut,
    required this.totalIn,
    required this.count,
  });

  final String last4;
  final CardNetwork network;
  final double totalOut;
  final double totalIn;
  final int count;
}
