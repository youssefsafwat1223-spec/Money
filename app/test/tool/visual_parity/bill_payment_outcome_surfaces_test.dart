import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/di/account_access_mode.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/session/account_scope.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/core/theme/widgets/glass_dialog.dart';
import 'package:money_companion/features/subscriptions/bill_details_sheet.dart';

import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/l10n/app_localizations.dart';

import '../../../tool/visual_parity/bill_payment_outcome_surfaces.dart';

class _Keys implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'bill-payment-outcome-test-memory';
  @override
  Future<String?> readStoredKey() async => 'bill-payment-outcome-test-memory';
}

Future<Map<String, Object>> _snapshot(AppDatabase db) async {
  final tables = await db
      .customSelect(
          "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name")
      .get();
  return {
    for (final table in tables)
      table.read<String>('name'): (await db
              .customSelect(
                  'SELECT * FROM "${table.read<String>('name')}" ORDER BY rowid')
              .get())
          .map((row) => row.data)
          .toList()
  };
}

Future<void> _io(WidgetTester tester) async {
  await tester.runAsync(
      () async => Future<void>.delayed(const Duration(milliseconds: 80)));
  await tester.pump(const Duration(milliseconds: 350));
}

void main() {
  for (final key in visualParityBillPaymentOutcomeKeys) {
    for (final language in ['ar', 'en']) {
      for (final dark in [false, true]) {
        testWidgets('$key actual public payment $language dark$dark',
            (tester) async {
          tester.view.physicalSize = const Size(375, 667);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          late AppDatabase parentDb;
          await tester.runAsync(() async {
            for (final family in [
              'Vazirmatn',
              'Alexandria',
              'IBMPlexSansArabic'
            ]) {
              final font = FontLoader(family);
              for (final w in ['Regular', 'Medium', 'SemiBold', 'Bold']) {
                font.addFont(rootBundle.load('assets/fonts/$family-$w.ttf'));
              }
              await font.load();
            }
            parentDb = await AppDatabase.open(
                executor: NativeDatabase.memory(), keyStore: _Keys());
          });
          final parent = ProviderContainer(
              overrides: [appDatabaseProvider.overrideWithValue(parentDb)]);
          addTearDown(() async {
            final close = closeVisualParityBillPaymentOutcome();
            await tester.pumpAndSettle();
            await tester.runAsync(() => close);
            parent.dispose();
            await parentDb.close();
          });
          final beforeParent = await tester.runAsync(() => _snapshot(parentDb));
          final parentRepo = parent.read(transactionRepositoryProvider);
          final events = visualParityBillPaymentOutcomeEvents();
          int delta(String suffix) =>
              (visualParityBillPaymentOutcomeEvents()['$key$suffix'] ?? 0) -
              (events['$key$suffix'] ?? 0);
          final root = GlobalKey<NavigatorState>();
          Future<bool?>? opening;
          await tester.pumpWidget(UncontrolledProviderScope(
              container: parent,
              child: MaterialApp(
                  navigatorKey: root,
                  theme: dark ? AppTheme.dark : AppTheme.light,
                  locale: Locale(language),
                  supportedLocales: AppL10n.supportedLocales,
                  localizationsDelegates: AppL10n.localizationsDelegates,
                  builder: (context, child) =>
                      Stack(fit: StackFit.expand, children: [
                        child!,
                        ValueListenableBuilder<Widget?>(
                            valueListenable:
                                visualParityBillPaymentOutcomeOverlay,
                            builder: (_, overlay, __) =>
                                overlay ?? const SizedBox.shrink())
                      ]),
                  home: Consumer(
                      builder: (context, ref, _) => Scaffold(
                          body: TextButton(
                              onPressed: () {
                                opening = tester.runAsync(() =>
                                    openVisualParityBillPaymentOutcome(
                                        context, ref, key));
                              },
                              child: const Text('Original router')))))));
          final original = tester.element(find.text('Original router'));
          final originalState = root.currentState;
          await tester.tap(find.text('Original router'));
          expect(await opening, isTrue);
          await tester.pumpAndSettle();
          for (var i = 0; i < 3; i++) {
            await _io(tester);
          }
          final details = find.byType(BillDetailsSheet);
          final detailContext = tester.element(details);
          final owned = Navigator.of(detailContext);
          expect(Navigator.of(detailContext, rootNavigator: true), same(owned));
          expect(owned, isNot(same(originalState)));
          expect(Navigator.of(visualParityBillPaymentOutcomeInspectionContext!),
              same(owned));
          final child = ProviderScope.containerOf(detailContext);
          final childDb = child.read(appDatabaseProvider);
          final bill = await tester.runAsync(() => child
              .read(billRepositoryProvider)
              .getById('qa-bill-payment-bill'));
          expect(bill!.amountMoney.minorUnits, 12345);
          expect(bill.currency, 'KWD');
          final accounts = await tester
              .runAsync(() => child.read(accountRepositoryProvider).getAll());
          expect(accounts!.single.currentBalanceMoney!.minorUnits, 100000);
          expect(
              await tester.runAsync(
                  () => child.read(transactionRepositoryProvider).getAll()),
              isEmpty);
          expect(
              await tester.runAsync(() =>
                  child.read(billRepositoryProvider).getPayments(bill.id)),
              isEmpty);
          final beforeChild = await tester.runAsync(() => _snapshot(childDb));
          final l10n = AppL10n.of(detailContext);
          final record =
              find.widgetWithText(FilledButton, l10n.bdsRecordPayment);
          await tester.ensureVisible(record);
          await tester.pumpAndSettle();
          await tester.tap(record);
          await tester.pumpAndSettle();
          expect(find.byType(GlassAlertDialog), findsOneWidget);
          final amount = find.byKey(const ValueKey('bill-payment-amount'));
          final submit = find.byKey(const ValueKey('bill-payment-submit'));
          expect(Navigator.of(tester.element(amount)), same(owned));
          final amountController = tester.widget<TextField>(amount).controller!;
          final noteController = tester
              .widget<TextField>(
                  find.widgetWithText(TextField, l10n.bdsOptionalNote))
              .controller!;
          expect(amountController.text, '12.345');
          void listener() {}
          void expectAlive() {
            for (final controller in [amountController, noteController]) {
              expect(() => controller.addListener(listener), returnsNormally);
              controller.removeListener(listener);
            }
          }

          void expectDisposed() {
            for (final controller in [amountController, noteController]) {
              expect(
                  () => controller.addListener(listener), throwsFlutterError);
            }
          }

          await tester.enterText(
              amount,
              key == 'billPaymentInvalid'
                  ? '1.2345'
                  : language == 'ar'
                      ? '١٢٫٣٤٥'
                      : '12.345');
          tester.testTextInput.hide();
          await tester.pumpAndSettle();
          await tester.tap(submit);
          await _io(tester);
          if (key == 'billPaymentInvalid') {
            expect(find.text(l10n.bfInvalidAmount), findsOneWidget);
            expect(visualParityBillPaymentOutcomeEvents()[key] ?? 0,
                events[key] ?? 0);
            expect(tester.widget<FilledButton>(submit).onPressed, isNotNull);
            expect(tester.widget<TextField>(amount).enabled, isTrue);
          } else {
            expect(visualParityBillPaymentOutcomeEvents()[key],
                (events[key] ?? 0) + 1);
            if (key == 'billPaymentBusy') {
              expect(tester.widget<FilledButton>(submit).onPressed, isNull);
              expect(find.byType(CircularProgressIndicator), findsOneWidget);
              expect(
                  tester
                      .widget<TextButton>(
                          find.widgetWithText(TextButton, l10n.commonCancel))
                      .onPressed,
                  isNull);
              expect(tester.widget<TextField>(amount).enabled, isFalse);
              expect(
                  tester
                      .widget<TextField>(
                          find.widgetWithText(TextField, l10n.bdsOptionalNote))
                      .enabled,
                  isFalse);
              expect(
                  tester
                      .widget<PopScope>(find
                          .ancestor(of: amount, matching: find.byType(PopScope))
                          .first)
                      .canPop,
                  isFalse);
              await tester.tap(submit, warnIfMissed: false);
              await tester.pump();
              expect(visualParityBillPaymentOutcomeEvents()[key],
                  (events[key] ?? 0) + 1);
            } else {
              expect(find.byKey(const ValueKey('bill-payment-error')),
                  findsOneWidget);
              expect(find.text(l10n.bdsRecordFailed), findsOneWidget);
              expect(find.text(l10n.bdsSavedButNotLinked), findsNothing);
              expect(find.textContaining('private_bill_'), findsNothing);
              expect(find.text(l10n.annRetry), findsOneWidget);
              expect(tester.widget<FilledButton>(submit).onPressed, isNotNull);
              expect(tester.widget<TextField>(amount).enabled, isFalse,
                  reason:
                      'Actual attempt retains payment input on failed first transaction');
              await tester.tap(submit);
              await _io(tester);
              expect(visualParityBillPaymentOutcomeEvents()[key],
                  (events[key] ?? 0) + 2);
            }
          }
          expect(await tester.runAsync(() => _snapshot(childDb)), beforeChild);
          expect(
              await tester.runAsync(() => _snapshot(parentDb)), beforeParent);
          expect(parent.read(transactionRepositoryProvider), same(parentRepo));
          expect(original.mounted, isTrue);
          expect(root.currentState, same(originalState));
          expect(
              visualParityBillPaymentOutcomeEvents()[
                      'billPaymentForbiddenWrite'] ??
                  0,
              events['billPaymentForbiddenWrite'] ?? 0);
          expect(
              visualParityBillPaymentOutcomeEvents()[
                      'billPaymentForbiddenLink'] ??
                  0,
              events['billPaymentForbiddenLink'] ?? 0);
          await tester.pump(const Duration(seconds: 5));
          if (key != 'billPaymentBusy') {
            final admissions = visualParityBillPaymentOutcomeEvents()[key] ?? 0;
            final cancel = find.widgetWithText(TextButton, l10n.commonCancel);
            expect(cancel.hitTestable(), findsOneWidget);
            await tester.tap(cancel);
            expectAlive();
            await tester.pump();
            expect(find.byType(GlassAlertDialog), findsOneWidget,
                reason: 'Actual reverse transition keeps the dialog mounted');
            await tester.pump(const Duration(milliseconds: 30));
            expectAlive();
            expect(tester.takeException(), isNull);
            await tester.pumpAndSettle();
            expect(find.byType(GlassAlertDialog), findsNothing);
            expectDisposed();
            expect(detailContext.mounted, isTrue);
            expect(
                visualParityBillPaymentOutcomeEvents()[key] ?? 0, admissions);
            expect(
                await tester.runAsync(() => _snapshot(childDb)), beforeChild);
            await tester.ensureVisible(record);
            await tester.pumpAndSettle();
            expect(record.hitTestable(), findsOneWidget);
            await tester.tap(record);
            await tester.pumpAndSettle();
            final freshAmount = tester.widget<TextField>(amount).controller!;
            final freshNote = tester
                .widget<TextField>(
                    find.widgetWithText(TextField, l10n.bdsOptionalNote))
                .controller!;
            expect(freshAmount, isNot(same(amountController)));
            expect(freshNote, isNot(same(noteController)));
            expect(freshAmount.text, '12.345');
            expect(freshNote.text, isEmpty);
            expect(tester.widget<TextField>(amount).enabled, isTrue);
            expect(cancel.hitTestable(), findsOneWidget);
            await tester.tap(cancel);
            for (final controller in [freshAmount, freshNote]) {
              expect(() => controller.addListener(listener), returnsNormally);
              controller.removeListener(listener);
            }
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 30));
            expect(find.byType(GlassAlertDialog), findsOneWidget);
            expect(tester.takeException(), isNull);
            await tester.pumpAndSettle();
            for (final controller in [freshAmount, freshNote]) {
              expect(
                  () => controller.addListener(listener), throwsFlutterError);
            }
            expect(find.byType(GlassAlertDialog), findsNothing);
            expect(
                visualParityBillPaymentOutcomeEvents()[key] ?? 0, admissions);
            expect(
                await tester.runAsync(() => _snapshot(childDb)), beforeChild);
          }
          final close = closeVisualParityBillPaymentOutcome();
          expect(closeVisualParityBillPaymentOutcome(), same(close));
          await tester.pump();
          expect(detailContext.mounted, isFalse);
          expectDisposed();
          for (var i = 0; i < 25 && delta('Closed') == 0; i++) {
            await _io(tester);
            await tester.pumpAndSettle();
          }
          await tester.runAsync(() => close);
          expect(delta('Closed'), 1);
          expect(delta('AllSqlUnchanged'), 1);
          expect(delta('UnmountedBeforeCancel'), 1);
          if (key == 'billPaymentBusy') {
            expect(delta('Cancelled'), 1);
            expect(delta('Settled'), 1);
          }
          expect(visualParityBillPaymentOutcomeOverlay.value, isNull);
          expect(visualParityBillPaymentOutcomeInspectionContext, isNull);
          expect(original.mounted, isTrue);
          expect(find.text('Original router').hitTestable(), findsOneWidget);
          expect(
              await tester.runAsync(() => _snapshot(parentDb)), beforeParent);
          await tester.pump(const Duration(seconds: 5));
          expect(tester.takeException(), isNull);
        });
      }
    }
  }
  for (final guard in ['unknown', 'file', 'readOnly']) {
    testWidgets('$guard rejects bill payment fixture before owned allocation',
        (tester) async {
      Directory? directory;
      AppDatabase? db;
      if (guard == 'file') {
        await tester.runAsync(() async {
          directory = await Directory.systemTemp
              .createTemp('qirsh-bill-payment-guard-');
          db = await AppDatabase.open(
              executor: NativeDatabase(File('${directory!.path}/guard.sqlite')),
              keyStore: _Keys());
        });
      }
      final before =
          db == null ? null : await tester.runAsync(() => _snapshot(db!));
      final events =
          Map<String, int>.of(visualParityBillPaymentOutcomeEvents());
      final parent = ProviderContainer(overrides: [
        if (db != null) appDatabaseProvider.overrideWithValue(db!),
        if (guard == 'readOnly')
          accountAccessModeProvider
              .overrideWithValue(AccountAccessMode.localRead),
      ]);
      addTearDown(() async {
        parent.dispose();
        await db?.close();
        await directory?.delete(recursive: true);
      });
      Future<void>? opening;
      Object? failure;
      bool? result;
      await tester.pumpWidget(UncontrolledProviderScope(
          container: parent,
          child: MaterialApp(
              home: Consumer(
                  builder: (context, ref, _) => Scaffold(
                      body: TextButton(
                          onPressed: () {
                            opening = tester.runAsync(() async {
                              try {
                                result =
                                    await openVisualParityBillPaymentOutcome(
                                        context,
                                        ref,
                                        guard == 'unknown'
                                            ? 'unknown'
                                            : 'billPaymentError');
                              } catch (error) {
                                failure = error;
                              }
                            });
                          },
                          child: const Text('Guard')))))));
      await tester.tap(find.text('Guard'));
      await opening;
      if (guard == 'unknown') {
        expect(result, isFalse);
        expect(failure, isNull);
      } else {
        expect(failure, isA<StateError>());
      }
      expect(visualParityBillPaymentOutcomeOverlay.value, isNull);
      expect(visualParityBillPaymentOutcomeEvents(), events);
      if (db != null) {
        expect(await tester.runAsync(() => _snapshot(db!)), before);
      }
      expect(tester.takeException(), isNull);
    });
  }
}
