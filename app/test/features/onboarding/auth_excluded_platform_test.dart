import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/features/onboarding/auth_screen.dart';
import 'package:money_companion/l10n/app_localizations.dart';

void main() {
  for (final platform in TargetPlatform.values.where(
    (platform) => platform != TargetPlatform.iOS,
  )) {
    for (final language in ['ar', 'en']) {
      for (final dark in [false, true]) {
        testWidgets('Apple is hidden on $platform in $language, dark=$dark',
            (tester) async {
          tester.view.physicalSize = const Size(375, 667);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);

          await tester.pumpWidget(ProviderScope(
            child: MaterialApp(
              theme: dark ? AppTheme.dark : AppTheme.light,
              locale: Locale(language),
              supportedLocales: AppL10n.supportedLocales,
              localizationsDelegates: AppL10n.localizationsDelegates,
              home: const OnboardingAuthScreen(),
            ),
          ));
          await tester.pumpAndSettle();

          final context = tester.element(find.byType(OnboardingAuthScreen));
          final l10n = AppL10n.of(context);
          expect(find.text(l10n.authAppleCta), findsNothing);
          expect(find.byIcon(Icons.apple), findsNothing);
          expect(find.byType(FilledButton), findsNothing);
          expect(find.text(l10n.authSubtitle), findsOneWidget);
          expect(find.text(l10n.authTrustLocalEncryption), findsOneWidget);
          expect(find.text(l10n.authTermsNotice), findsOneWidget);
          expect(find.byKey(const ValueKey('onboarding-language')).hitTestable(),
              findsOneWidget);
          expect(tester.takeException(), isNull);
        }, variant: TargetPlatformVariant({platform}));
      }
    }
  }
}
