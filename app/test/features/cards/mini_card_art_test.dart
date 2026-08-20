import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/engine/parser/card_network.dart';
import 'package:money_companion/features/cards/card_theme.dart';
import 'package:money_companion/features/cards/mini_card_art.dart';
import 'package:money_companion/core/utils/app_lucide_icons.dart';

void main() {
  Widget harness(Widget child) => MaterialApp(
        theme: AppTheme.light,
        home: Scaffold(
          body: Directionality(
            textDirection: TextDirection.rtl,
            child: Center(child: child),
          ),
        ),
      );

  testWidgets('renders every network badge variant', (tester) async {
    for (final (network, probe) in [
      (CardNetwork.visa, find.text('VISA')),
      (CardNetwork.mada, find.text('مدى')),
      (CardNetwork.amex, find.text('AMEX')),
      (CardNetwork.unknown, find.byIcon(AppLucideIcons.creditCard)),
    ]) {
      await tester.pumpWidget(harness(MiniCardArt(network: network)));
      expect(probe, findsOneWidget, reason: '$network badge missing');
    }
    // Mastercard is drawn as two overlapping circles — no text, no icon.
    await tester.pumpWidget(
        harness(const MiniCardArt(network: CardNetwork.mastercard)));
    expect(find.text('VISA'), findsNothing);
    expect(find.byIcon(AppLucideIcons.creditCard), findsNothing);
  });

  testWidgets('uses the real card ratio and the theme gradient',
      (tester) async {
    await tester.pumpWidget(harness(
        const MiniCardArt(network: CardNetwork.visa, themeKey: 'navy')));
    final size = tester.getSize(find.byType(MiniCardArt));
    expect(size.width, 54);
    expect(size.height, moreOrLessEquals(54 / 1.586, epsilon: 0.01));

    final container = tester.widget<Container>(find
        .descendant(
            of: find.byType(MiniCardArt), matching: find.byType(Container))
        .first);
    final gradient =
        (container.decoration! as BoxDecoration).gradient! as LinearGradient;
    expect(gradient.colors, cardThemeByKey('navy')!.colors);
  });

  testWidgets('no theme key falls back to the default brand gradient',
      (tester) async {
    await tester.pumpWidget(harness(const MiniCardArt()));
    final context = tester.element(find.byType(MiniCardArt));
    final container = tester.widget<Container>(find
        .descendant(
            of: find.byType(MiniCardArt), matching: find.byType(Container))
        .first);
    final gradient =
        (container.decoration! as BoxDecoration).gradient! as LinearGradient;
    expect(gradient.colors, (cardGradient(context) as LinearGradient).colors);
  });
}
