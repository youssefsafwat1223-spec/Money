import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/theme/widgets/ring_progress.dart';

void main() {
  testWidgets('renders its center child slot', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: RingProgress(
          value: 0.7,
          animate: false,
          child: Text('70%'),
        ),
      ),
    );
    expect(find.text('70%'), findsOneWidget);
    expect(find.byType(CustomPaint), findsWidgets);
  });

  testWidgets('null value renders the indeterminate state without throwing',
      (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: RingProgress(value: null, animate: false, child: Text('—')),
      ),
    );
    expect(tester.takeException(), isNull);
    expect(find.text('—'), findsOneWidget);
  });

  testWidgets('out-of-range values are clamped, not thrown', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Column(
          children: [
            RingProgress(value: -0.4, animate: false),
            RingProgress(value: 1.8, animate: false),
          ],
        ),
      ),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('animates in by default without throwing', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: RingProgress(value: 0.5)),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
