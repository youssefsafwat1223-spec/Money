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

/// Normalize localized numeric text to CANONICAL decimal text — deterministic
/// and AMBIGUITY-SAFE, so the magnitude can NEVER silently change (Blocker 2):
///   - Arabic-Indic (U+0660–0669) / Persian (U+06F0–06F9) digits → ASCII;
///   - ٫ (U+066B) and ASCII '.' are the ONLY decimal separators (at most one);
///   - a grouping separator (see [_grouping]) is accepted ONLY when the integer
///     part forms STRUCTURALLY-VALID thousands groups (`\d{1,3}(,\d{3})+`);
///     anything else — `12,50`, `1.234,50`, `1,23`, a comma in the fraction —
///     THROWS. A comma is never deleted or reinterpreted as a decimal.
///   - fraction part = digits only; a single leading '+'/'-' is kept.
/// Money.parse itself stays locale-independent; this adapter is the only
/// localization boundary.
String normalizeLocalizedDecimal(String input) {
  final sb = StringBuffer();
  var negative = false;
  final runes = input.trim().runes.toList();
  for (var i = 0; i < runes.length; i++) {
    final rune = runes[i];
    final ch = String.fromCharCode(rune);
    if (i == 0 && (ch == '+' || ch == '-')) {
      negative = ch == '-';
      continue;
    }
    if (rune >= 0x0660 && rune <= 0x0669) {
      sb.writeCharCode(0x30 + (rune - 0x0660)); // Arabic-Indic → ASCII
    } else if (rune >= 0x06F0 && rune <= 0x06F9) {
      sb.writeCharCode(0x30 + (rune - 0x06F0)); // Persian → ASCII
    } else if (rune >= 0x30 && rune <= 0x39) {
      sb.write(ch);
    } else if (ch == '.' || rune == 0x066B) {
      sb.write('.'); // canonical decimal marker (count validated below)
    } else if (_grouping.contains(ch)) {
      sb.write(',');
    } else {
      throw MoneyInputException('unexpected character "$ch" in "$input"');
    }
  }
  final body = sb.toString();

  if ('.'.allMatches(body).length > 1) {
    throw MoneyInputException('more than one decimal separator: "$input"');
  }
  final dot = body.indexOf('.');
  final intRaw = dot < 0 ? body : body.substring(0, dot);
  final fracRaw = dot < 0 ? '' : body.substring(dot + 1);

  // fraction: digits only — no grouping after the decimal point.
  if (dot >= 0 && (fracRaw.isEmpty || !RegExp(r'^\d+$').hasMatch(fracRaw))) {
    throw MoneyInputException('invalid fraction in "$input"');
  }

  // integer: grouping, if present, MUST be structurally-valid thousands.
  final String intDigits;
  if (intRaw.contains(',')) {
    final grouped = intRaw;
    if (!RegExp(r'^\d{1,3}(,\d{3})+$').hasMatch(grouped)) {
      throw MoneyInputException(
          'ambiguous grouping/decimal in "$input" — magnitude cannot be guessed');
    }
    intDigits = grouped.replaceAll(',', '');
  } else {
    intDigits = intRaw;
  }
  if (intDigits.isEmpty || !RegExp(r'^\d+$').hasMatch(intDigits)) {
    throw MoneyInputException('no valid integer part in "$input"');
  }

  final out = fracRaw.isEmpty ? intDigits : '$intDigits.$fracRaw';
  return negative ? '-$out' : out;
}

/// Parse localized money input to canonical [Money] (adapter → canonical decimal
/// → strict `Money.parse`). Rejects over-precision beyond the currency scale
/// (Decision 1A — user money is never silently rounded) and unsupported
/// currencies. Throws [MoneyInputException] on localized-format errors and
/// rethrows [DecimalFormatException] on precision/format violations from the
/// strict parser.
Money parseLocalizedMoney(String input, String currency) =>
    Money.parse(normalizeLocalizedDecimal(input), currency);
