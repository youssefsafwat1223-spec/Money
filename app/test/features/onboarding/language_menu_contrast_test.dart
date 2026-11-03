import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/features/onboarding/widgets/onboarding_language_button.dart';
import 'package:money_companion/l10n/app_localizations.dart';

void main() {
  for (final onDark in [false, true]) {
    for (final language in ['en', 'ar']) {
      for (final theme in [AppTheme.light, AppTheme.dark]) {
        testWidgets('language menu is readable onDark=$onDark $language ${theme.brightness.name}',
            (tester) async {
          tester.view.physicalSize = const Size(320, 568);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          await tester.pumpWidget(MaterialApp(
            theme: theme, locale: Locale(language),
            supportedLocales: AppL10n.supportedLocales,
            localizationsDelegates: AppL10n.localizationsDelegates,
            home: Scaffold(body: SafeArea(child: OnboardingLanguageButton(onDark: onDark))),
          ));
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(const ValueKey('onboarding-language')));
          await tester.pumpAndSettle();
          final items = find.byType(PopupMenuItem<String>);
          expect(items, findsNWidgets(2));
          for (final item in items.evaluate()) {
            final textFinder = find.descendant(of: find.byWidget(item.widget), matching: find.byType(Text));
            final text = tester.widget<Text>(textFinder);
            final surface = tester.widget<Material>(find.ancestor(
              of: textFinder, matching: find.byType(Material)).first);
            final background = Color.alphaBlend(surface.color!, theme.scaffoldBackgroundColor);
            final foreground = Color.alphaBlend(text.style!.color!, background);
            final a = foreground.computeLuminance();
            final b = background.computeLuminance();
            final ratio = ((a > b ? a : b) + .05) / ((a > b ? b : a) + .05);
            expect(ratio, greaterThanOrEqualTo(4.5), reason: '${text.data} menu text contrast');
          }
          expect(tester.takeException(), isNull);
        });
      }
    }
  }
}
