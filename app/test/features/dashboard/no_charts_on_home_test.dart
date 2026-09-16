import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Architecture contract for the Home/Reports split.
///
/// **Amended by the dashboard redesign — read this before "fixing" a failure.**
/// The original rule was "no bars/donuts/lines on Home at all". That was
/// superseded on purpose: Home's «المصروفات اليومية» card renders seven fixed
/// day slots (`lib/features/dashboard/widgets/daily_spend_card.dart`).
///
/// What the contract actually protects is not "no rectangle may be drawn" — it
/// is **ownership of the analytics layer**:
///   * Reports owns `fl_chart` and the shared `spending_charts` widgets, and
///     every interactive chart (axes, legends, tooltips, gestures, drill-down).
///   * Home may render a bespoke, non-interactive, fixed-slot visual whose only
///     job is to give ONE number its context — no axis, no legend, no tooltip.
///
/// The assertion is therefore unchanged in mechanism (Home must not *depend on*
/// the chart package or the shared chart widgets); only its rationale moved.
/// A full widget-pump of DashboardScreen is impractical (its provider aggregates
/// ~a dozen repositories), so this asserts the STRUCTURE (the file's `import`
/// directives) rather than symbol spelling in the body: robust to
/// renames/comments/formatting, and it still catches the real regression — a
/// Reports chart being wired back into Home.
List<String> _imports(String path) {
  final directive = RegExp(r'''^\s*import\s+['"]([^'"]+)['"]''', multiLine: true);
  return directive
      .allMatches(File(path).readAsStringSync())
      .map((m) => m.group(1)!)
      .toList(growable: false);
}

bool _dependsOnCharts(List<String> imports) => imports.any((i) =>
    i.contains('fl_chart') ||
    i.contains('spending_charts') ||
    i.contains('/charts/') ||
    i.endsWith('_chart.dart'));

void main() {
  test('Home (dashboard_screen.dart) imports no chart package or chart widget',
      () {
    final imports = _imports('lib/features/dashboard/dashboard_screen.dart');
    expect(_dependsOnCharts(imports), isFalse,
        reason: 'analytics charts belong in Reports, not Home — '
            'offending imports: ${imports.where((i) => i.contains('chart'))}');
  });

  test('Reports (reports_screen.dart) still depends on the chart widgets '
      '(moved, not deleted)', () {
    final imports = _imports('lib/features/reports/reports_screen.dart');
    expect(_dependsOnCharts(imports), isTrue,
        reason: 'the chart widgets must still be rendered somewhere — Reports');
  });
}
