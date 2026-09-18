import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/domain/entities/budget_entity.dart';
import 'package:money_companion/domain/entities/engagement_entities.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/domain/services/budget_alert_planner.dart';

/// THE USER'S OWN WARNING THRESHOLD.
///
/// The early warning used to be a hardcoded 0.75 in the planner and a hardcoded
/// 0.8 in `budget_progress_usecase` — two constants for one idea, so the
/// progress bar could read "warning" while no alert had been sent. Both now
/// read `budget.alertThresholdPercent`, chosen per budget in the form.
///
/// What is NOT configurable, and is asserted below: the 100% exceeded alert,
/// and the 90% escalation for anyone whose threshold sits below it.
BudgetProgressEntry _entry({
  required int amountMinor,
  required int spentMinor,
  int thresholdPercent = BudgetEntity.defaultAlertThresholdPercent,
  String id = 'b1',
  DateTime? periodStart,
}) {
  final start = periodStart ?? DateTime.utc(2026, 7);
  final budget = BudgetEntity(
    id: id,
    categoryId: 'food',
    currency: 'SAR',
    amountMoney: Money(amountMinor, 'SAR'),
    period: BudgetPeriod.monthly,
    startDate: start,
    isActive: true,
    lastNotifiedSpentMoney: Money(0, 'SAR'),
    lastNotifiedPeriodStart: start,
    alertThresholdPercent: thresholdPercent,
  );
  final spent = Money(spentMinor, 'SAR');
  final ratio = spent.toDouble() / budget.amountMoney.toDouble();
  return BudgetProgressEntry(
    budget: budget,
    spent: spent,
    remaining: budget.amountMoney - spent,
    ratio: ratio,
    health: ratio >= 1
        ? BudgetHealth.over
        : (ratio >= thresholdPercent / 100
            ? BudgetHealth.warning
            : BudgetHealth.safe),
    periodStart: start,
    periodEnd: DateTime.utc(2026, 7, 31),
  );
}

void main() {
  const planner = BudgetAlertPlanner();
  final now = DateTime.utc(2026, 7, 15);

  BudgetAlertContent? plan(
    BudgetProgressEntry entry, {
    String lang = 'ar',
    DateTime? at,
  }) =>
      planner.plan(
        entry: entry,
        now: at ?? now,
        currencyLabel: lang == 'en' ? 'SAR' : 'ريال',
        categoryLabel: lang == 'en' ? 'Food' : 'الطعام',
        accountLabel: lang == 'en' ? 'Al Rajhi' : 'الراجحي',
        lang: lang,
      );

  group('the chosen threshold is the one that fires', () {
    for (final percent in const [10, 30, 50, 80, 95, 100]) {
      test('$percent%: silent just below, warns at it', () {
        // One minor unit below the threshold, and exactly on it.
        final below = _entry(
          amountMinor: 100000,
          spentMinor: (100000 * percent ~/ 100) - 1,
          thresholdPercent: percent,
        );
        final at = _entry(
          amountMinor: 100000,
          spentMinor: 100000 * percent ~/ 100,
          thresholdPercent: percent,
        );
        expect(plan(below), isNull,
            reason: 'alerted before the user asked to be');
        expect(plan(at), isNotNull, reason: 'did not alert at the threshold');
      });
    }

    test('30% warns while the old hardcoded 75/80 would still be silent', () {
      // The owner's example. Against the pre-change planner this produced
      // nothing at all.
      final entry = _entry(
        amountMinor: 100000,
        spentMinor: 35000,
        thresholdPercent: 30,
      );
      final content = plan(entry);
      expect(content, isNotNull);
      expect(content!.type, NotificationType.budgetWarning);
    });

    test('the alert states the user\'s own percentage, not a constant', () {
      // Saying "75%" to someone who asked for 30% describes a moment that has
      // not happened yet.
      final ar = plan(_entry(
          amountMinor: 100000, spentMinor: 35000, thresholdPercent: 30));
      expect(ar!.title, contains('٣٠٪'),
          reason: 'Arabic copy must carry the threshold in Eastern digits');
      expect(ar.title, isNot(contains('٧٥')));

      final en = plan(
        _entry(amountMinor: 100000, spentMinor: 35000, thresholdPercent: 30),
        lang: 'en',
      );
      expect(en!.title, contains('30%'));
      expect(en.title, isNot(contains('75%')));
    });
  });

  group('what is not a preference', () {
    test('100% still reports exceeded, whatever the threshold', () {
      for (final percent in const [10, 50, 100]) {
        final content = plan(_entry(
          amountMinor: 100000,
          spentMinor: 120000,
          thresholdPercent: percent,
        ));
        expect(content!.type, NotificationType.budgetOver,
            reason: 'threshold $percent% lost the exceeded state');
      }
    });

    test('the 90% escalation survives a low threshold', () {
      final content = plan(_entry(
        amountMinor: 100000,
        spentMinor: 92000,
        thresholdPercent: 30,
      ));
      // Warning at 30% and then silence until 100% would be worse than either.
      expect(content!.title, contains('على وشك الاكتمال'));
    });

    test('a threshold at or above 90 subsumes the escalation', () {
      // Otherwise 95% would fire "reached 95%" and "almost used up" as two
      // separate alerts for one crossing.
      final content = plan(_entry(
        amountMinor: 100000,
        spentMinor: 96000,
        thresholdPercent: 95,
      ));
      expect(content!.title, contains('٩٥٪'));
      expect(content.title, isNot(contains('على وشك الاكتمال')));
    });

    test('a jump straight past every threshold reports the highest', () {
      final content = plan(_entry(
        amountMinor: 100000,
        spentMinor: 150000,
        thresholdPercent: 30,
      ));
      expect(content!.type, NotificationType.budgetOver,
          reason: '40% -> 150% in one transaction must not report "reached 30%"');
    });
  });

  group('no spam', () {
    test('spending more while already past the threshold reuses the id', () {
      // The id IS the dedup: the platform replaces a notification with the same
      // id rather than stacking another one.
      final first = plan(_entry(
          amountMinor: 100000, spentMinor: 55000, thresholdPercent: 50));
      final second = plan(_entry(
          amountMinor: 100000, spentMinor: 70000, thresholdPercent: 50));
      final third = plan(_entry(
          amountMinor: 100000, spentMinor: 88000, thresholdPercent: 50));
      expect(first!.notifId, second!.notifId);
      expect(second.notifId, third!.notifId);
    });

    test('crossing a HIGHER threshold is a different alert', () {
      final warn = plan(_entry(
          amountMinor: 100000, spentMinor: 55000, thresholdPercent: 50));
      final over = plan(_entry(
          amountMinor: 100000, spentMinor: 105000, thresholdPercent: 50));
      expect(warn!.notifId, isNot(over!.notifId));
    });

    test('the next period can warn again', () {
      final july = plan(_entry(
        amountMinor: 100000,
        spentMinor: 55000,
        thresholdPercent: 50,
        periodStart: DateTime.utc(2026, 7),
      ));
      final august = plan(
        _entry(
          amountMinor: 100000,
          spentMinor: 55000,
          thresholdPercent: 50,
          periodStart: DateTime.utc(2026, 8),
        ),
        at: DateTime.utc(2026, 8, 15),
      );
      expect(july!.notifId, isNot(august!.notifId),
          reason: 'a new budget period must be able to alert again');
    });

    test('two budgets with different thresholds never share an id', () {
      final a = plan(_entry(
          amountMinor: 100000,
          spentMinor: 55000,
          thresholdPercent: 50,
          id: 'b1'));
      final b = plan(_entry(
          amountMinor: 100000,
          spentMinor: 55000,
          thresholdPercent: 50,
          id: 'b2'));
      expect(a!.notifId, isNot(b!.notifId));
    });
  });

  group('the value is normalized before it is trusted', () {
    test('out-of-range and off-grid values snap onto the selectable set', () {
      expect(BudgetEntity.normalizeAlertThreshold(0), 10);
      expect(BudgetEntity.normalizeAlertThreshold(-40), 10);
      expect(BudgetEntity.normalizeAlertThreshold(140), 100);
      expect(BudgetEntity.normalizeAlertThreshold(33), 35);
      expect(BudgetEntity.normalizeAlertThreshold(32), 30);
      expect(BudgetEntity.normalizeAlertThreshold(80), 80);
    });

    test('a corrupt stored threshold still produces a usable alert', () {
      // Belt and braces: the decoder normalizes, but the planner must not
      // divide by a nonsense number even if something else writes the row.
      final content = plan(_entry(
          amountMinor: 100000, spentMinor: 20000, thresholdPercent: 0));
      expect(content, isNotNull, reason: 'normalized to 10%, so 20% alerts');
    });
  });

  test('a new budget defaults to 80, which is what Settings has promised', () {
    final budget = BudgetEntity(
      id: 'b1',
      categoryId: 'food',
      currency: 'SAR',
      amountMoney: Money(100000, 'SAR'),
      period: BudgetPeriod.monthly,
      lastNotifiedSpentMoney: Money(0, 'SAR'),
      isActive: true,
      startDate: DateTime.utc(2026, 7),
      lastNotifiedPeriodStart: DateTime.utc(2026, 7),
    );
    expect(budget.alertThresholdPercent, 80);
  });
}
