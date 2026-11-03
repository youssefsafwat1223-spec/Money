import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/features/onboarding/setup_screen.dart';
import 'package:money_companion/l10n/app_localizations.dart';

// Keep the original country-selector contrast regression while allowing the
// approved neutral surface. Measure actual copy over the composited fill in
// both themes, instead of asserting a navy-specific opacity.
void main() {
  for (final dark in [false, true]) {
    for (final language in ['ar', 'en']) {
      for (final size in [const Size(320, 568), const Size(390, 844)]) {
      testWidgets('country labels remain readable: $language, dark=$dark, width=${size.width}',
          (tester) async {
        await tester.binding.setSurfaceSize(size);
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(ProviderScope(child: MaterialApp(
          theme: dark ? AppTheme.dark : AppTheme.light,
          locale: Locale(language),
          supportedLocales: AppL10n.supportedLocales,
          localizationsDelegates: const [
            ...AppL10n.localizationsDelegates,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          home: const OnboardingSetupScreen(),
        )));
        await tester.pumpAndSettle();
        expect(find.byType(ChoiceChip), findsNothing);
        final pills = find.byWidgetPredicate(
            (widget) => widget.runtimeType.toString() == '_CountryPill');
        expect(pills, findsNWidgets(8));
        final background = tester.widget<Scaffold>(find.byType(Scaffold)).backgroundColor!;
        for (var index = 0; index < 8; index++) {
          final pill = pills.at(index);
          for (final material in tester.widgetList<Material>(find.descendant(
              of: pill, matching: find.byType(Material)))) {
            expect(material.type, MaterialType.transparency,
                reason: 'ambient Material must not override the explicit pill surface');
          }
          final ink = tester.widget<Ink>(find.descendant(of: pill, matching: find.byType(Ink)));
          final fill = (ink.decoration! as ShapeDecoration).color!;
          final text = tester.widget<Text>(find.descendant(of: pill, matching: find.byType(Text)));
          final surface = Color.alphaBlend(fill, background);
          final copy = Color.alphaBlend(text.style!.color!, surface);
          final a = surface.computeLuminance();
          final b = copy.computeLuminance();
          final ratio = a > b ? (a + .05) / (b + .05) : (b + .05) / (a + .05);
          expect(ratio, greaterThanOrEqualTo(4.5),
              reason: 'country $index must have AA contrast in $language, dark=$dark');
        }
        expect(tester.takeException(), isNull);
      });
      }
    }
  }
}
