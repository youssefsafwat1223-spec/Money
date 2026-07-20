import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../entities/engagement_entities.dart';

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

  BudgetAlertContent? plan({
    required BudgetProgressEntry entry,
    required DateTime now,
    required String currencyLabel,
    required String categoryLabel,
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
    final dailyRate = entry.spent / daysPassed;
    final projected = entry.spent + dailyRate * daysRemaining;
    final remaining = entry.remaining.clamp(0.0, budget.amount);

    String fmt(double v) => v.toStringAsFixed(0);

    final String title;
    final String body;
    if (bucket == 3) {
      title = 'تجاوزت $categoryLabel';
      body =
          'صرفت ${fmt(entry.spent - budget.amount)} $currencyLabel زيادة عن الميزانية.';
    } else if (bucket == 2) {
      title = '$categoryLabel على وشك الاكتمال';
      body = 'بقيلك ${fmt(remaining)} $currencyLabel فقط — '
          'معدلك الحالي سيستهلكها في $daysRemaining يوم.';
    } else {
      title = 'وصلت ٧٥٪ من $categoryLabel';
      body = projected > budget.amount
          ? 'بقيلك ${fmt(remaining)} $currencyLabel. '
              'إذا استمر معدلك قد تتجاوز الميزانية بـ${fmt(projected - budget.amount)} $currencyLabel.'
          : 'بقيلك ${fmt(remaining)} $currencyLabel حتى نهاية الفترة.';
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
