import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../entities/engagement_entities.dart';
import '../finance/money.dart';

/// Deterministic notification id for a (budget, period, threshold) triple —
/// SHA-256 instead of hashCode for the same stability reason documented in
/// notification_planner.dart. Distinct base (95000) from bill (92000) and
/// goal (93000) reminder ids.
int _budgetAlertNotificationId(
  String budgetId,
  DateTime periodStart,
  int bucket,
) {
  final stableId = '$budgetId:${periodStart.toIso8601String()}:$bucket';
  final digest = sha256.convert(utf8.encode(stableId));
  final value = (digest.bytes[0] << 24) |
      (digest.bytes[1] << 16) |
      (digest.bytes[2] << 8) |
      digest.bytes[3];
  return 95000 + (value.abs() % 900000);
}

class BudgetAlertContent {
  const BudgetAlertContent({
    required this.notifId,
    required this.type,
    required this.title,
    required this.body,
  });

  final int notifId;
  final NotificationType type;
  final String title;
  final String body;
}

/// Turns a budget's current spend snapshot into a local-notification payload
/// once it crosses the 75%/90%/100% thresholds. Pure and side-effect free —
/// callers (SMS capture, manual transaction add) own the actual
/// LocalNotificationService.showBudgetAlert call and its dedup id.
class BudgetAlertPlanner {
  const BudgetAlertPlanner();

  /// UX-037 — [accountLabel] is REQUIRED and nullable rather than optional.
  ///
  /// The account was already resolved by the only caller and simply never
  /// reached the text. Making it optional would let a future caller silently
  /// drop it again and reproduce the finding; making it required-and-nullable
  /// forces the caller to state that it genuinely does not know, which happens
  /// only when there is no account at all.
  BudgetAlertContent? plan({
    required BudgetProgressEntry entry,
    required DateTime now,
    required String currencyLabel,
    required String categoryLabel,
    required String? accountLabel,
  }) {
    final ratio = entry.ratio;
    final bucket = ratio >= 1.0
        ? 3
        : ratio >= 0.9
            ? 2
            : ratio >= 0.75
                ? 1
                : 0;
    if (bucket == 0) return null;

    final budget = entry.budget;
    final daysTotal =
        entry.periodEnd.difference(entry.periodStart).inDays.clamp(1, 3660);
    final daysPassed =
        now.difference(entry.periodStart).inDays.clamp(1, daysTotal);
    final daysRemaining = (daysTotal - daysPassed).clamp(0, daysTotal);
    final projectedIncrement = entry.spent.applyRate(
      rateNumerator: BigInt.from(daysRemaining),
      rateDenominator: BigInt.from(daysPassed),
    );
    final projected = entry.spent + projectedIncrement;
    final zero = Money.zero(budget.currency);
    final remaining = entry.remaining.compareTo(zero) < 0
        ? zero
        : entry.remaining.compareTo(budget.amountMoney) > 0
            ? budget.amountMoney
            : entry.remaining;

    String fmt(Money value) => value.toDecimalString();

    // UX-037 — a budget alert must say WHICH budget crossed WHICH threshold.
    //
    // The QA's case: a shopping-budget warning arriving right after an
    // unrelated food purchase read as though the food transaction had been
    // filed under shopping. The notification named neither the account nor the
    // threshold, so the only context the user had was the transaction they had
    // just watched arrive — and they attributed the alert to it.
    //
    // Naming the budget's own account and the crossed threshold removes that
    // reading: the alert now describes a state of a named budget rather than
    // an unattributed reaction to a recent event.
    final scope =
        accountLabel == null ? categoryLabel : '$categoryLabel في $accountLabel';

    final String title;
    final String body;
    if (bucket == 3) {
      title = 'تجاوزت $categoryLabel';
      body = 'ميزانية $scope وصلت ١٠٠٪ من حدّها — '
          'صرفت ${fmt(entry.spent - budget.amountMoney)} $currencyLabel زيادة عنها.';
    } else if (bucket == 2) {
      title = '$categoryLabel على وشك الاكتمال';
      body = 'ميزانية $scope عدّت ٩٠٪ — بقيلك ${fmt(remaining)} $currencyLabel '
          'فقط، ومعدلك الحالي سيستهلكها في $daysRemaining يوم.';
    } else {
      title = 'وصلت ٧٥٪ من $categoryLabel';
      body = projected.compareTo(budget.amountMoney) > 0
          ? 'ميزانية $scope عدّت ٧٥٪ — بقيلك ${fmt(remaining)} $currencyLabel. '
              'إذا استمر معدلك قد تتجاوز الميزانية بـ${fmt(projected - budget.amountMoney)} $currencyLabel.'
          : 'ميزانية $scope عدّت ٧٥٪ — بقيلك ${fmt(remaining)} $currencyLabel '
              'حتى نهاية الفترة.';
    }

    final type = bucket == 3
        ? NotificationType.budgetOver
        : NotificationType.budgetWarning;

    return BudgetAlertContent(
      notifId: _budgetAlertNotificationId(budget.id, entry.periodStart, bucket),
      type: type,
      title: title,
      body: body,
    );
  }
}
