import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/theme/app_assets.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/features/onboarding/brand_screen.dart';
import 'package:money_companion/l10n/app_localizations.dart';

void main() {
  for (final language in ['en', 'ar']) {
    for (final theme in [AppTheme.light, AppTheme.dark]) {
      testWidgets('brand controls fit a compact phone in $language ${theme.brightness.name}', (tester) async {
        tester.view.physicalSize = const Size(320, 568);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(MaterialApp(
          theme: theme, locale: Locale(language),
          localizationsDelegates: AppL10n.localizationsDelegates,
          supportedLocales: AppL10n.supportedLocales,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: true),
            child: child!),
          home: const OnboardingBrandScreen(),
        ));
        await tester.pumpAndSettle();
        expect(find.byWidgetPredicate((widget) => widget is Image &&
          widget.image == const AssetImage(AppAssets.qirshLogoFull)), findsOneWidget);
        final context = tester.element(find.byType(OnboardingBrandScreen));
        expect(find.text(AppL10n.of(context).brandContinueCta), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('onboarding-language')));
        await tester.pumpAndSettle();
        expect(find.text('English'), findsWidgets);
        expect(find.text('العربية'), findsWidgets);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
