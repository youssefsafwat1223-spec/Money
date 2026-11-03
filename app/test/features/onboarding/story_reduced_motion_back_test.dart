import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/features/onboarding/story_screen.dart';
import 'package:money_companion/l10n/app_localizations.dart';

void main() {
  for (final lang in ['ar', 'en']) {
    for (final dark in [false, true]) {
      testWidgets('reduced motion moves both directions immediately $lang dark$dark', (tester) async {
        tester.view.physicalSize = const Size(375, 667);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(MaterialApp(
          theme: dark ? AppTheme.dark : AppTheme.light,
          locale: Locale(lang), supportedLocales: AppL10n.supportedLocales,
          localizationsDelegates: AppL10n.localizationsDelegates,
          builder: (context, child) => MediaQuery(data: MediaQuery.of(context).copyWith(disableAnimations: true), child: child!),
          home: const OnboardingStoryScreen(),
        ));
        await tester.pumpAndSettle();
        final l = AppL10n.of(tester.element(find.byType(OnboardingStoryScreen)));
        final page = tester.widget<PageView>(find.byType(PageView)).controller!;
        await tester.tap(find.text(l.storyContinueCta));
        await tester.pump();
        await tester.pump();
        expect(page.page, 1);
        await tester.tap(find.byIcon(Icons.arrow_back_ios_new));
        await tester.pump();
        final immediatelyAfterBack = page.page;
        await tester.pumpAndSettle();
        expect(page.page, 0);
        expect(tester.takeException(), isNull);
        expect(immediatelyAfterBack, 0, reason: 'Reduced motion must not animate the return direction');
      });
    }
  }
}
