import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/di/local_read_providers.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/features/app/local_read_shell.dart';
import 'package:money_companion/l10n/app_localizations.dart';

void main() {
  for (final language in ['ar', 'en']) {
    for (final dark in [false, true]) {
      testWidgets('recovery prompt at 2x text: $language dark=$dark',
          (tester) async {
        tester.view.physicalSize = const Size(375, 667);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        var signIns = 0;
        var logouts = 0;
        await tester.pumpWidget(ProviderScope(
          overrides: [
            localReadSnapshotProvider.overrideWith((_) async {
              fail(
                  'the recovery presentation must not mount financial providers');
            })
          ],
          child: MaterialApp(
            theme: dark ? AppTheme.dark : AppTheme.light,
            locale: Locale(language),
            supportedLocales: AppL10n.supportedLocales,
            localizationsDelegates: AppL10n.localizationsDelegates,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: const TextScaler.linear(2)),
              child: child!,
            ),
            home: LocalReadShell(
              onReconnect: () => signIns++,
              onLogout: () async => logouts++,
            ),
          ),
        ));
        await tester.pumpAndSettle();
        final l10n = AppL10n.of(tester.element(find.byType(LocalReadShell)));
        expect(find.text(l10n.sessionRecoveryTitle), findsOneWidget);
        expect(find.text(l10n.localReadBannerTitle), findsNothing);
        expect(find.text(l10n.localReadReconnect), findsNothing);
        for (final key in ['local_read_reconnect', 'local_read_logout']) {
          final action = find.byKey(Key(key));
          await tester.ensureVisible(action);
          await tester.pumpAndSettle();
          expect(action.hitTestable(), findsOneWidget);
          await tester.tap(action);
          await tester.pumpAndSettle();
        }
        expect(signIns, 1);
        expect(logouts, 1);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
