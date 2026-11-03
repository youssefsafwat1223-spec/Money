import 'dart:io';
import 'package:money_companion/core/di/account_access_mode.dart';
import 'package:money_companion/core/session/account_scope.dart';
import 'dart:convert';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/core/theme/widgets/glass_dialog.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/features/subscriptions/bill_details_sheet.dart';
import 'package:money_companion/l10n/app_localizations.dart';
import '../../../tool/visual_parity/bill_partial_link_surfaces.dart';

class _Keys implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'partial-test-memory';
  @override
  Future<String?> readStoredKey() async => 'partial-test-memory';
}

Future<String> _snapshot(AppDatabase db) async {
  final tables = await db
      .customSelect(
          "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name")
      .get();
  return jsonEncode({
    for (final t in tables)
      t.read<String>('name'): (await db
              .customSelect(
                  'SELECT * FROM "${t.read<String>('name')}" ORDER BY rowid')
              .get())
          .map((r) => r.data)
          .toList()
  });
}

Future<void> _io(WidgetTester t) async {
  await t.runAsync(
      () async => Future<void>.delayed(const Duration(milliseconds: 80)));
  await t.pump(const Duration(milliseconds: 350));
}

void main() {
  for (final lang in ['ar', 'en']) {
    for (final dark in [false, true]) {
      testWidgets(
          'genuine transaction once, failed bill link retries safely $lang dark$dark',
          (tester) async {
        tester.view.physicalSize = const Size(375, 667);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        late AppDatabase parentDb;
        await tester.runAsync(() async {
          final font = FontLoader('Vazirmatn');
          for (final w in ['Regular', 'Medium', 'SemiBold', 'Bold']) {
            font.addFont(rootBundle.load('assets/fonts/Vazirmatn-$w.ttf'));
          }
          await font.load();
          parentDb = await AppDatabase.open(
              executor: NativeDatabase.memory(), keyStore: _Keys());
        });
        final parent = ProviderContainer(
            overrides: [appDatabaseProvider.overrideWithValue(parentDb)]);
        final parentBefore = await tester.runAsync(() => _snapshot(parentDb));
        final parentRepo = parent.read(transactionRepositoryProvider);
        final root = GlobalKey<NavigatorState>();
        Future<bool?>? opening;
        await tester.pumpWidget(UncontrolledProviderScope(
            container: parent,
            child: MaterialApp(
                navigatorKey: root,
                theme: dark ? AppTheme.dark : AppTheme.light,
                locale: Locale(lang),
                supportedLocales: AppL10n.supportedLocales,
                localizationsDelegates: AppL10n.localizationsDelegates,
                builder: (context, child) =>
                    Stack(fit: StackFit.expand, children: [
                      child!,
                      ValueListenableBuilder<Widget?>(
                          valueListenable: visualParityBillPartialLinkOverlay,
                          builder: (_, overlay, __) =>
                              overlay ?? const SizedBox.shrink())
                    ]),
                home: Consumer(
                    builder: (context, ref, _) => Scaffold(
                        body: TextButton(
                            onPressed: () {
                              opening = tester.runAsync(() =>
                                  openVisualParityBillPartialLink(context, ref,
                                      'billPaymentPartialLinkError'));
                            },
                            child: const Text('Original root')))))));
        final rootState = root.currentState;
        final original = tester.element(find.text('Original root'));
        await tester.tap(find.text('Original root'));
        expect(await opening, isTrue);
        await tester.pumpAndSettle();
        for (var i = 0; i < 3; i++) {
          await _io(tester);
        }
        final context = tester.element(find.byType(BillDetailsSheet));
        final owned = Navigator.of(context);
        expect(owned, isNot(same(rootState)));
        expect(Navigator.of(context, rootNavigator: true), same(owned));
        final child = ProviderScope.containerOf(context);
        final db = child.read(appDatabaseProvider);
        final before = await tester.runAsync(() => _snapshot(db));
        final txRepo = child.read(transactionRepositoryProvider);
        final accountRepo = child.read(accountRepositoryProvider);
        final billRepo = child.read(billRepositoryProvider);
        final from = DateTime.utc(2000);
        final to = DateTime.utc(2100);
        Future<Money?> expense() =>
            tester.runAsync(() => txRepo.expenseTotalBetween(
                from: from,
                to: to,
                currency: 'KWD',
                accountId: 'qa-bill-payment-account'));
        expect(await expense(), Money.zero('KWD'));
        expect(await tester.runAsync(() => txRepo.getAll()), isEmpty);
        final l = AppL10n.of(context);
        final record = find.widgetWithText(FilledButton, l.bdsRecordPayment);
        await tester.ensureVisible(record);
        await tester.pumpAndSettle();
        await tester.tap(record);
        await tester.pumpAndSettle();
        expect(find.byType(GlassAlertDialog), findsOneWidget);
        final amount = find.byKey(const ValueKey('bill-payment-amount'));
        final submit = find.byKey(const ValueKey('bill-payment-submit'));
        final note = find.widgetWithText(TextField, l.bdsOptionalNote);
        final amountController = tester.widget<TextField>(amount).controller!;
        final noteController = tester.widget<TextField>(note).controller!;
        await tester.enterText(amount, lang == 'ar' ? '١٢٫٣٤٥' : '12.345');
        await tester.enterText(note, 'QA partial note');
        tester.testTextInput.hide();
        await tester.pumpAndSettle();
        await tester.tap(submit);
        for (var i = 0; i < 4; i++) {
          await _io(tester);
        }
        await tester.pumpAndSettle();
        expect(find.text(l.bdsSavedButNotLinked), findsOneWidget);
        expect(find.text(l.bdsRecordFailed), findsNothing);
        expect(find.textContaining('private_bill_'), findsNothing);
        expect(find.text(l.annRetry), findsOneWidget);
        final receipt1 = visualParityBillPartialLinkReceipt();
        expect(receipt1['transactionSaves'], 1);
        expect(receipt1['linkAttempts'], 1);
        expect(receipt1['amountMinor'], 12345);
        final actual = (await tester.runAsync(() => txRepo.getAll()))!;
        expect(actual, hasLength(1));
        final tx = actual.single;
        expect(tx.id, receipt1['transactionId']);
        expect(tx.amountMoney, Money(12345, 'KWD'));
        expect(tx.accountId, 'qa-bill-payment-account');
        expect(tx.balanceAfterMoney, isNull);
        expect(await expense(), Money(12345, 'KWD'));
        expect(
            await tester.runAsync(() => txRepo.incomeTotalBetween(
                from: from,
                to: to,
                currency: 'KWD',
                accountId: 'qa-bill-payment-account')),
            Money.zero('KWD'));
        expect(
            await tester
                .runAsync(() => billRepo.getPayments('qa-bill-payment-bill')),
            isEmpty);
        final account = (await tester
            .runAsync(() => accountRepo.getById('qa-bill-payment-account')))!;
        expect(account.currentBalanceMoney, Money(100000, 'KWD'));
        final post = await tester.runAsync(() => _snapshot(db));
        validateBillPartialSqlDelta(before!, post!, tx.id);
        expect(tester.widget<TextField>(amount).enabled, isFalse);
        expect(tester.widget<TextField>(note).enabled, isFalse);
        await tester.tap(submit);
        for (var i = 0; i < 3; i++) {
          await _io(tester);
        }
        await tester.pumpAndSettle();
        final receipt2 = visualParityBillPartialLinkReceipt();
        expect(receipt2['transactionSaves'], 1);
        expect(receipt2['linkAttempts'], 2);
        final args = receipt2['paymentArguments'] as List;
        expect(args[0], args[1]);
        expect((args[0] as Map)['note'], 'QA partial note');
        expect((args[0] as Map)['transactionId'], tx.id);
        expect(await tester.runAsync(() => _snapshot(db)), post);
        expect(await expense(), Money(12345, 'KWD'));
        expect(await tester.runAsync(() => txRepo.getAll()), hasLength(1));
        expect(find.text(l.bdsSavedButNotLinked), findsOneWidget);
        final cancel = find.widgetWithText(TextButton, l.commonCancel);
        await tester.tap(cancel);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 30));
        void listener() {}
        for (final controller in [amountController, noteController]) {
          expect(() => controller.addListener(listener), returnsNormally);
          controller.removeListener(listener);
        }
        expect(tester.takeException(), isNull);
        await tester.pumpAndSettle();
        for (final controller in [amountController, noteController]) {
          expect(() => controller.addListener(listener), throwsFlutterError);
        }
        expect(await tester.runAsync(() => _snapshot(db)), post);
        final close = closeVisualParityBillPartialLink();
        await tester.pump();
        for (var i = 0; i < 15; i++) {
          await _io(tester);
          await tester.pumpAndSettle();
        }
        await tester.runAsync(() => close);
        final finalReceipt = visualParityBillPartialLinkReceipt();
        expect(finalReceipt['baselineDeltaValidated'], isTrue);
        expect(finalReceipt['postCommitSqlUnchanged'], isTrue);
        expect(finalReceipt['transactionSaves'], 1);
        expect(finalReceipt['linkAttempts'], 2);
        expect(await tester.runAsync(() => _snapshot(parentDb)), parentBefore);
        expect(parent.read(transactionRepositoryProvider), same(parentRepo));
        expect(original.mounted, isTrue);
        expect(root.currentState, same(rootState));
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        parent.dispose();
        await tester.runAsync(() => parentDb.close());
      });
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
      final events = Map<String, int>.of(visualParityBillPartialLinkEvents());
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
                                result = await openVisualParityBillPartialLink(
                                    context,
                                    ref,
                                    guard == 'unknown'
                                        ? 'unknown'
                                        : 'billPaymentPartialLinkError');
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
      expect(visualParityBillPartialLinkOverlay.value, isNull);
      expect(visualParityBillPartialLinkEvents(), events);
      if (db != null) {
        expect(await tester.runAsync(() => _snapshot(db!)), before);
      }
      expect(tester.takeException(), isNull);
    });
  }
}
