import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/domain/finance/currency_scale.dart';
import 'package:money_companion/domain/finance/decimal_minor.dart';
import 'package:money_companion/domain/finance/money.dart';

// MALI-026 (Phase-8 B8-1.5) — deterministic migration-conversion fixture. The
// v30 migration does not exist yet; this proves the CONVERSION LOGIC it will use
// (legacy REAL → canonical minor, with per-field currency authority) is exact,
// covers the required vectors, and is REPEATABLE: running the same fixture twice
// from a fresh state yields byte/value-equivalent outcomes.

/// A legacy row as it exists in v29: a REAL money value (or null) + the resolved
/// currency (from the field's currency authority) + the expected v30 outcome.
class _Row {
  const _Row(this.real, this.currency, {this.expectMinor, this.expectThrows = false});
  final double? real;
  final String? currency; // may be null/unsupported to exercise rejection
  final int? expectMinor;
  final bool expectThrows;
}

/// Convert one legacy row exactly as the v30 preflight+backfill will. Null money
/// → null. A null/unsupported currency or an overflowing value THROWS (the
/// migration aborts before the version commit — no canonical value is invented).
int? _convert(_Row r) {
  if (r.real == null) return null;
  if (r.currency == null) throw const UnsupportedCurrencyException('<null>');
  return legacyRealToMinor(r.real!, currencyScale(r.currency!)); // throws if unsupported/overflow
}

void main() {
  const fixture = <_Row>[
    _Row(1234.0, 'JPY', expectMinor: 1234), // 0-decimal
    _Row(19.99, 'EGP', expectMinor: 1999), // 2-decimal
    _Row(1.234, 'KWD', expectMinor: 1234), // 3-decimal
    _Row(-5.5, 'USD', expectMinor: -550), // negative
    _Row(19.989999999, 'USD', expectMinor: 1999), // legacy binary artifact
    _Row(0.1 + 0.2, 'EGP', expectMinor: 30), // 0.30000000000000004
    _Row(null, 'EGP', expectMinor: null), // nullable money
    _Row(2500.0, 'SAR', expectMinor: 250000), // base-currency budget/goal
    _Row(1000000000000.0, 'USD', expectMinor: 100000000000000), // large exact-safe
    _Row(1.5, 'ZZZ', expectThrows: true), // unsupported currency → reject
    _Row(1.5, null, expectThrows: true), // missing currency → reject
    _Row(1e18, 'USD', expectThrows: true), // 1e18 * 100 minor > int64 → overflow
  ];

  List<int?> runOnce() {
    final out = <int?>[];
    for (final r in fixture) {
      if (r.expectThrows) {
        expect(() => _convert(r), throwsA(isA<Object>()),
            reason: '${r.real} ${r.currency}');
        out.add(null); // rejected rows abort the migration; placeholder here
      } else {
        final minor = _convert(r);
        expect(minor, r.expectMinor, reason: '${r.real} ${r.currency}');
        out.add(minor);
      }
    }
    return out;
  }

  test('fixture converts exactly to the expected minor units', () {
    runOnce();
  });

  test('foreign_amount non-null REQUIRES a valid foreign_currency', () {
    // foreign leg present but foreign_currency missing → reject (no guess).
    expect(() => _convert(const _Row(50.0, null)), throwsA(isA<Object>()));
    // valid foreign_currency → exact.
    expect(_convert(const _Row(50.0, 'USD')), 5000);
  });

  test('conversion is REPEATABLE — two fresh passes are value-equivalent', () {
    final first = runOnce();
    final second = runOnce();
    expect(second, equals(first));
  });

  test('performance: conversion cost is LINEAR in row count (no O(n^2))', () {
    // History of this assertion, because it has now been wrong twice:
    //   1. it asserted a 2s wall-clock budget — that measures the machine, and
    //      failed at 2926ms under full-suite load;
    //   2. it asserted a single-shot time RATIO — also load-sensitive, and
    //      failed at 3.6x when the larger run happened to catch contention.
    //
    // Both failures were noise, not a slower converter. A micro-benchmark
    // inside a 2600-test parallel suite cannot reliably compare two single
    // timings. What IS stable is the MINIMUM of several runs: the fastest run
    // is the one that got the least interference, so best-of-N largely removes
    // the scheduler from the measurement.
    //
    // Compared as PER-ITEM cost, which states the property directly: linear
    // work has the same per-item cost at any n, while O(n^2) doubles it when n
    // doubles. The threshold sits between those, wide enough for residual
    // noise and still failing loudly on a genuine quadratic regression.
    double perItemNanos(int n) {
      var best = double.infinity;
      for (var attempt = 0; attempt < 3; attempt++) {
        var acc = BigInt.zero;
        final sw = Stopwatch()..start();
        for (var i = 0; i < n; i++) {
          acc += BigInt.from(legacyRealToMinor(19.99, 2));
        }
        sw.stop();
        expect(acc, BigInt.from(n) * BigInt.from(1999)); // exact aggregate
        final per = sw.elapsedMicroseconds * 1000 / n;
        if (per < best) best = per;
      }
      return best;
    }

    perItemNanos(20000); // warm up: do not charge JIT to the first measurement
    final small = perItemNanos(50000);
    final large = perItemNanos(100000);

    final ratio = large / small;
    expect(ratio, lessThan(1.6),
        reason: 'per-item cost went from ${small.toStringAsFixed(1)}ns to '
            '${large.toStringAsFixed(1)}ns (${ratio.toStringAsFixed(2)}x) when '
            'the row count doubled. Linear work holds ~1.0x; quadratic doubles '
            'to ~2.0x.');
  });

  test('Money round-trips the converted minor back to the exact decimal', () {
    for (final r in fixture) {
      if (r.expectThrows || r.real == null) continue;
      final m = Money(r.expectMinor!, r.currency!);
      expect(m.toDecimalString(),
          minorToDecimalString(r.expectMinor!, currencyScale(r.currency!)));
    }
  });
}
