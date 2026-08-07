// Phase-7 B2-C — date-section grouping is precomputed in the provider layer
// (TransactionsView.sections), by LOCAL calendar day, in one ordered pass.
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/domain/entities/transaction_entity.dart';
import 'package:money_companion/features/common/category_catalog.dart';
import 'package:money_companion/features/transactions/transactions_providers.dart';

TransactionEntity _tx(String id, DateTime occurredAt) => TransactionEntity(
      id: id,
      amount: 1,
      currency: 'SAR',
      type: TransactionTypeEntity.payment,
      source: TransactionSourceEntity.bank,
      occurredAt: occurredAt,
      rawMessage: '',
      parseConfidence: 1,
      status: TransactionStatus.confirmed,
      createdAt: occurredAt,
      updatedAt: occurredAt,
    );

TransactionsView _view(List<TransactionEntity> txns) => TransactionsView(
      transactions: txns,
      catalog: CategoryCatalog(const []),
      range: transactionsRangeForPreset(TransactionsDatePreset.thisMonth),
    );

void main() {
  test('rows are grouped by local calendar day, in order, no row lost', () {
    // Two days, newest-first (as the list is ordered occurred_at DESC).
    final d2 = DateTime(2026, 6, 15, 9); // local
    final d1 = DateTime(2026, 6, 14, 20);
    final txns = [
      _tx('a', d2.add(const Duration(hours: 3))),
      _tx('b', d2),
      _tx('c', d1.add(const Duration(hours: 1))),
      _tx('d', d1),
    ];
    final sections = _view(txns).sections;

    expect(sections.length, 2);
    expect(sections[0].day, DateTime(2026, 6, 15));
    expect(sections[0].transactions.map((t) => t.id), ['a', 'b']);
    expect(sections[1].day, DateTime(2026, 6, 14));
    expect(sections[1].transactions.map((t) => t.id), ['c', 'd']);
    // Every row present exactly once.
    final all = sections.expand((s) => s.transactions).map((t) => t.id).toList();
    expect(all, ['a', 'b', 'c', 'd']);
  });

  test('empty list → no sections', () {
    expect(_view(const []).sections, isEmpty);
  });

  test('a single day yields one section', () {
    final day = DateTime(2026, 6, 15, 10);
    final s = _view([
      _tx('x', day),
      _tx('y', day.add(const Duration(minutes: 5))),
    ]).sections;
    expect(s.length, 1);
    expect(s.single.transactions.length, 2);
  });
}
