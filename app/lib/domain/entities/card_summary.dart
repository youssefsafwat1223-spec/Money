import '../../engine/parser/card_network.dart';
import '../finance/money.dart';

/// ملخّص بطاقة لعملة واحدة (MALI-074n): آخر 4 أرقام + العملة + الشبكة.
/// [totalOut] صافي الإنفاق (payment + withdrawal − refund، الاسترداد يخصم)،
/// و[totalIn] الدخل فقط (لا يشمل الاسترداد). لا تُجمع عملتان في ملخّص واحد.
class CardSummary {
  const CardSummary({
    required this.last4,
    required this.currency,
    required this.network,
    required this.totalOut,
    required this.totalIn,
    required this.count,
    this.colorTheme,
    this.accentHex,
  });

  final String last4;

  /// عملة هذا الملخّص — إلزامية؛ بطاقة بعملتين تُنتج ملخّصين منفصلين.
  final String currency;
  final CardNetwork network;

  /// صافي الإنفاق: payment + withdrawal − refund (الاسترداد يخصم، لا يُحتسب دخلاً).
  final Money totalOut;

  /// الدخل فقط (income) — الاسترداد لا يظهر هنا.
  final Money totalIn;
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
      currency: currency,
      network: network,
      totalOut: totalOut,
      totalIn: totalIn,
      count: count,
      colorTheme: colorTheme ?? this.colorTheme,
      accentHex: accentHex ?? this.accentHex,
    );
  }
}
