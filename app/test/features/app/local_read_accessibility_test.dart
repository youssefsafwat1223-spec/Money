import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/auth/auth_diagnostics.dart';
import 'package:money_companion/core/di/local_read_providers.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/features/app/local_read_shell.dart';
import 'package:money_companion/l10n/app_localizations.dart';

void main() {
  setUp(AuthDiagnostics.debugReset);
  tearDown(AuthDiagnostics.debugReset);

  for (final language in ['ar', 'en']) {
    for (final dark in [false, true]) {
      for (final state in ['populated', 'empty', 'error', 'loading']) {
        testWidgets('compact local-read $state scrolls at 2x text in $language dark=$dark', (tester) async {
          tester.view.physicalSize = const Size(375, 667);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          for (var index = 0; index < 8; index++) {
            // Public diagnostic sink only: no refresh, grant or session change.
            AuthDiagnostics.add('coldRecovery retryable:deadline '
                'open=1 mark=2 send=3 reply=- end=10000 http=-');
          }
          final name = language == 'ar'
              ? 'حساب الادخار الخاص بالأسرة والأهداف المستقبلية'
              : 'Family savings account for future plans and emergencies';
          final merchant = language == 'ar'
              ? 'متجر مشتريات المنزل والأجهزة الكهربائية'
              : 'Household shopping and electrical appliances store';
          final pending = Completer<LocalReadSnapshot>();
          addTearDown(() {
            if (!pending.isCompleted) {
              pending.complete(const LocalReadSnapshot([], []));
            }
          });
          var reconnects = 0;
          var logouts = 0;
          await tester.pumpWidget(ProviderScope(overrides: [
            localReadSnapshotProvider.overrideWith((ref) async {
              if (state == 'loading') return pending.future;
              if (state == 'error') throw StateError('synthetic read failure');
              if (state == 'empty') return const LocalReadSnapshot([], []);
              return LocalReadSnapshot([
                LocalReadAccountRow(name, 'EGP', '1250.00'),
              ], [
                LocalReadTransactionRow(id: 'synthetic-accessibility-tx',
                    title: merchant, amount: '59.95', currency: 'EGP',
                    isDebit: true, occurredAt: '2026-10-17T12:00:00Z'),
              ]);
            }),
          ], child: MaterialApp(
            theme: dark ? AppTheme.dark : AppTheme.light,
            locale: Locale(language),
            supportedLocales: AppL10n.supportedLocales,
            localizationsDelegates: AppL10n.localizationsDelegates,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                  textScaler: const TextScaler.linear(2)),
              child: child!,
            ),
            home: LocalReadShell(
              onReconnect: () => reconnects++,
              onLogout: () async => logouts++,
            ),
          )));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          final l10n = AppL10n.of(tester.element(find.byType(LocalReadShell)));
          final trail = find.byKey(const Key('local_read_auth_trail'));
          expect(tester.widget<SelectableText>(trail).data!.split('\n'),
              hasLength(8));
          final scrollable = find.byType(Scrollable).first;
          Future<void> revealText(Finder finder) async {
            await tester.scrollUntilVisible(finder, 250, scrollable: scrollable);
            await tester.pumpAndSettle();
            final rect = tester.getRect(finder);
            final headerBottom = tester.getBottomRight(find.byType(AppBar)).dy;
            expect(rect.top, greaterThanOrEqualTo(headerBottom));
            expect(rect.bottom, lessThanOrEqualTo(667));
          }
          final reconnect = find.byKey(const Key('local_read_reconnect'));
          await tester.scrollUntilVisible(reconnect, 250, scrollable: scrollable);
          await tester.pumpAndSettle();
          expect(reconnect.hitTestable(), findsOneWidget);
          await tester.tap(reconnect);
          await tester.pumpAndSettle();
          expect(reconnects, 1);
          if (state == 'populated') {
            await revealText(find.text(name));
            await revealText(find.text('1250.00 EGP'));
            await revealText(find.text(merchant));
            await revealText(find.text('-59.95 EGP'));
          } else if (state == 'empty') {
            await revealText(find.text(l10n.localReadNoTransactions));
            expect(find.text(l10n.localReadNoAccounts), findsOneWidget);
          } else if (state == 'error') {
            await revealText(find.text(l10n.localReadLoadError));
          } else {
            expect(find.text(l10n.localReadLoadError), findsNothing);
            expect(find.text(l10n.localReadNoTransactions), findsNothing);
          }
          await tester.tap(find.byKey(const Key('local_read_logout')));
          await tester.pumpAndSettle();
          expect(logouts, 1);
          expect(find.byType(LocalReadShell), findsOneWidget,
              reason: 'injected UI callbacks do not change session authority');
          expect(tester.takeException(), isNull);
        });
      }
    }
  }
}
