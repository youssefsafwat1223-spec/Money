import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Harness interaction smoke — the WidgetTester behaviours the sweeper relies
/// on, pinned locally so a misuse costs a second rather than a 7-minute device
/// cycle. Every case here corresponds to a defect that actually shipped into a
/// device run: an off-screen control scored DEAD-TAP because warnIfMissed was
/// suppressed, a long-press exercised as a tap, a refresh counted from the drag
/// alone, dropdowns "passed" on opening, and text entry that never landed.
void main() {
  Widget app(Widget child) => MaterialApp(home: Scaffold(body: child));

  testWidgets('off-screen but BUILT control: ensureVisible then tap fires',
      (tester) async {
    var taps = 0;
    await tester.pumpWidget(app(SingleChildScrollView(
      child: Column(children: [
        ...List.generate(40, (i) => SizedBox(height: 80, child: Text('row $i'))),
        ListTile(title: const Text('deep'), onTap: () => taps++),
      ]),
    )));
    final target = find.text('deep');
    expect(target, findsOneWidget, reason: 'a Column builds all children');
    // Without ensureVisible this tap misses; with warnIfMissed suppressed it
    // would then be scored as a dead control — the /settings dead-tap wave.
    await tester.ensureVisible(target);
    await tester.pumpAndSettle();
    await tester.tap(target);
    await tester.pumpAndSettle();
    expect(taps, 1, reason: 'ensureVisible must bring it into hit-test range');
  });

  testWidgets('lazily-built control is ABSENT, not dead — a NOT-REACHED cause',
      (tester) async {
    await tester.pumpWidget(app(ListView(
      children: [
        ...List.generate(40, (i) => SizedBox(height: 80, child: Text('row $i'))),
        ListTile(title: const Text('deep'), onTap: () {}),
      ],
    )));
    // A lazy viewport never builds the tail, so the control is not in the tree.
    // The sweeper must classify this as NOT-REACHED (lazy build) and scroll to
    // reach it — never as a control that exists and does nothing.
    expect(find.text('deep'), findsNothing);
    await tester.scrollUntilVisible(find.text('deep'), 300);
    await tester.pumpAndSettle();
    expect(find.text('deep'), findsOneWidget,
        reason: 'scrolling must materialise it before any verdict');
  });

  testWidgets('a missed tap must be made FATAL, not merely warned about',
      (tester) async {
    var taps = 0;
    await tester.pumpWidget(app(Stack(children: [
      SizedBox(width: 10, height: 10, child: GestureDetector(onTap: () => taps++)),
      Positioned.fill(child: Container(color: Colors.black)),
    ])));
    // DISCOVERY: warnIfMissed:true only PRINTS a warning — the tap still
    // "succeeds" and the control would be scored DEAD-TAP with no failure.
    // The sweeper must therefore opt in to fatal hit-test warnings, or a
    // missed tap is indistinguishable from a control that does nothing.
    WidgetController.hitTestWarningShouldBeFatal = true;
    addTearDown(() => WidgetController.hitTestWarningShouldBeFatal = false);
    await expectLater(
      () => tester.tap(find.byType(GestureDetector).first),
      throwsA(anything),
      reason: 'an obscured control must fail, never degrade to DEAD-TAP',
    );
    expect(taps, 0);
  });

  testWidgets('long press fires onLongPress, not onTap', (tester) async {
    var tapped = 0, held = 0;
    await tester.pumpWidget(app(GestureDetector(
      onTap: () => tapped++,
      onLongPress: () => held++,
      child: const SizedBox(width: 100, height: 100, child: Text('lp')),
    )));
    await tester.longPress(find.text('lp'));
    await tester.pumpAndSettle();
    expect(held, 1, reason: 'a long-press is a distinct user action');
    expect(tapped, 0);
  });

  testWidgets('refresh: callback starts and the indicator settles',
      (tester) async {
    var refreshed = 0;
    await tester.pumpWidget(app(RefreshIndicator(
      onRefresh: () async {
        refreshed++;
        await Future<void>.delayed(const Duration(milliseconds: 50));
      },
      child: ListView(
        children: List.generate(20, (i) => SizedBox(height: 60, child: Text('r$i'))),
      ),
    )));
    await tester.drag(find.byType(ListView), const Offset(0, 250));
    await tester.pump();
    expect(find.byType(RefreshProgressIndicator), findsWidgets,
        reason: 'the drag must actually start the callback');
    await tester.pumpAndSettle();
    expect(refreshed, 1);
    expect(find.byType(RefreshProgressIndicator), findsNothing,
        reason: 'and the surface must return to a stable state');
  });

  testWidgets('dropdown: selecting an item changes the value', (tester) async {
    String? selected = 'a';
    await tester.pumpWidget(app(StatefulBuilder(
      builder: (context, setState) => DropdownButton<String>(
        value: selected,
        items: const [
          DropdownMenuItem(value: 'a', child: Text('A')),
          DropdownMenuItem(value: 'b', child: Text('B')),
        ],
        onChanged: (v) => setState(() => selected = v),
      ),
    )));
    await tester.tap(find.byType(DropdownButton<String>));
    await tester.pumpAndSettle();
    // Opening alone proves nothing — the item must be selected.
    await tester.tap(find.text('B').last);
    await tester.pumpAndSettle();
    expect(selected, 'b', reason: 'selection must reach onChanged');
  });

  testWidgets('text entry lands in the controller', (tester) async {
    final c = TextEditingController();
    await tester.pumpWidget(app(TextField(controller: c)));
    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '42');
    await tester.pumpAndSettle();
    expect(c.text, '42',
        reason: 'entering text without asserting the value is how three '
            'device runs reported a save that never happened');
  });
}
