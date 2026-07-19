import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/features/onboarding/widgets/word_reveal_text.dart';

void main() {
  testWidgets('reduced motion shows the complete Arabic copy immediately',
      (tester) async {
    const copy = 'رحلتك المالية محفوظة';

    await tester.pumpWidget(
      const MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(disableAnimations: true),
          child: Directionality(
            textDirection: TextDirection.rtl,
            child: Center(
              child: WordRevealText(
                copy,
                style: TextStyle(fontSize: 30, height: 1.08),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text(copy), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Arabic copy is revealed as complete words without overflow',
      (tester) async {
    const copy = 'المصروفات الصغيرة تصنع فرقًا كبيرًا';

    await tester.pumpWidget(
      const MaterialApp(
        home: Directionality(
          textDirection: TextDirection.rtl,
          child: SizedBox(
            width: 320,
            child: WordRevealText(
              copy,
              initialDelay: Duration.zero,
              wordInterval: Duration(milliseconds: 20),
              showCursor: false,
              style: TextStyle(fontSize: 30, height: 1.08),
            ),
          ),
        ),
      ),
    );

    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 25));
    }

    expect(find.text(copy), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
