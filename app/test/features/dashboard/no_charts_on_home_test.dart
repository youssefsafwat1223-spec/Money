import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Regression guard for the Home/Reports split: Home must never import the
/// chart package or the chart widgets directly — all visual analytics
/// (donut/bar/line charts) belong only in Reports. A widget-level pump of
/// the full DashboardScreen would need a large fake-provider harness
/// (dashboardDataProvider alone aggregates a dozen repositories); this
/// static check catches the regression this task cared about — a chart
/// being re-added to Home — far more cheaply, and reliably.
void main() {
  test(
      'dashboard_screen.dart does not import fl_chart or the shared chart '
      'widgets', () {
    final source =
        File('lib/features/dashboard/dashboard_screen.dart').readAsStringSync();

    expect(source.contains('fl_chart'), isFalse);
    expect(source.contains('spending_charts.dart'), isFalse);
    expect(source.contains('CategoryDonutChart'), isFalse);
    expect(source.contains('WeeklyCapsuleBarChart'), isFalse);
    expect(source.contains('DailySpendBarChart'), isFalse);
    expect(source.contains('CompactSparkline'), isFalse);
    expect(source.contains('PieChart('), isFalse);
    expect(source.contains('BarChart('), isFalse);
    expect(source.contains('LineChart('), isFalse);
  });

  test(
      'reports_screen.dart still renders the chart widgets (not '
      'duplicated-away, just moved)', () {
    final source =
        File('lib/features/reports/reports_screen.dart').readAsStringSync();

    expect(source.contains('CategoryDonutChart'), isTrue);
    expect(source.contains('WeeklyCapsuleBarChart'), isTrue);
  });
}
