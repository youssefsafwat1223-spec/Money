import 'package:intl/intl.dart';

/// MALI-074n — currency-exponent-correct presentation. The underlying REAL
/// storage risk stays with MALI-026; this fixes FORMATTING so a value is shown
/// with its currency's real number of fraction digits instead of a hardcoded 2.
///
/// This is presentation only — it must never be used to sum across currencies
/// (that is forbidden by the financial-semantics contract).

/// ISO-4217 minor-unit exponents that differ from the default of 2.
const Map<String, int> _currencyExponents = {
  // Three-decimal (common in the Gulf/MENA markets this app targets).
  'KWD': 3, 'BHD': 3, 'OMR': 3, 'JOD': 3, 'TND': 3, 'LYD': 3, 'IQD': 3,
  // Zero-decimal.
  'JPY': 0, 'KRW': 0, 'ISK': 0, 'CLP': 0, 'VND': 0, 'XAF': 0, 'XOF': 0,
  'UGX': 0, 'RWF': 0, 'DJF': 0, 'GNF': 0, 'PYG': 0,
};

/// The number of fraction digits to present for [currencyCode] (default 2).
int currencyDecimalDigits(String currencyCode) =>
    _currencyExponents[currencyCode.toUpperCase()] ?? 2;

/// Formats [amount] with the correct number of fraction digits for
/// [currencyCode]. Grouped thousands; no currency symbol (callers add the label
/// so grouped-by-currency surfaces stay explicit).
String formatMoneyAmount(
  num amount,
  String currencyCode, {
  String locale = 'en_US',
}) {
  final digits = currencyDecimalDigits(currencyCode);
  final pattern = digits == 0 ? '#,##0' : '#,##0.${'0' * digits}';
  return NumberFormat(pattern, locale).format(amount);
}
