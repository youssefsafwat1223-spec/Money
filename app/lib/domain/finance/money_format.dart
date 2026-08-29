import 'package:intl/intl.dart';

import 'currency_scale.dart';
import 'money.dart';

/// MALI-074n — currency-exponent-correct presentation. The underlying REAL
/// storage risk stays with MALI-026; this fixes FORMATTING so a value is shown
/// with its currency's real number of fraction digits instead of a hardcoded 2.
///
/// This is presentation only — it must never be used to sum across currencies
/// (that is forbidden by the financial-semantics contract).

/// R-8a — DISPLAY scale is derived from the CANONICAL registry, never from a
/// second table.
///
/// This file previously carried its own `_currencyExponents` map. Two
/// independent scale tables is one table too many: they had already drifted —
/// `KMF` is canonically 0-decimal in `kCurrencyScale` and was absent here, so it
/// fell through to the default of 2 and displayed `1000` as `1000.00`. A value
/// shown with more precision than it can hold is a lie about the data.
///
/// The display default of 2 for an UNKNOWN code is retained deliberately.
/// `currency_scale.dart` THROWS on unknown codes because minting canonical minor
/// units from a guess is corruption; a display surface must not throw — showing
/// an unfamiliar currency with two decimals is a presentation compromise, not a
/// data one.

/// The number of fraction digits to present for [currencyCode] (default 2).
int currencyDecimalDigits(String currencyCode) =>
    kCurrencyScale[currencyCode.trim().toUpperCase()] ?? 2;

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


/// **R-8 — the Money-typed display formatter.**
///
/// Formats a canonical [Money] for presentation WITHOUT passing through
/// `double` at any point.
///
/// ## Why not just `formatMoneyAmount(money.toDouble(), …)`
///
/// `Money.toDouble()` is documented as approximate beyond 2^53 minor units, and
/// it is the funnel every financial surface currently uses. Two consequences:
///
///  * large values lose significant digits — the reported symptom in UX-035,
///    where big amounts render as an unreadable, zero-like result;
///  * the binary conversion re-introduces exactly the double-rounding class the
///    domain remediation removed from storage. Formatting is presentation, but
///    presenting a wrong number is still presenting a wrong number.
///
/// This works from `minorUnits` through [Money.toDecimalString] (integer maths)
/// and groups the digit string by hand, so it is exact at any magnitude.
String formatMoney(Money money, {String locale = 'en_US'}) {
  final decimal = money.toDecimalString(); // exact; never a double
  final dot = decimal.indexOf('.');
  final negative = decimal.startsWith('-');
  final unsigned = negative ? decimal.substring(1) : decimal;
  final intPart = dot < 0 ? unsigned : unsigned.substring(0, dot - (negative ? 1 : 0));
  final fracPart = dot < 0 ? '' : unsigned.substring(dot - (negative ? 1 : 0) + 1);

  final symbols = NumberFormat.decimalPattern(locale).symbols;
  final grouped = _group(intPart, symbols.GROUP_SEP);
  final body =
      fracPart.isEmpty ? grouped : '$grouped${symbols.DECIMAL_SEP}$fracPart';
  return negative ? '${symbols.MINUS_SIGN}$body' : body;
}

/// Groups a plain digit string in threes. Done on the STRING rather than by
/// parsing to a number, so a value too large for an `int` still groups exactly.
String _group(String digits, String sep) {
  if (digits.length <= 3) return digits;
  final buf = StringBuffer();
  final lead = digits.length % 3 == 0 ? 3 : digits.length % 3;
  buf.write(digits.substring(0, lead));
  for (var i = lead; i < digits.length; i += 3) {
    buf..write(sep)..write(digits.substring(i, i + 3));
  }
  return buf.toString();
}
