import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'dart:io';

import 'package:go_router/go_router.dart';

/// Regression for the unguarded pop in RestorePromptScreen._startFresh.
///
/// Found by the exhaustive control sweep: entering /backup/restore as the root
/// of the stack and tapping "start fresh" threw
/// `GoError: There is nothing to pop`, leaving the user on a screen whose
/// dismiss button is dead. In-app entries use push(), so a real user normally
/// has something to pop — this covers the root case (deep link, go(), restored
/// route) that has no such guarantee.
///
/// The navigation contract is modelled rather than the whole screen, so the
/// test stays fast and pins the branch that was wrong.
void main() {
  Widget harness(GoRouter router) => MaterialApp.router(routerConfig: router);

  /// The fixed contract from restore_prompt_screen.dart:_startFresh.
  void startFresh(BuildContext context) =>
      context.canPop() ? context.pop() : context.go('/data-transfer');

  testWidgets('pushed restore screen: start fresh pops back', (tester) async {
    final router = GoRouter(initialLocation: '/data-transfer', routes: [
      GoRoute(
        path: '/data-transfer',
        builder: (c, s) => Scaffold(
          body: TextButton(
            onPressed: () => c.push('/backup/restore'),
            child: const Text('open'),
          ),
        ),
      ),
      GoRoute(
        path: '/backup/restore',
        builder: (c, s) => Scaffold(
          body: TextButton(
            onPressed: () => startFresh(c),
            child: const Text('start fresh'),
          ),
        ),
      ),
    ]);
    await tester.pumpWidget(harness(router));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('start fresh'), findsOneWidget);

    await tester.tap(find.text('start fresh'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('open'), findsOneWidget,
        reason: 'pushed screen must return to where it came from');
  });

  testWidgets('root restore screen: no GoError, lands on data transfer',
      (tester) async {
    final router = GoRouter(initialLocation: '/backup/restore', routes: [
      GoRoute(
        path: '/data-transfer',
        builder: (c, s) => const Scaffold(body: Text('data transfer')),
      ),
      GoRoute(
        path: '/backup/restore',
        builder: (c, s) => Scaffold(
          body: TextButton(
            onPressed: () => startFresh(c),
            child: const Text('start fresh'),
          ),
        ),
      ),
    ]);
    await tester.pumpWidget(harness(router));
    expect(find.text('start fresh'), findsOneWidget);

    await tester.tap(find.text('start fresh'));
    await tester.pumpAndSettle();
    // The defect: this threw GoError instead of navigating.
    expect(tester.takeException(), isNull,
        reason: 'an unguarded pop threw when nothing was on the stack');
    expect(find.text('data transfer'), findsOneWidget,
        reason: 'must fall back to the route this screen is reached from');
  });

  test('onboardingFlow branch still returns before the canPop guard', () {
    final src = File('lib/features/onboarding/restore_prompt_screen.dart')
        .readAsStringSync();
    final body = src.substring(src.indexOf('void _startFresh()'));
    final onboarding = body.indexOf('widget.onboardingFlow');
    final guard = body.indexOf('context.canPop()');
    expect(onboarding, isNonNegative);
    expect(guard, isNonNegative);
    expect(onboarding < guard, isTrue,
        reason: 'onboarding must return before the non-onboarding fallback, '
            'or the fix would change onboarding navigation');
  });
}
