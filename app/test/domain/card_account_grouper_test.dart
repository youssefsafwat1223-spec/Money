import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/domain/services/card_account_grouper.dart';

CardAccountBreakdownRow _row(
  String last4,
  String? accountId, {
  int count = 1,
  double out = 100,
  double income = 0,
  String sample = 'card 1234 visa',
  String currency = 'SAR',
}) =>
    CardAccountBreakdownRow(
      last4: last4,
      currency: currency,
      accountId: accountId,
      totalIn: income,
      totalOut: out,
      count: count,
      sample: sample,
    );

void main() {
  const grouper = CardAccountGrouper();

  test('single-account card is assigned to that account', () {
    final result = grouper.group([_row('1234', 'acc-a', count: 3)]);
    expect(result.byAccount['acc-a']?.single.last4, '1234');
    expect(result.unassigned, isEmpty);
  });

  test('card with only null-account transactions is unassigned', () {
    final result = grouper.group([_row('5678', null, count: 2)]);
    expect(result.byAccount, isEmpty);
    expect(result.unassigned.single.last4, '5678');
  });

  test('card seen on two different accounts is unassigned (no forcing)', () {
    final result = grouper.group([
      _row('9999', 'acc-a', count: 5),
      _row('9999', 'acc-b', count: 1),
    ]);
    expect(result.byAccount, isEmpty);
    expect(result.unassigned.single.last4, '9999');
  });

  test('one account + some null-account rows still assigns confidently', () {
    final result = grouper.group([
      _row('4321', 'acc-a', count: 4),
      _row('4321', null, count: 2),
    ]);
    expect(result.byAccount['acc-a']?.single.last4, '4321');
    expect(result.unassigned, isEmpty);
  });

  test('summary aggregates in/out/count across rows of the same card', () {
    final result = grouper.group([
      _row('1111', 'acc-a', count: 2, out: 30, income: 0),
      _row('1111', 'acc-a', count: 1, out: 0, income: 50),
    ]);
    final card = result.byAccount['acc-a']!.single;
    expect(card.totalOut, 30);
    expect(card.totalIn, 50);
    expect(card.count, 3);
  });

  test('relaxed confidence assigns to a dominant account', () {
    const relaxed = CardAccountGrouper(confidence: 0.8);
    final result = relaxed.group([
      _row('2222', 'acc-a', count: 9),
      _row('2222', 'acc-b', count: 1),
    ]);
    expect(result.byAccount['acc-a']?.single.last4, '2222');
    expect(result.unassigned, isEmpty);
  });
}
