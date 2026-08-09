import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Architecture contract for the Home/Reports split: the Home screen's
/// dependency graph must exclude the chart package and the shared chart widgets
/// — all visual analytics (donut/bar/line) live only in Reports. A full
/// widget-pump of DashboardScreen is impractical (its provider aggregates ~a
/// dozen repositories), so this asserts the STRUCTURE (the file's `import`
/// directives) rather than symbol spelling in the body: it is robust to
/// renames/comments/formatting and catches the real regression — a chart being
/// wired back into Home.
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
