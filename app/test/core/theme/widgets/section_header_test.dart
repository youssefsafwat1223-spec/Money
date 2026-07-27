import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/theme/widgets/section_header.dart';

void main() {
  testWidgets('renders title only when no trailing given', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: SectionHeader(title: 'آخر العمليات')),
    );
    expect(find.text('آخر العمليات'), findsOneWidget);
  });

  testWidgets('renders trailing and fires its tap callback', (tester) async {
    var tapped = false;
    await tester.pumpWidget(
      MaterialApp(
        home: SectionHeader(
          title: 'الميزانية',
          trailing: 'الكل',
          onTrailingTap: () => tapped = true,
        ),
      ),
    );
    expect(find.text('الكل'), findsOneWidget);
    await tester.tap(find.text('الكل'));
    expect(tapped, isTrue);
  });
}
