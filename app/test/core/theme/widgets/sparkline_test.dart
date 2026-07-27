import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/theme/widgets/sparkline.dart';

void main() {
  Future<void> pumpValues(WidgetTester tester, List<double> values) {
    return tester.pumpWidget(
      MaterialApp(
        home: SizedBox(width: 100, child: Sparkline(values: values)),
      ),
    );
  }

  testWidgets('renders normal trend data without throwing', (tester) async {
    await pumpValues(tester, [1, 5, 3, 8, 2, 9]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('empty data does not throw', (tester) async {
    await pumpValues(tester, const []);
    expect(tester.takeException(), isNull);
  });

  testWidgets('single point does not throw', (tester) async {
    await pumpValues(tester, const [5]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('flat (all-equal) data does not divide by zero', (tester) async {
    await pumpValues(tester, const [4, 4, 4, 4]);
    expect(tester.takeException(), isNull);
  });
}
