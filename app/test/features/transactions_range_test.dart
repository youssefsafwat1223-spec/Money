import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/features/transactions/transactions_providers.dart';

void main() {
  test('rolling presets resolve to the current time on each read', () {
    final stored = TransactionsDateRange(
      preset: TransactionsDatePreset.today,
      from: DateTime(2026, 7, 5),
      to: DateTime(2026, 7, 5, 9),
    );

    final effective = effectiveTransactionsRange(
      stored,
      now: DateTime(2026, 7, 5, 12, 16),
    );

    expect(effective.from, DateTime(2026, 7, 5));
    expect(effective.to, DateTime(2026, 7, 5, 12, 16));
  });

  test('custom ranges stay fixed', () {
    final stored = TransactionsDateRange(
      preset: TransactionsDatePreset.custom,
      from: DateTime(2026, 6, 1),
      to: DateTime(2026, 6, 30, 23, 59),
    );

    final effective = effectiveTransactionsRange(
      stored,
      now: DateTime(2026, 7, 5, 12, 16),
    );

    expect(identical(effective, stored), isTrue);
  });
}
