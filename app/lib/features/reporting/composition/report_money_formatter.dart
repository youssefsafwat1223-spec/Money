import 'package:intl/intl.dart';

import '../../../core/utils/currency.dart';

/// Report-scoped money & percentage formatting.
///
/// Matches the app's conventions — Western digits, `,` thousands / `.` decimal,
/// U+2212 minus for negatives — while fixing two things for reports:
/// per-currency decimal places (the app's `Formatters` hard-codes 2, mangling
/// 3-decimal Gulf currencies) and a language-appropriate currency token (the
/// Arabic word for `ar`, the ISO code for `en`).
class ReportMoneyFormatter {
  const ReportMoneyFormatter(this.languageCode, {this.masked = false});

  final String languageCode;

  /// When true (privacy mode), monetary values render as `••••` while
  /// percentages and structural labels stay visible.
  final bool masked;

  static const String _mask = '••••';

  static const Set<String> _threeDecimalCurrencies = <String>{
    'KWD', 'BHD', 'OMR', 'TND', 'IQD', 'LYD', 'JOD',
  };

  int _decimals(String code) =>
      _threeDecimalCurrencies.contains(code.toUpperCase()) ? 3 : 2;

  String _token(String code) =>
      languageCode == 'ar' ? Currency.arabicLabel(code) : code.toUpperCase();

  String _number(double value, int decimals) {
    final pattern = decimals == 0 ? '#,##0' : '#,##0.${'0' * decimals}';
    return NumberFormat(pattern, 'en_US').format(value);
  }

  /// e.g. `12,400.00 ريال` / `12,400.00 SAR` (magnitude only), or `••••` masked.
  String money(double amount, String code) => masked
      ? _mask
      : '${_number(amount.abs(), _decimals(code))} ${_token(code)}';

  /// Signed with U+2212 for negative/expense values, `+` otherwise.
  String signedMoney(double amount, String code, {bool? isExpense}) {
    if (masked) return _mask;
    final negative = isExpense ?? (amount < 0);
    return '${negative ? '−' : '+'}${money(amount, code)}';
  }

  /// Whole-percent from a `0..1` fraction, e.g. `30%`.
  String percent(double fraction) => '${(fraction * 100).round()}%';

  /// One-decimal, unsigned percent from a fraction, e.g. `11.9%`.
  String percent1(double fraction) =>
      '${(fraction * 100).abs().toStringAsFixed(1)}%';

  /// Percentage-points delta, signed, one decimal, e.g. `+10.0 pp`.
  String points(double delta) {
    final sign = delta < 0 ? '−' : '+';
    return '$sign${(delta * 100).abs().toStringAsFixed(1)} pp';
  }
}
