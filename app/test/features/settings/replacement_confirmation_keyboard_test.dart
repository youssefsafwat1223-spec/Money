import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/features/settings/data_transfer_screen.dart';
import 'package:money_companion/l10n/app_localizations.dart';

void main() {
  for (final language in ['ar', 'en']) {
    for (final dark in [false, true]) {
      for (final scale in [1.0, 1.9411764705882353]) {
        testWidgets('replacement remains usable with keyboard $language dark=$dark scale=$scale', (tester) async {
          tester.view.physicalSize = const Size(375, 667);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          for (final family in ['Vazirmatn', 'Alexandria', 'IBMPlexSansArabic']) {
            final loader = FontLoader(family);
            for (final weight in ['Regular', 'Medium', 'SemiBold', 'Bold']) {
              loader.addFont(rootBundle.load('assets/fonts/$family-$weight.ttf'));
            }
            await loader.load();
          }
          bool? outcome;
          late AppL10n l10n;
          await tester.pumpWidget(MaterialApp(
            locale: Locale(language),
            localizationsDelegates: AppL10n.localizationsDelegates,
            supportedLocales: AppL10n.supportedLocales,
            theme: dark ? AppTheme.dark : AppTheme.light,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
            home: Builder(builder: (context) {
              l10n = AppL10n.of(context);
              return Scaffold(body: TextButton(
                onPressed: () async { outcome = await showReplaceConfirmationDialog(context); },
                child: const Text('Open replacement'),
              ));
            }),
          ));
          await tester.tap(find.text('Open replacement'));
          await tester.pumpAndSettle();
          // The actual native small-screen dialog overflowed while the keyboard
          // entered. Keep that constrained viewport for all remaining actions.
          tester.view.viewInsets = const FakeViewPadding(bottom: 310);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          await tester.ensureVisible(find.byType(TextField));
          await tester.pumpAndSettle();
          expect(find.byType(TextField).hitTestable(), findsOneWidget);
          await tester.enterText(find.byType(TextField), l10n.dtxReplace);
          await tester.pump();
          expect(find.text(l10n.commonCancel).hitTestable(), findsOneWidget);
          await tester.tap(find.text(l10n.commonCancel));
          await tester.pumpAndSettle();
          expect(outcome, isFalse);
          expect(find.byType(TextField), findsNothing);
          expect(tester.takeException(), isNull);
        });
      }
    }
  }
}
