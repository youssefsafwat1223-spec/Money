import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Why /budgets' pull-to-refresh could never fire.
///
/// The exhaustive control sweep reported the /budgets RefreshIndicator as
/// "callback never started" on a physical iPhone. /budgets is
/// RefreshIndicator > SafeArea > NestedScrollView(headerSlivers, body: ListView).
///
/// A first hypothesis — content shorter than the viewport, so no overscroll —
/// was disproved locally: a short CustomScrollView refreshes fine. Measuring
/// the notifications that actually reach the indicator showed the real cause:
/// under NestedScrollView the ScrollUpdateNotifications that accumulate the
/// pull distance are emitted by the INNER scrollable at depth 1 (20 updates at
/// depth 1, none at depth 0), while RefreshIndicator's default predicate
/// accepts only depth 0. It armed on the start notification and never saw a
/// single update.
///
/// This models the exact structure and pins both halves: the defect with the
/// default predicate, and the fix with depth == 1.
void main() {
  Widget host(
    void Function() onRefresh, {
    bool Function(ScrollNotification)? predicate,
  }) =>
      MaterialApp(
        home: Scaffold(
          body: RefreshIndicator(
            onRefresh: () async => onRefresh(),
            notificationPredicate:
                predicate ?? defaultScrollNotificationPredicate,
            child: SafeArea(
              top: false,
              bottom: false,
              child: NestedScrollView(
                headerSliverBuilder: (context, inner) => const [
                  SliverToBoxAdapter(
                    child: SizedBox(height: 140, child: Text('header')),
                  ),
                ],
                body: ListView(
                  children: const [
                    SizedBox(height: 80, child: Text('budget one')),
                    SizedBox(height: 80, child: Text('budget two')),
                  ],
                ),
              ),
            ),
          ),
        ),
      );

  /// Pulls down and reports whether the refresh actually started.
  Future<bool> pull(WidgetTester tester, Finder from) async {
    await tester.drag(from, const Offset(0, 250));
    await tester.pump();
    final started = find.byType(RefreshProgressIndicator).evaluate().isNotEmpty;
    await tester.pumpAndSettle();
    return started;
  }

  for (final platform in [TargetPlatform.iOS, TargetPlatform.android]) {
    testWidgets('$platform: default predicate never starts (the defect)',
        (tester) async {
      debugDefaultTargetPlatformOverride = platform;
      var refreshed = 0;
      await tester.pumpWidget(host(() => refreshed++));

      final body = await pull(tester, find.text('budget one'));
      final header = await pull(tester, find.text('header'));

      // Cleared inside the body: addTearDown runs after the framework's
      // debug-variable invariant check and fails the test.
      debugDefaultTargetPlatformOverride = null;

      expect(body, isFalse);
      expect(header, isFalse);
      expect(refreshed, 0,
          reason: 'a depth-0 predicate sees no ScrollUpdateNotification under '
              'NestedScrollView, so the pull never accumulates');
    });

    testWidgets('$platform: depth-1 predicate refreshes from the body (fix)',
        (tester) async {
      debugDefaultTargetPlatformOverride = platform;
      var refreshed = 0;
      await tester
          .pumpWidget(host(() => refreshed++, predicate: (n) => n.depth == 1));

      final started = await pull(tester, find.text('budget one'));
      debugDefaultTargetPlatformOverride = null;

      expect(started, isTrue,
          reason: 'depth 1 is where the update notifications are emitted');
      expect(refreshed, 1);
    });
  }
}
