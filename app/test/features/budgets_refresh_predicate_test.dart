import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Pins the /budgets pull-to-refresh fix to the product file. The mechanism is
/// proven in test/harness/nested_refresh_repro_test.dart; this guards against
/// the predicate being dropped in a refactor, which would silently restore a
/// RefreshIndicator that can never fire.
void main() {
  test('/budgets RefreshIndicator over NestedScrollView keeps its predicate', () {
    final src = File('lib/features/budgets/budgets_screen.dart').readAsStringSync();
    final at = src.indexOf('RefreshIndicator(');
    expect(at, isNonNegative);
    final block = src.substring(at, src.indexOf('NestedScrollView(', at));
    expect(block.contains('notificationPredicate: (n) => n.depth == 1'), isTrue,
        reason: 'under NestedScrollView the pull notifications arrive at '
            'depth 1; without this the indicator can never start');
  });
}
