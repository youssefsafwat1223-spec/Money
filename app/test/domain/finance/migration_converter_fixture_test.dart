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
    // The property this test is named for is linearity, but it used to assert a
    // wall-clock budget (<2s for 100k). That measures the machine as much as the
    // algorithm: it passed idle and failed at 2926ms under full-suite load,
    // which is a flaky gate rather than a broken converter.
    //
    // Linearity is measured instead, by comparing two sizes: doubling the work
    // must roughly double the time. A quadratic regression — the actual risk —
    // would show ~4x and still fail loudly. A generous absolute ceiling stays as
    // a backstop against a catastrophic slowdown.
    int timeFor(int n) {
      var acc = BigInt.zero;
      final sw = Stopwatch()..start();
      for (var i = 0; i < n; i++) {
        acc += BigInt.from(legacyRealToMinor(19.99, 2));
      }
      sw.stop();
      expect(acc, BigInt.from(n) * BigInt.from(1999)); // exact aggregate
      return sw.elapsedMicroseconds;
    }

    timeFor(20000); // warm up, so JIT compilation is not charged to the first
    final small = timeFor(50000);
    final large = timeFor(100000);

    // 2x the work in under 3x the time. Quadratic would be ~4x.
    expect(large, lessThan(small * 3),
        reason: 'doubling rows took ${(large / small).toStringAsFixed(1)}x the '
            'time — that is superlinear, which is the regression this guards');
    expect(large, lessThan(30 * 1000 * 1000),
        reason: 'backstop: 100k conversions should never take 30s');
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
