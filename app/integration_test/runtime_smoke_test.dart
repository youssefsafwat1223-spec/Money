import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:money_companion/main.dart' as app;

/// ON-DEVICE RUNTIME QA — real iPhone.
///
/// The iOS 26.5 simulator on this machine is not a trustworthy runtime (Apple's
/// own Calendar hits the FRONTBOARD 0x8BADF00D scene-create watchdog there), so
/// journeys run on the physical device and are driven from inside Dart — no
/// macOS Accessibility, no taps on a window server.
///
/// The app boots ONCE. `app.main()` performs real global initialisation
/// (Supabase, Drift, seed, flags); calling it per-test opened the database
/// repeatedly and drift warned about it, so every assertion shares one launch.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Future<void> settle(WidgetTester tester,
      {Duration budget = const Duration(seconds: 40)}) async {
    final deadline = DateTime.now().add(budget);
    while (DateTime.now().isBefore(deadline)) {
      await tester.pump(const Duration(milliseconds: 250));
      if (!tester.binding.hasScheduledFrame) break;
    }
  }

  /// Every visible string, for screen identification and copy inspection.
  List<String> visibleText(WidgetTester tester) => tester
      .widgetList<Text>(find.byType(Text))
      .map((t) => t.data ?? t.textSpan?.toPlainText() ?? '')
      .where((s) => s.trim().isNotEmpty)
      .toList();

  testWidgets('on-device runtime pass', (tester) async {
    app.main();
    await settle(tester);

    // ---- J1: first frame ----
    expect(find.byType(MaterialApp), findsWidgets);
    debugPrint('[QA] J1 first frame OK');

    // ---- J2: no error surface ----
    expect(find.byType(ErrorWidget), findsNothing);
    debugPrint('[QA] J2 no ErrorWidget');

    // ---- J3: identify the surface ----
    final texts = visibleText(tester);
    debugPrint('[QA] J3 screen text (${texts.length}): ${texts.take(25).join(" | ")}');

    // ---- J4: interactive controls ----
    final tappables = find.byWidgetPredicate((w) =>
        w is ElevatedButton ||
        w is TextButton ||
        w is OutlinedButton ||
        w is InkWell ||
        w is GestureDetector);
    debugPrint('[QA] J4 tappables: ${tappables.evaluate().length}');
    expect(tappables, findsWidgets);

    // ---- J5: navigation shell present? ----
    final navBars = find.byType(NavigationBar).evaluate().length +
        find.byType(BottomNavigationBar).evaluate().length;
    debugPrint('[QA] J5 nav bars: $navBars');

    // ---- J6: scrollables (list surfaces) ----
    debugPrint('[QA] J6 scrollables: ${find.byType(Scrollable).evaluate().length}');

    // ---- J7: overflow / layout errors ----
    final err = tester.takeException();
    debugPrint('[QA] J7 layout exception: ${err ?? "none"}');
    expect(err, isNull);

    // ---- J8: exercise the primary reachable control, verify UI responds ----
    if (tappables.evaluate().isNotEmpty) {
      final before = visibleText(tester).join('|');
      await tester.tap(tappables.first, warnIfMissed: false);
      await settle(tester, budget: const Duration(seconds: 12));
      final after = visibleText(tester).join('|');
      debugPrint('[QA] J8 tapped primary control; surface changed: '
          '${before != after}');
      expect(find.byType(ErrorWidget), findsNothing,
          reason: 'tapping the primary control must not produce an error surface');
    }

    debugPrint('[QA] DONE');
  });
}
