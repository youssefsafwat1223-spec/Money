import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/session/app_session.dart';
import 'package:money_companion/features/app/local_read_cleanup_notice.dart';
import 'package:money_companion/l10n/app_localizations.dart';
import 'package:money_companion/l10n/app_localizations_ar.dart';
import 'package:money_companion/l10n/app_localizations_en.dart';

// Astra D4 — the ROOT-level notice for a remove-data that finished with the
// durable deny unfinished. It lives above the router (like RemovalNoticeHost), so
// the screen that started the removal being disposed cannot lose it.

Widget _app(String locale,
        {required Widget Function() home,
        Future<bool> Function()? retry}) =>
    MaterialApp(
      locale: Locale(locale),
      supportedLocales: AppL10n.supportedLocales,
      localizationsDelegates: const [
        ...AppL10n.localizationsDelegates,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      builder: (context, child) =>
          Stack(children: [child!, DenyIncompleteNoticeHost(retry: retry)]),
      home: Scaffold(body: home()),
    );

void main() {
  final pending = AppSession.instance.denyIncompleteNoticePending;
  setUp(() => pending.value = false);
  tearDown(() => pending.value = false);

  testWidgets('shown after the initiating widget was disposed (EN), distinct '
      'from the data-removed notice', (tester) async {
    final show = ValueNotifier<bool>(true);
    await tester.pumpWidget(_app('en',
        home: () => ValueListenableBuilder<bool>(
            valueListenable: show,
            builder: (_, v, __) =>
                v ? const Text('initiating screen') : const SizedBox())));
    expect(find.text('initiating screen'), findsOneWidget);
    // The scope swap disposes the screen, THEN the removal reports.
    show.value = false;
    await tester.pump();
    pending.value = true;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const Key('deny_incomplete_notice')), findsOneWidget);
    expect(find.text(AppL10nEn().removeDataDenyIncompleteMessage),
        findsOneWidget);
    expect(find.text(AppL10nEn().setDataRemovedNotice), findsNothing,
        reason: 'it does not claim that everything was completed');
    // R10.3: neutral denial-incomplete copy. It claims no removal and does not
    // promise that a restart finishes the denial.
    expect(AppL10nEn().removeDataDenyIncompleteMessage,
        isNot(contains('was removed')));
    expect(AppL10nEn().removeDataDenyIncompleteMessage,
        isNot(contains('Restart the app')));
  });

  testWidgets('Arabic copy', (tester) async {
    pending.value = true;
    await tester.pumpWidget(_app('ar', home: () => const SizedBox()));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text(AppL10nAr().removeDataDenyIncompleteMessage),
        findsOneWidget);
  });

  testWidgets('nothing is shown when nothing is pending', (tester) async {
    await tester.pumpWidget(_app('en', home: () => const SizedBox()));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const Key('deny_incomplete_notice')), findsNothing);
  });

  testWidgets('Retry that fails keeps the honest message and re-runs only the '
      'injected deny', (tester) async {
    var retries = 0;
    pending.value = true;
    await tester.pumpWidget(_app('en', home: () => const SizedBox(), retry: () async {
      retries++;
      return false;
    }));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byKey(const Key('deny_incomplete_retry')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(retries, 1);
    expect(find.byKey(const Key('deny_incomplete_notice')), findsOneWidget);
    expect(find.text(AppL10nEn().removeDataDenyStillIncomplete), findsOneWidget);
    expect(pending.value, isTrue);
  });

  testWidgets('Retry that succeeds closes the notice and clears the flag',
      (tester) async {
    var retries = 0;
    pending.value = true;
    await tester.pumpWidget(_app('en', home: () => const SizedBox(), retry: () async {
      retries++;
      return true;
    }));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byKey(const Key('deny_incomplete_retry')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(retries, 1);
    expect(find.byKey(const Key('deny_incomplete_notice')), findsNothing);
    expect(pending.value, isFalse);
  });

  testWidgets('Close dismisses the notice without retrying', (tester) async {
    var retries = 0;
    pending.value = true;
    await tester.pumpWidget(_app('en', home: () => const SizedBox(), retry: () async {
      retries++;
      return true;
    }));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byKey(const Key('deny_incomplete_close')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(retries, 0);
    expect(find.byKey(const Key('deny_incomplete_notice')), findsNothing);
  });
}
