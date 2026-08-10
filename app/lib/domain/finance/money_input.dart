/// MALI-026 (Phase-8 B8-1 §4) — the localized money-INPUT adapter.
///
/// The Money domain parser (`Money.parse` / `parseExactDecimalToMinor`) is
/// deliberately LOCALE-AGNOSTIC — it accepts only canonical decimal text
/// (`-19.99`). This adapter is the ONE place localization lives: it maps
/// localized UI text (Arabic-Indic / Persian digits, the Arabic decimal
/// separator, grouping separators) to canonical decimal text, then hands it to
/// the strict parser. NO `double.parse` sits in this path.
///
/// It replaces the scattered ad-hoc normalizers (generic import, bill form,
/// manual transaction, parser) for the MONEY-input surfaces during the later
/// UI-migration step (not yet wired here — B8-1 delivers the contract + helper).
library;

import 'decimal_minor.dart';
import 'money.dart';

class MoneyInputException implements Exception {
  const MoneyInputException(this.message);
  final String message;
  @override
  String toString() => 'MoneyInputException: $message';
}

/// Grouping / thousands separators that carry no value and are stripped:
/// ASCII comma, space, NBSP, Arabic thousands (U+066C) and Arabic comma (U+060C).
const _grouping = {',', ' ', ' ', '٬', '،'};

/// Normalize localized numeric text to CANONICAL decimal text (ASCII digits,
/// '.' decimal, optional leading sign, no grouping). Deterministic:
///   - Arabic-Indic digits U+0660–0669 and Persian digits U+06F0–06F9 → 0–9;
///   - Arabic decimal separator ٫ (U+066B) and ASCII '.' → '.';
///   - grouping separators (see [_grouping]) → removed;
///   - a single leading '+'/'-' is kept.
/// Any other character, more than one decimal point, or an empty/So-only string
/// throws [MoneyInputException]. Comma is treated as GROUPING (removed), matching
/// the app's existing '.'-decimal money forms — never as a decimal separator.
String normalizeLocalizedDecimal(String input) {
  final buf = StringBuffer();
  var seenDot = false;
  var i = 0;
  final chars = input.trim().runes.toList();
  for (final rune in chars) {
    final ch = String.fromCharCode(rune);
    if (i == 0 && (ch == '+' || ch == '-')) {
      buf.write(ch);
      i++;
      continue;
    }
    i++;
    if (rune >= 0x0660 && rune <= 0x0669) {
      buf.writeCharCode(0x30 + (rune - 0x0660)); // Arabic-Indic → ASCII
    } else if (rune >= 0x06F0 && rune <= 0x06F9) {
      buf.writeCharCode(0x30 + (rune - 0x06F0)); // Persian → ASCII
    } else if (rune >= 0x30 && rune <= 0x39) {
      buf.write(ch); // ASCII digit
    } else if (ch == '.' || rune == 0x066B) {
      if (seenDot) {
        throw MoneyInputException('more than one decimal separator: "$input"');
      }
      seenDot = true;
      buf.write('.');
    } else if (_grouping.contains(ch)) {
      // strip grouping
    } else {
      throw MoneyInputException('unexpected character "$ch" in "$input"');
    }
  }
  final out = buf.toString();
  final digitsOnly = out.replaceAll(RegExp(r'[+\-.]'), '');
  if (digitsOnly.isEmpty) {
    throw MoneyInputException('no digits in "$input"');
  }
  return out;
}

/// Parse localized money input to canonical [Money] (adapter → canonical decimal
/// → strict `Money.parse`). Rejects over-precision beyond the currency scale
/// (Decision 1A — user money is never silently rounded) and unsupported
/// currencies. Throws [MoneyInputException] on localized-format errors and
/// rethrows [DecimalFormatException] on precision/format violations from the
/// strict parser.
Money parseLocalizedMoney(String input, String currency) =>
    Money.parse(normalizeLocalizedDecimal(input), currency);
