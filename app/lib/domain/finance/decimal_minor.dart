/// MALI-026 (Phase-8 B8-0) — exact decimal ⇄ integer-minor-units conversion.
///
/// All arithmetic here is BigInt/decimal-exact: NO binary `double` is used to
/// derive canonical minor units. The only place a `double` appears is the legacy
/// REAL migration converter, where the double is first reconstructed to its
/// SHORTEST round-trip decimal string (`double.toString()`) and every further
/// step is exact decimal arithmetic — never `real * pow10` float math.
library;

/// Signed 64-bit range — the canonical persisted contract (SQLite INTEGER).
final BigInt int64Max = BigInt.parse('9223372036854775807');
final BigInt int64Min = BigInt.parse('-9223372036854775808');

/// Thrown when a computed minor-unit value cannot fit the signed-int64 contract.
class MoneyOverflowException implements Exception {
  const MoneyOverflowException(this.value);
  final BigInt value;
  @override
  String toString() =>
      'MoneyOverflowException: $value is outside signed int64 minor-unit range';
}

/// Thrown when decimal text is malformed or (for exact parsing) carries more
/// precision than the currency scale allows.
class DecimalFormatException implements Exception {
  const DecimalFormatException(this.message);
  final String message;
  @override
  String toString() => 'DecimalFormatException: $message';
}

/// Checked narrowing of a BigInt minor value to signed int64. Callers do wide
/// (BigInt) intermediate math for multiplication / rate / aggregation, then pass
/// through here before storing to SQLite.
int checkedInt64(BigInt value) {
  if (value > int64Max || value < int64Min) {
    throw MoneyOverflowException(value);
  }
  return value.toInt();
}

/// Round `numerator / denominator` (denominator > 0) to the nearest integer,
/// ties going AWAY FROM ZERO (ROUND_HALF_UP interpreted symmetrically). Exact.
BigInt roundHalfAwayFromZero(BigInt numerator, BigInt denominator) {
  assert(denominator > BigInt.zero);
  final negative = numerator.isNegative;
  final n = numerator.abs();
  var q = n ~/ denominator;
  final r = n % denominator;
  // tie (2r == den) rounds away from zero; anything above rounds up too.
  if (r * BigInt.two >= denominator) q += BigInt.one;
  return negative ? -q : q;
}

class _ParsedDecimal {
  const _ParsedDecimal(this.negative, this.intDigits, this.fracDigits);
  final bool negative;
  final String intDigits; // digits only, no sign, may be "0"
  final String fracDigits; // digits only, may be ""
}

/// Strict decimal grammar: optional sign, digits, optional '.' + digits.
/// No exponent, no thousands separators, no whitespace (callers normalise).
_ParsedDecimal _parseDecimal(String raw) {
  final text = raw.trim();
  if (text.isEmpty) throw const DecimalFormatException('empty');
  var i = 0;
  var negative = false;
  if (text[i] == '+' || text[i] == '-') {
    negative = text[i] == '-';
    i++;
  }
  final rest = text.substring(i);
  if (!RegExp(r'^\d+(\.\d+)?$').hasMatch(rest)) {
    throw DecimalFormatException('not a plain decimal: "$raw"');
  }
  final dot = rest.indexOf('.');
  final intDigits = dot < 0 ? rest : rest.substring(0, dot);
  final fracDigits = dot < 0 ? '' : rest.substring(dot + 1);
  return _ParsedDecimal(negative, intDigits, fracDigits);
}

/// Combined |value| * 10^scale as a BigInt, plus the number of fractional digits.
BigInt _digitsAsBigInt(_ParsedDecimal d) =>
    BigInt.parse('${d.intDigits}${d.fracDigits}');

/// EXACT parse (Decision 1 case A — new user-entered money): decimal text →
/// int64 minor at [scale]. Rejects any value that carries NON-ZERO precision
/// beyond the currency scale (never silently rounds user input).
int parseExactDecimalToMinor(String text, int scale) {
  final d = _parseDecimal(text);
  if (d.fracDigits.length > scale) {
    final excess = d.fracDigits.substring(scale);
    if (excess.replaceAll('0', '').isNotEmpty) {
      throw DecimalFormatException(
          'value "$text" has more precision than the currency allows (scale $scale)');
    }
  }
  final unscaled = _digitsAsBigInt(d); // |int|·frac as one integer
  final fracLen = d.fracDigits.length;
  final BigInt minorAbs = fracLen <= scale
      ? unscaled * BigInt.from(10).pow(scale - fracLen)
      : unscaled ~/ BigInt.from(10).pow(fracLen - scale); // excess are all zero
  final signed = d.negative ? -minorAbs : minorAbs;
  return checkedInt64(signed);
}

/// QUANTIZING parse (Decision 1 case B/C — legacy/derived money): decimal text →
/// int64 minor at [scale], rounding excess precision HALF-AWAY-FROM-ZERO.
int quantizeDecimalToMinor(String text, int scale) {
  final d = _parseDecimal(text);
  final unscaled = _digitsAsBigInt(d);
  final fracLen = d.fracDigits.length;
  final BigInt minorAbs;
  if (fracLen <= scale) {
    minorAbs = unscaled * BigInt.from(10).pow(scale - fracLen);
  } else {
    minorAbs =
        roundHalfAwayFromZero(unscaled, BigInt.from(10).pow(fracLen - scale));
  }
  final signed = d.negative ? -minorAbs : minorAbs;
  return checkedInt64(signed);
}

/// Legacy REAL (binary double) → int64 minor at [scale] (Decision 1 case B).
/// The double is FIRST reconstructed to its shortest round-trip decimal via
/// [double.toString], which recovers the intended value ("19.99", not
/// "19.989999999"); the remaining steps are exact decimal quantization. No
/// `real * pow10` float math and no epsilon hacks. NaN/Infinity are rejected.
int legacyRealToMinor(double real, int scale) {
  if (real.isNaN || real.isInfinite) {
    throw DecimalFormatException('non-finite legacy REAL: $real');
  }
  return quantizeDecimalToMinor(_doubleToPlainDecimal(real), scale);
}

/// [double.toString] may use exponent form for very large/small magnitudes
/// (e.g. "1e+21", "1.5e-7"); expand it to plain decimal text so the exact parser
/// can consume it.
String _doubleToPlainDecimal(double value) {
  final s = value.toString();
  if (!s.contains('e') && !s.contains('E')) return s;
  final negative = s.startsWith('-');
  final body = negative ? s.substring(1) : s;
  final eIdx = body.toLowerCase().indexOf('e');
  final mantissa = body.substring(0, eIdx);
  final exp = int.parse(body.substring(eIdx + 1));
  final dot = mantissa.indexOf('.');
  final intPart = dot < 0 ? mantissa : mantissa.substring(0, dot);
  final fracPart = dot < 0 ? '' : mantissa.substring(dot + 1);
  final digits = '$intPart$fracPart';
  final pointPos = intPart.length + exp; // position of the decimal point in digits
  String out;
  if (pointPos <= 0) {
    out = '0.${'0' * (-pointPos)}$digits';
  } else if (pointPos >= digits.length) {
    out = '$digits${'0' * (pointPos - digits.length)}';
  } else {
    out = '${digits.substring(0, pointPos)}.${digits.substring(pointPos)}';
  }
  return negative ? '-$out' : out;
}

/// int64 minor → exact plain decimal string at [scale] (for transport as a
/// decimal string and for display). Never routes through `double`.
String minorToDecimalString(int minor, int scale) {
  final negative = minor < 0;
  final abs = BigInt.from(minor).abs().toString();
  final String out;
  if (scale == 0) {
    out = abs;
  } else {
    final padded = abs.padLeft(scale + 1, '0');
    final cut = padded.length - scale;
    out = '${padded.substring(0, cut)}.${padded.substring(cut)}';
  }
  return negative ? '-$out' : out;
}
