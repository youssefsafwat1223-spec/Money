import 'package:intl/intl.dart';

import '../../../core/utils/currency.dart';
import '../../../domain/finance/money_format.dart';
import '../../../domain/finance/money.dart';

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

  /// MALI-074n / Batch 1: the ONE currency-exponent source (0/2/3 fraction
  /// digits), so reports match the rest of the app instead of a local list that
  /// missed 0-decimal currencies (JPY/KRW/…).
  int _decimals(String code) => currencyDecimalDigits(code);

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

  /// Exact-money leaf formatter. Decimal text is derived directly from minor
  /// units; no binary floating-point value participates in financial math.
  String moneyExact(Money amount) => masked
      ? _mask
      : '${_number(amount.toDouble().abs(), _decimals(amount.currency))} '
          '${_token(amount.currency)}';

  /// Signed with U+2212 for negative/expense values, `+` otherwise.
  String signedMoney(double amount, String code, {bool? isExpense}) {
    if (masked) return _mask;
    final negative = isExpense ?? (amount < 0);
    return '${negative ? '−' : '+'}${money(amount, code)}';
  }

  String signedMoneyExact(Money amount, {bool? isExpense}) {
    if (masked) return _mask;
    final negative = isExpense ?? amount.isNegative;
    return '${negative ? '−' : '+'}${moneyExact(amount)}';
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
