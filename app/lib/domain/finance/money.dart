import 'currency_scale.dart';
import 'decimal_minor.dart';

/// MALI-026 (Phase-8 B8-0) — the canonical fixed-precision Money value type.
///
/// Money is `int` minor units + an ISO currency code. All arithmetic on
/// persisted financial totals is exact integer/BigInt math; no binary `double`
/// is ever used to derive a canonical amount. Cross-currency arithmetic is
/// forbidden (currency isolation is a Phase-4 invariant). This is the FOUNDATION
/// only — schema/repository/wire wiring is a later, separately-approved step.
class Money implements Comparable<Money> {
  /// Canonical constructor. [currency] must be a supported currency (Decision 2);
  /// an unknown code throws [UnsupportedCurrencyException] — Money never guesses
  /// a scale.
  Money(this.minorUnits, String currency) : currency = _requireSupported(currency);

  /// Zero in [currency].
  Money.zero(String currency) : this(0, currency);

  /// Signed minor units (int64 contract).
  final int minorUnits;

  /// Normalised (upper-case) ISO currency code.
  final String currency;

  int get scale => currencyScale(currency);

  bool get isZero => minorUnits == 0;
  bool get isNegative => minorUnits < 0;

  static String _requireSupported(String currency) {
    final code = currency.trim().toUpperCase();
    currencyScale(code); // throws UnsupportedCurrencyException if unknown
    return code;
  }

  /// EXACT parse of user-entered decimal text (Decision 1 case A). Rejects any
  /// value carrying non-zero precision beyond the currency scale — user money is
  /// never silently rounded.
  factory Money.parse(String decimalText, String currency) {
    final code = _requireSupported(currency);
    return Money(parseExactDecimalToMinor(decimalText, currencyScale(code)), code);
  }

  /// Legacy REAL (binary double) → Money (Decision 1 case B — MIGRATION ONLY).
  /// Deterministic quantization via the shortest round-trip decimal; no float
  /// `* pow10`. Do NOT use for new user input.
  factory Money.fromLegacyReal(double real, String currency) {
    final code = _requireSupported(currency);
    return Money(legacyRealToMinor(real, currencyScale(code)), code);
  }

  void _requireSameCurrency(Money other) {
    if (other.currency != currency) {
      throw ArgumentError(
          'cross-currency arithmetic is forbidden: $currency vs ${other.currency}');
    }
  }

  Money operator +(Money other) {
    _requireSameCurrency(other);
    return Money(
        checkedInt64(BigInt.from(minorUnits) + BigInt.from(other.minorUnits)),
        currency);
  }

  Money operator -(Money other) {
    _requireSameCurrency(other);
    return Money(
        checkedInt64(BigInt.from(minorUnits) - BigInt.from(other.minorUnits)),
        currency);
  }

  Money operator -() => Money(checkedInt64(-BigInt.from(minorUnits)), currency);

  /// Exact multiplication by a whole factor (e.g. a monthly bill × 12). Wide
  /// intermediate, checked back to int64.
  Money operator *(int factor) =>
      Money(checkedInt64(BigInt.from(minorUnits) * BigInt.from(factor)), currency);

  /// Exact aggregation of same-currency amounts (integer sum; no float fold).
  static Money sum(Iterable<Money> amounts, String currency) {
    final code = _requireSupported(currency);
    var acc = BigInt.zero;
    for (final m in amounts) {
      if (m.currency != code) {
        throw ArgumentError('sum() mixes currencies: $code vs ${m.currency}');
      }
      acc += BigInt.from(m.minorUnits);
    }
    return Money(checkedInt64(acc), code);
  }

  /// Rate/percentage/derived-money contract (Decision 1 case C, Correction D):
  /// `Money × (rateNumerator / rateDenominator)` computed in BigInt, rounded
  /// HALF-AWAY-FROM-ZERO exactly ONCE, into [targetCurrency] (default: same).
  /// The rate is an exact ratio, never a binary double.
  Money applyRate({
    required BigInt rateNumerator,
    required BigInt rateDenominator,
    String? targetCurrency,
  }) {
    if (rateDenominator <= BigInt.zero) {
      throw ArgumentError('rate denominator must be positive');
    }
    final code = _requireSupported(targetCurrency ?? currency);
    // Compute at the TARGET scale exactly, then round once:
    //   result_minor = round( minor * num * 10^(targetScale-scale) / den )
    final scaleDelta = currencyScale(code) - scale;
    var numer = BigInt.from(minorUnits) * rateNumerator;
    var denom = rateDenominator;
    if (scaleDelta >= 0) {
      numer *= BigInt.from(10).pow(scaleDelta);
    } else {
      denom *= BigInt.from(10).pow(-scaleDelta);
    }
    return Money(checkedInt64(roundHalfAwayFromZero(numer, denom)), code);
  }

  /// Deterministic largest-remainder split into [weights.length] parts whose
  /// sum is EXACTLY this amount (no cent lost or minted). Ties break by index.
  List<Money> allocate(List<int> weights) {
    if (weights.isEmpty) throw ArgumentError('weights must be non-empty');
    if (weights.any((w) => w < 0)) {
      throw ArgumentError('weights must be non-negative');
    }
    final totalWeight = weights.fold<BigInt>(BigInt.zero, (s, w) => s + BigInt.from(w));
    if (totalWeight == BigInt.zero) throw ArgumentError('weights sum to zero');

    final negative = minorUnits < 0;
    final absTotal = BigInt.from(minorUnits).abs();
    final floors = <BigInt>[];
    final remainders = <BigInt>[];
    for (final w in weights) {
      final product = absTotal * BigInt.from(w);
      floors.add(product ~/ totalWeight);
      remainders.add(product % totalWeight);
    }
    final distributed = floors.fold<BigInt>(BigInt.zero, (s, f) => s + f);
    var left = absTotal - distributed;
    // hand out the leftover units to the largest remainders (ties: lowest index)
    final order = List<int>.generate(weights.length, (i) => i)
      ..sort((a, b) {
        final c = remainders[b].compareTo(remainders[a]);
        return c != 0 ? c : a.compareTo(b);
      });
    var k = 0;
    while (left > BigInt.zero) {
      floors[order[k % order.length]] += BigInt.one;
      left -= BigInt.one;
      k++;
    }
    return [
      for (final f in floors)
        Money(checkedInt64(negative ? -f : f), currency),
    ];
  }

  /// Exact plain-decimal string at the currency scale (transport as a decimal
  /// STRING / display). Never routes through `double`.
  String toDecimalString() => minorToDecimalString(minorUnits, scale);

  @override
  int compareTo(Money other) {
    _requireSameCurrency(other);
    return minorUnits.compareTo(other.minorUnits);
  }

  @override
  bool operator ==(Object other) =>
      other is Money &&
      other.minorUnits == minorUnits &&
      other.currency == currency;

  @override
  int get hashCode => Object.hash(minorUnits, currency);

  @override
  String toString() => 'Money(${toDecimalString()} $currency)';
}
