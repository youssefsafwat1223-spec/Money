import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/domain/finance/goal_pacing.dart';
import 'package:money_companion/domain/finance/money.dart';

Money sar(int minor) => Money(minor, 'SAR');

void main() {
  final now = DateTime(2026, 9, 1);

  test('projects arrival from the rate the goal was ACTUALLY funded at', () {
    // 5 months old, 5,000 saved → 1,000/month. 5,000 left → 5 more months.
    final p = goalProjection(
      target: sar(1000000),
      saved: sar(500000),
      createdAt: DateTime(2026, 4, 1),
      deadline: null,
      now: now,
    );

    expect(p.actualPerMonth, sar(100000));
    expect(p.monthsToTarget, 5);
    expect(p.arrivesOn, DateTime(2027, 2, 1));
  });

  test('reports how late that lands against the deadline', () {
    final p = goalProjection(
      target: sar(1000000),
      saved: sar(500000),
      createdAt: DateTime(2026, 4, 1),
      deadline: DateTime(2026, 12, 1),
      now: now,
    );

    expect(p.arrivesOn, DateTime(2027, 2, 1));
    expect(p.monthsLate, 2);
    expect(p.isLate, isTrue);
  });

  test('a pace that beats the deadline is not late', () {
    final p = goalProjection(
      target: sar(1000000),
      saved: sar(900000),
      createdAt: DateTime(2026, 4, 1),
      deadline: DateTime(2027, 6, 1),
      now: now,
    );

    expect(p.isLate, isFalse);
    expect(p.monthsLate! <= 0, isTrue);
  });

  test('no contributions yet projects no date — never an infinity', () {
    final p = goalProjection(
      target: sar(1000000),
      saved: sar(0),
      createdAt: DateTime(2026, 4, 1),
      deadline: DateTime(2026, 12, 1),
      now: now,
    );

    expect(p.actualPerMonth.isZero, isTrue);
    expect(p.monthsToTarget, isNull);
    expect(p.arrivesOn, isNull);
    expect(p.monthsLate, isNull);
    expect(p.isLate, isFalse);
  });

  test('an already-met goal projects nothing', () {
    final p = goalProjection(
      target: sar(500000),
      saved: sar(500000),
      createdAt: DateTime(2026, 4, 1),
      deadline: DateTime(2026, 12, 1),
      now: now,
    );

    expect(p.arrivesOn, isNull);
  });

  test('a days-old goal is measured over a month, not over a fraction', () {
    // Created 3 days ago with 300 saved. Measuring over 0.1 months would claim
    // 3,000/month and project an absurdly early arrival.
    final p = goalProjection(
      target: sar(1000000),
      saved: sar(30000),
      createdAt: now.subtract(const Duration(days: 3)),
      deadline: null,
      now: now,
    );

    expect(p.actualPerMonth, sar(30000));
    expect(p.monthsToTarget, 33); // ceil((1,000,000 − 30,000) / 30,000)
  });

  test('a partial month still counts as a whole month to live through', () {
    // 1,000 left at 900/month is two months, not one.
    final p = goalProjection(
      target: sar(1000000),
      saved: sar(900000),
      createdAt: DateTime(2026, 8, 2),
      deadline: null,
      now: now,
    );

    expect(p.actualPerMonth, sar(900000));
    expect(p.monthsToTarget, 1);
  });

  test('no deadline means no lateness claim', () {
    final p = goalProjection(
      target: sar(1000000),
      saved: sar(500000),
      createdAt: DateTime(2026, 4, 1),
      deadline: null,
      now: now,
    );

    expect(p.monthsLate, isNull);
    expect(p.isLate, isFalse);
  });
}
