import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/domain/finance/financial_period.dart';
import 'package:money_companion/features/transactions/transactions_providers.dart';

/// V1 annual reporting (charter: REQUIRED_PRODUCT_CHANGE_3).
///
/// Deliberately implemented as two presets on the existing
/// `TransactionsDatePreset` rather than a second reporting stack: the reports
/// screen, the transactions list, the category breakdown, the trends and the
/// charts all already resolve their window through
/// `transactionsRangeForPreset`, so a preset reaches every one of them at once.
void main() {
  test('this year starts on 1 January and is clamped to now', () {
    final now = DateTime(2026, 9, 15, 14, 30);
    final range =
        transactionsRangeForPreset(TransactionsDatePreset.thisYear, now: now);

    expect(range.from, DateTime(2026, 1, 1));
    // Never report a window running into the future — an unfinished year would
    // otherwise skew the daily average and the "highest day" for months.
    expect(range.to, now);
    expect(range.from.isBefore(range.to), isTrue);
  });

  test('previous year is the whole year, and stops before this one starts', () {
    final now = DateTime(2026, 9, 15);
    final range = transactionsRangeForPreset(
      TransactionsDatePreset.previousYear,
      now: now,
    );

    expect(range.from, DateTime(2025, 1, 1));
    expect(range.to.year, 2025);
    expect(range.to.month, 12);
    expect(range.to.day, 31);
    // Must not bleed into this year, or January would be counted twice.
    expect(range.to.isBefore(DateTime(2026, 1, 1)), isTrue);
  });

  test('the year window agrees with the canonical period resolver', () {
    // FinancialPeriod is the one contract every surface derives windows from.
    // If the preset drifted from it, reports and budgets would disagree about
    // what "this year" means.
    final now = DateTime(2026, 6, 1);
    final canonical = FinancialPeriod.year(now);
    final preset =
        transactionsRangeForPreset(TransactionsDatePreset.thisYear, now: now);

    expect(preset.from, canonical.from);
    expect(canonical.to, DateTime(2027, 1, 1));
  });

  test('a January date still resolves a valid, non-empty year window', () {
    // Boundary: on 1 January the clamped "this year" window is nearly empty but
    // must stay ordered rather than inverting.
    final now = DateTime(2026, 1, 1, 0, 30);
    final range =
        transactionsRangeForPreset(TransactionsDatePreset.thisYear, now: now);
    expect(range.from, DateTime(2026, 1, 1));
    expect(range.from.isBefore(range.to), isTrue);

    final prev = transactionsRangeForPreset(
      TransactionsDatePreset.previousYear,
      now: now,
    );
    expect(prev.from, DateTime(2025, 1, 1));
    expect(prev.to.isBefore(range.from), isTrue);
  });

  test('a leap year is covered end to end', () {
    final now = DateTime(2025, 3, 1);
    final prev = transactionsRangeForPreset(
      TransactionsDatePreset.previousYear,
      now: now,
    );
    expect(prev.from, DateTime(2024, 1, 1));
    expect(prev.to.month, 12);
    expect(prev.to.day, 31);
  });

  test('both presets are offered by every picker', () {
    // All three range pickers build their chips from `.values`, so presence in
    // the enum is what makes them reachable.
    expect(
      TransactionsDatePreset.values,
      containsAll([
        TransactionsDatePreset.thisYear,
        TransactionsDatePreset.previousYear,
      ]),
    );
  });

  test('every preset resolves a well-ordered range', () {
    // Guards the whole set, not just the new pair: an inverted range silently
    // returns zero rows, which reads as "you spent nothing".
    final now = DateTime(2026, 9, 15, 10);
    for (final preset in TransactionsDatePreset.values) {
      if (preset == TransactionsDatePreset.custom) continue;
      final range = transactionsRangeForPreset(preset, now: now);
      expect(range.from.isBefore(range.to), isTrue, reason: preset.name);
    }
  });
}
