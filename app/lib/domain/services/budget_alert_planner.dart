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
  ///
  /// [lang] is the reader's language, read from the settings row by the caller.
  /// This runs in a background isolate with no BuildContext, so it follows the
  /// same contract as every other notification builder: the words are chosen
  /// here from a language code, not resolved from an ARB at a widget.
  BudgetAlertContent? plan({
    required BudgetProgressEntry entry,
    required DateTime now,
    required String currencyLabel,
    required String categoryLabel,
    required String? accountLabel,
    String lang = 'ar',
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
    final en = lang == 'en';
    final scope = accountLabel == null
        ? categoryLabel
        : en
            ? '$categoryLabel in $accountLabel'
            : '$categoryLabel في $accountLabel';

    final String title;
    final String body;
    if (bucket == 3) {
      final over = fmt(entry.spent - budget.amountMoney);
      title = en ? 'You went over $categoryLabel' : 'تجاوزت $categoryLabel';
      body = en
          ? 'The $scope budget reached 100% of its limit — '
              'you spent $over $currencyLabel over it.'
          : 'ميزانية $scope بلغت ١٠٠٪ من حدّها — '
              'أنفقت $over $currencyLabel زيادة عنها.';
    } else if (bucket == 2) {
      final left = fmt(remaining);
      title = en
          ? '$categoryLabel is almost used up'
          : '$categoryLabel على وشك الاكتمال';
      body = en
          ? 'The $scope budget reached 90% — only $left $currencyLabel left, '
              'and at your current rate it runs out in '
              '${_enDays(daysRemaining)}.'
          : 'ميزانية $scope بلغت ٩٠٪ — تبقّى لك $left $currencyLabel '
              'فقط، ومعدّلك الحالي سيستهلكها خلال ${_arDays(daysRemaining)}.';
    } else {
      final left = fmt(remaining);
      title = en
          ? '$categoryLabel has reached 75%'
          : 'وصلت ٧٥٪ من $categoryLabel';
      if (projected.compareTo(budget.amountMoney) > 0) {
        final overBy = fmt(projected - budget.amountMoney);
        body = en
            ? 'The $scope budget reached 75% — $left $currencyLabel left. '
                'At your current rate you may go over by '
                '$overBy $currencyLabel.'
            : 'ميزانية $scope بلغت ٧٥٪ — تبقّى لك $left $currencyLabel. '
                'إذا استمرّ معدّلك فقد تتجاوز الميزانية بـ$overBy $currencyLabel.';
      } else {
        body = en
            ? 'The $scope budget reached 75% — $left $currencyLabel left '
                'for the rest of the period.'
            : 'ميزانية $scope بلغت ٧٥٪ — تبقّى لك $left $currencyLabel '
                'حتى نهاية الفترة.';
      }
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

/// Arabic counts days with five categories; a bare "$n يوم" is wrong for every
/// value except 1 and is the kind of agreement error the MSA guard exists to
/// catch. `ar.arb` handles this with an ICU plural, but this builder has no
/// ARB, so the same five categories are spelled out here.
String _arDays(int n) => switch (n) {
      0 => 'أقل من يوم',
      1 => 'يوم واحد',
      2 => 'يومين',
      >= 3 && <= 10 => '$n أيام',
      _ => '$n يومًا',
    };

String _enDays(int n) => n == 1 ? '1 day' : '$n days';
