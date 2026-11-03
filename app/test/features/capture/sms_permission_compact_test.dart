import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/features/capture/sms_permission_screen.dart';
import 'package:money_companion/l10n/app_localizations.dart';

void main() {
  for (final language in ['ar', 'en']) {
    for (final theme in [AppTheme.light, AppTheme.dark]) {
      testWidgets('capture actions fit 375x667 in $language ${theme.brightness.name}', (tester) async {
        tester.view.physicalSize = const Size(375, 667);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(MaterialApp(
          theme: theme, locale: Locale(language),
          supportedLocales: AppL10n.supportedLocales,
          localizationsDelegates: AppL10n.localizationsDelegates,
          home: Builder(builder: (context) => Scaffold(body: TextButton(
            onPressed: () => SmsPermissionScreen.showSheet(context),
            child: const Text('Open')))),
        ));
        await tester.tap(find.text('Open'));
        await tester.pumpAndSettle();
        final context = tester.element(find.byType(SmsPermissionScreen));
        final l10n = AppL10n.of(context);
        expect(find.text(l10n.smsPasteManually).hitTestable(), findsOneWidget);
        expect(find.text(l10n.smsPasteLater).hitTestable(), findsOneWidget);
        await tester.drag(find.byType(SingleChildScrollView), const Offset(0, -400));
        await tester.pumpAndSettle();
        expect(find.text(l10n.smsShareFallback), findsOneWidget);
        expect(find.text(l10n.smsPasteManually).hitTestable(), findsOneWidget);
        await tester.tap(find.text(l10n.smsPasteLater));
        await tester.pumpAndSettle();
        expect(find.byType(SmsPermissionScreen), findsNothing);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
