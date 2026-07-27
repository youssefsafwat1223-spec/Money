import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/theme/mali_tokens.dart';
import 'package:money_companion/core/theme/widgets/mali_card.dart';

void main() {
  Future<void> pumpCard(WidgetTester tester, MaliSurfaceStyle style) {
    return tester.pumpWidget(
      MaterialApp(
        home: MaliCard(style: style, child: const Text('content')),
      ),
    );
  }

  testWidgets('floating style applies a shadow', (tester) async {
    await pumpCard(tester, MaliSurfaceStyle.floating);
    final box = tester.widget<DecoratedBox>(find.byType(DecoratedBox));
    final decoration = box.decoration as BoxDecoration;
    expect(decoration.color, MaliTokens.light.surfaceFloating);
    expect(decoration.boxShadow, isNotEmpty);
  });

  testWidgets('raised style has no shadow (quieter than floating)',
      (tester) async {
    await pumpCard(tester, MaliSurfaceStyle.raised);
    final box = tester.widget<DecoratedBox>(find.byType(DecoratedBox));
    final decoration = box.decoration as BoxDecoration;
    expect(decoration.color, MaliTokens.light.surfaceRaised);
    expect(decoration.boxShadow, isNull);
  });

  testWidgets('glass style has a stroke border', (tester) async {
    await pumpCard(tester, MaliSurfaceStyle.glass);
    final box = tester.widget<DecoratedBox>(find.byType(DecoratedBox));
    final decoration = box.decoration as BoxDecoration;
    expect(decoration.border, isNotNull);
  });

  testWidgets('accent style uses the restrained gradient + glow',
      (tester) async {
    await pumpCard(tester, MaliSurfaceStyle.accent);
    final box = tester.widget<DecoratedBox>(find.byType(DecoratedBox));
    final decoration = box.decoration as BoxDecoration;
    expect(decoration.gradient, MaliTokens.accentGradient);
    expect(decoration.boxShadow, isNotEmpty);
  });

  testWidgets('all styles render their child', (tester) async {
    for (final style in MaliSurfaceStyle.values) {
      await pumpCard(tester, style);
      expect(find.text('content'), findsOneWidget);
    }
  });

  testWidgets('onTap makes the card tappable while keeping the shadow',
      (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: MaliCard(onTap: () => taps++, child: const Text('content')),
      ),
    );
    // The drop shadow lives on the DecoratedBox and must survive (not be
    // clipped away by the ink layer).
    final box = tester.widget<DecoratedBox>(find.byType(DecoratedBox));
    expect((box.decoration as BoxDecoration).boxShadow, isNotEmpty);
    // The ink/ripple layer is clipped to the rounded corners.
    expect(find.byType(ClipRRect), findsOneWidget);
    expect(find.byType(InkWell), findsOneWidget);
    await tester.tap(find.text('content'));
    expect(taps, 1);
  });

  testWidgets('a non-tappable card adds no InkWell or clip', (tester) async {
    await pumpCard(tester, MaliSurfaceStyle.floating);
    expect(find.byType(InkWell), findsNothing);
    expect(find.byType(ClipRRect), findsNothing);
  });
}
