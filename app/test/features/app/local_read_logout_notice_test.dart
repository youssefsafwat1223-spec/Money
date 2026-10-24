import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/di/local_read_providers.dart';
import 'package:money_companion/core/session/app_session.dart';
import 'package:money_companion/features/app/local_read_shell.dart';
import 'package:money_companion/l10n/app_localizations.dart';
import 'package:money_companion/l10n/app_localizations_ar.dart';
import 'package:money_companion/l10n/app_localizations_en.dart';

// O-H3 item 2 — the honest message for an incomplete logout, over the real
// LocalReadShell: the outcome comes from the session's typed result; Retry
// re-runs only the durable deny.

Future<void> _pump(
  WidgetTester tester, {
  required Future<SignOutOutcome> Function() signOut,
  required Future<bool> Function() retry,
  Locale locale = const Locale('en'),
}) async {
  await tester.pumpWidget(ProviderScope(
    overrides: [
      localReadSnapshotProvider.overrideWith(
          (ref) async => const LocalReadSnapshot([], [])),
    ],
    child: MaterialApp(
      locale: locale,
      supportedLocales: AppL10n.supportedLocales,
      localizationsDelegates: const [
        AppL10n.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: LocalReadShell(signOutAction: signOut, retryDeny: retry),
    ),
  ));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('an incomplete logout shows the honest message (EN)',
      (tester) async {
    await _pump(tester,
        signOut: () async => SignOutOutcome.durableDenyIncomplete,
        retry: () async => false);
    await tester.tap(find.byKey(const Key('local_read_logout')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('sign_out_incomplete_notice')), findsOneWidget);
    expect(find.text(AppL10nEn().signOutCleanupIncompleteMessage),
        findsOneWidget);
    // R10.3: a restart is named only as a risk, never as the fix.
    expect(AppL10nEn().signOutCleanupIncompleteMessage,
        isNot(contains('Restart the app')));
    expect(AppL10nEn().signOutCleanupIncompleteMessage, contains('Try again'));
  });

  testWidgets('the same message in Arabic', (tester) async {
    await _pump(tester,
        signOut: () async => SignOutOutcome.durableDenyIncomplete,
        retry: () async => false,
        locale: const Locale('ar'));
    await tester.tap(find.byKey(const Key('local_read_logout')));
    await tester.pumpAndSettle();
    expect(find.text(AppL10nAr().signOutCleanupIncompleteMessage),
        findsOneWidget);
  });

  testWidgets('a complete logout shows no message', (tester) async {
    await _pump(tester,
        signOut: () async => SignOutOutcome.complete, retry: () async => true);
    await tester.tap(find.byKey(const Key('local_read_logout')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('sign_out_incomplete_notice')), findsNothing);
  });

  testWidgets('Retry that fails keeps the honest message', (tester) async {
    var retries = 0;
    await _pump(tester,
        signOut: () async => SignOutOutcome.durableDenyIncomplete,
        retry: () async {
          retries++;
          return false;
        });
    await tester.tap(find.byKey(const Key('local_read_logout')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('sign_out_incomplete_retry')));
    await tester.pumpAndSettle();
    expect(retries, 1);
    expect(find.byKey(const Key('sign_out_incomplete_notice')), findsOneWidget);
    expect(find.text(AppL10nEn().signOutCleanupStillIncomplete),
        findsOneWidget);
  });

  testWidgets('Retry that succeeds closes the message', (tester) async {
    var retries = 0;
    await _pump(tester,
        signOut: () async => SignOutOutcome.durableDenyIncomplete,
        retry: () async {
          retries++;
          return true;
        });
    await tester.tap(find.byKey(const Key('local_read_logout')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('sign_out_incomplete_retry')));
    await tester.pumpAndSettle();
    expect(retries, 1);
    expect(find.byKey(const Key('sign_out_incomplete_notice')), findsNothing);
  });
}
