import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// UX-025, UX-027, UX-006 — three findings about what a card tells you and what
/// it lets you do.
void main() {
  group('UX-025 — a goal shows its date and its required rate', () {
    final screen =
        File('lib/features/goals/goals_screen.dart').readAsStringSync();

    test('the card computes pacing from exact Money', () {
      expect(screen, contains('goalPacing('));
      expect(screen, contains('target: goal.targetMoney'),
          reason: 'the double getters are display-only; pacing is arithmetic');
      expect(screen, contains('saved: goal.savedMoney'));
    });

    test('the deadline and the monthly rate are rendered', () {
      expect(screen, contains('_goalDeadlineLabel'));
      expect(screen, contains('MoneyText(rate'),
          reason: 'R-8 — a required contribution is money');
      expect(screen, contains('/شهر'));
    });

    test('an overdue goal says so instead of showing a fictional rate', () {
      expect(screen, contains('pacing.isOverdue'));
      expect(screen, contains('تجاوز الموعد المستهدف'));
    });

    test('the deadline reached the PDF export before it reached the app', () {
      // Recorded because it is the sharpest evidence the data was trusted:
      // the field ordered the Home preview and printed in the exported report
      // while the screen that manages the goal never showed it.
      final composer =
          File('lib/features/reporting/composition/report_composer.dart')
              .readAsStringSync();
      expect(composer, contains('g.deadline'),
          reason: 'export already rendered it');
    });
  });

  group('UX-027 — delete is no longer the only affordance on a plan', () {
    final screen =
        File('lib/features/plans/plans_screen.dart').readAsStringSync();

    test('the card offers edit, not just delete', () {
      expect(screen, contains('PopupMenuButton<String>'));
      expect(screen, contains("value: 'edit'"));
      expect(screen, contains('PlanFormSheet.show(context, existing: plan)'));
    });

    test('the bare trash icon is gone from the card header', () {
      expect(screen.contains("tooltip: 'حذف',\n                icon: Icon(AppLucideIcons.trash2"),
          isFalse,
          reason: 'the most prominent control must not be the destructive one');
    });

    test('delete is still confirmed', () {
      // Making delete less prominent must not make it less guarded.
      expect(screen, contains('_confirmDelete(context, ref)'));
      expect(screen, contains('حذف الخطة؟'));
    });
  });

  group('UX-006 — a closed plan says it is closed', () {
    final screen =
        File('lib/features/plans/plans_screen.dart').readAsStringSync();

    test('closed plans carry a «منتهية» badge', () {
      expect(screen, contains('plan.status == PlanStatus.closed'));
      expect(screen, contains('منتهية'));
    });
  });
}
