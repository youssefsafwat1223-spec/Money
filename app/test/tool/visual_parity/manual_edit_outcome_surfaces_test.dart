import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/domain/entities/transaction_entity.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/features/transactions/manual_transaction_sheet.dart';
import 'package:money_companion/l10n/app_localizations.dart';

import '../../../tool/visual_parity/manual_edit_outcome_surfaces.dart';

class _Keys implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'manual-edit-parent-memory';
  @override
  Future<String?> readStoredKey() async => 'manual-edit-parent-memory';
}

Future<bool>? _opening;

class _Launch extends ConsumerWidget {
  const _Launch(this.keyName);
  final String keyName;
  @override
  Widget build(BuildContext context, WidgetRef ref) => Scaffold(
      body: TextButton(
          onPressed: () {
            _opening = openVisualParityManualEditOutcome(context, ref, keyName);
          },
          child: const Text('Open edit fixture')));
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

Future<void> _settle(WidgetTester tester) async {
  await tester
      .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
  await tester.pump(const Duration(milliseconds: 150));
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await _settle(tester);
}

void main() {
  late AppDatabase parent;
  final nativeCalls = <String>[];
  setUp(() async {
    parent = await AppDatabase.open(
        executor: NativeDatabase.memory(),
        keyStore: _Keys(),
        initialLanguage: 'en');
    nativeCalls.clear();
    for (final channel in [
      'plugins.flutter.io/flutter_secure_storage',
      'dexterous.com/flutter/local_notifications',
      'com.youssefsafwat.mali/capture',
      'plugins.flutter.io/firebase_messaging',
      'plugins.flutter.io/google_mobile_ads'
    ]) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(MethodChannel(channel), (call) async {
        nativeCalls.add('$channel:${call.method}');
        return null;
      });
    }
  });
  tearDown(() async => parent.close());
  for (final key in visualParityManualEditOutcomeKeys) {
    for (final language in ['ar', 'en']) {
      for (final dark in [false, true]) {
        testWidgets('$key real public edit $language dark=$dark',
            (tester) async {
          tester.view.physicalSize = const Size(375, 667);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          await tester.runAsync(() async {
            for (final family in [
              'Vazirmatn',
              'Alexandria',
              'IBMPlexSansArabic'
            ]) {
              final loader = FontLoader(family);
              for (final weight in ['Regular', 'Medium', 'SemiBold', 'Bold']) {
                loader.addFont(
                    rootBundle.load('assets/fonts/$family-$weight.ttf'));
              }
              await loader.load();
            }
          });
          final before = await tester.runAsync(() => _snapshot(parent));
          final eventsBefore = visualParityManualEditOutcomeEvents();
          int delta(String suffix) =>
              (visualParityManualEditOutcomeEvents()['$key$suffix'] ?? 0) -
              (eventsBefore['$key$suffix'] ?? 0);
          await tester.pumpWidget(ProviderScope(
              overrides: [appDatabaseProvider.overrideWithValue(parent)],
              child: MaterialApp(
                  theme: dark ? AppTheme.dark : AppTheme.light,
                  locale: Locale(language),
                  supportedLocales: AppL10n.supportedLocales,
                  localizationsDelegates: AppL10n.localizationsDelegates,
                  home: _Launch(key))));
          final outer = tester.state<NavigatorState>(find.byType(Navigator));
          final parentContainer =
              ProviderScope.containerOf(tester.element(find.byType(_Launch)));
          final parentRepository =
              parentContainer.read(transactionRepositoryProvider);
          addTearDown(() async {
            await tester.pumpWidget(const SizedBox.shrink());
            for (var i = 0; i < 4; i++) {
              await _settle(tester);
            }
            await tester.pump(const Duration(seconds: 5));
          });
          await tester.runAsync(() async {
            await tester.tap(find.text('Open edit fixture'));
            expect(await _opening, isTrue);
          });
          for (var i = 0; i < 5; i++) {
            await _settle(tester);
          }
          final form = find.byType(ManualTransactionSheet);
          expect(form, findsOneWidget);
          final context = tester.element(form);
          final l10n = AppL10n.of(context);
          final childContainer = ProviderScope.containerOf(context);
          final child = childContainer.read(appDatabaseProvider);
          expect(child, isNot(same(parent)));
          final repository = childContainer.read(transactionRepositoryProvider);
          expect(repository, isNot(same(parentRepository)));
          final rows = (await tester.runAsync(() => repository.getAll()))!;
          expect(rows, hasLength(1));
          final tx = rows.single;
          final awaiting = key == 'manualAwaitingPricing';
          expect(tx.status, TransactionStatus.pending);
          expect(tx.amountMoney, Money(awaiting ? 0 : 2468, 'EGP'));
          expect(tx.foreignMoney, awaiting ? Money(12345, 'KWD') : isNull);
          final childBefore = await tester.runAsync(() => _snapshot(child));
          final save = find.widgetWithText(FilledButton, l10n.mtSaveEdits);
          final confirm = find.widgetWithText(FilledButton, l10n.txdConfirmTx);
          final delete = find.widgetWithText(OutlinedButton, l10n.txdDeleteTx);
          final amount = find.byType(TextField).first;
          await tester.ensureVisible(amount);
          await tester.enterText(amount, awaiting ? '12.34' : '37.50');
          tester.testTextInput.hide();
          await tester.pump();
          if (awaiting) {
            await tester.ensureVisible(confirm);
            await tester.pumpAndSettle();
            expect(confirm.hitTestable(), findsOneWidget);
            expect(tester.widget<FilledButton>(confirm).onPressed, isNull);
            await tester.tap(confirm);
            await tester.pump();
            expect(delta('Attempt'), 0);
            expect(tx.pricingState, TransactionPricingState.awaitingFx);
            expect(tester.widget<FilledButton>(save).onPressed, isNotNull);
            expect(await tester.runAsync(() => _snapshot(child)), childBefore);
          } else {
            Future<void> attempt() async {
              if (key.contains('Save')) {
                await _tap(tester, save);
              } else if (key.contains('Confirm')) {
                await _tap(tester, confirm);
              } else {
                await _tap(tester, delete);
                expect(find.text(l10n.mtDeleteBody), findsOneWidget);
                await _tap(
                    tester, find.widgetWithText(TextButton, l10n.setDelete));
                await _settle(tester);
              }
            }

            await attempt();
            expect(delta('Attempt'), 1);
            final receipt = visualParityManualEditOutcomeReceipts()[key]!;
            expect(receipt['transactionId'], tx.id);
            expect(receipt['syntheticOnly'], isTrue);
            expect(receipt['status'], 'pending');
            expect(receipt['amountMinor'], 2468);
            final args = receipt['arguments']! as Map;
            expect(args['transactionId'], tx.id);
            if (key.contains('Save')) {
              expect(args['amountMinor'], 3750);
              expect(args['currency'], 'EGP');
              expect(args['accountId'], tx.accountId);
              expect(args['type'], 'payment');
              expect(
                  args['occurredAt'], tx.occurredAt.toUtc().toIso8601String());
              expect(args['categoryId'], tx.categoryId);
            }
            if (key.endsWith('Busy')) {
              expect(receipt['phase'], 'held');
              expect(delta('Held'), 1);
              expect(tester.widget<FilledButton>(save).onPressed, isNull);
              expect(tester.widget<FilledButton>(confirm).onPressed, isNull);
              expect(tester.widget<OutlinedButton>(delete).onPressed, isNull);
              expect(find.byType(CircularProgressIndicator), findsOneWidget);
              await tester.ensureVisible(confirm);
              await tester.pump();
              await tester.tap(confirm);
              await tester.pump();
              expect(delta('Attempt'), 1);
              // The held delete owns a real transaction. Child queries wait
              // until cancellation/rollback; never issue one while held.
              if (!key.contains('Delete')) {
                expect(
                    await tester.runAsync(() => _snapshot(child)), childBefore);
              }
            } else {
              for (var i = 0; i < 3; i++) {
                await _settle(tester);
              }
              final error = key.contains('Save')
                  ? l10n.mtSaveFailed
                  : key.contains('Delete')
                      ? l10n.mtDeleteFailed
                      : l10n.mtConfirmFailed;
              expect(find.text(error), findsOneWidget);
              expect(tester.widget<FilledButton>(save).onPressed, isNotNull);
              expect(tester.widget<FilledButton>(confirm).onPressed, isNotNull);
              expect(
                  tester.widget<OutlinedButton>(delete).onPressed, isNotNull);
              expect(
                  tester.widget<TextField>(amount).controller!.text, '37.50');
              expect(
                  await tester.runAsync(() => _snapshot(child)), childBefore);
              await attempt();
              expect(delta('Attempt'), 2);
              expect(delta('Refused'), 2);
              expect(
                  await tester.runAsync(() => _snapshot(child)), childBefore);
            }
          }
          expect(await tester.runAsync(() => _snapshot(parent)), before);
          expect(parentContainer.read(transactionRepositoryProvider),
              same(parentRepository));
          expect(nativeCalls, isEmpty);
          // Remove the entire owned navigator even with a held delete. Its
          // lifetime cancels, waits for real rollback, verifies SQL, then closes.
          outer.pop();
          for (var i = 0; i < 40 && delta('Closed') == 0; i++) {
            await _settle(tester);
          }
          expect(delta('Closed'), 1);
          expect(delta('AllSqlUnchanged'), 1);
          expect(
              visualParityManualEditOutcomeReceipts()[key]![
                  'childAllSqlUnchanged'],
              isTrue);
          if (key.endsWith('Busy')) {
            expect(delta('Cancelled'), 1);
            expect(delta('Settled'), 1);
          }
          expect(delta('ForbiddenWrite'), 0);
          expect(delta('ForbiddenDoubleAdmission'), 0);
          expect(delta('ForbiddenBillCleanup'), 0);
          expect(await tester.runAsync(() => _snapshot(parent)), before);
          // The real error toast owns its three-second dismissal timer even
          // when its modal overlay has just been disposed.
          await tester.pump(const Duration(seconds: 5));
          await _settle(tester);
          expect(nativeCalls, isEmpty);
          expect(tester.takeException(), isNull);
        });
      }
    }
  }
  testWidgets('unknown edit key accesses no provider', (tester) async {
    bool? handled;
    final events = visualParityManualEditOutcomeEvents();
    await tester.pumpWidget(ProviderScope(
        overrides: [
          appDatabaseProvider
              .overrideWith((ref) => throw StateError('must not read provider'))
        ],
        child: MaterialApp(
            home: Consumer(
                builder: (context, ref, _) => TextButton(
                    onPressed: () async {
                      handled = await openVisualParityManualEditOutcome(
                          context, ref, 'unrelated');
                    },
                    child: const Text('Unknown'))))));
    await tester.tap(find.text('Unknown'));
    await tester.pump();
    expect(handled, isFalse);
    expect(visualParityManualEditOutcomeEvents(), events);
    expect(tester.takeException(), isNull);
  });
  testWidgets('file parent rejected before any child fixture', (tester) async {
    final directory = (await tester
        .runAsync(() => Directory.systemTemp.createTemp('qirsh-edit-guard-')))!;
    final disk = (await tester.runAsync(() => AppDatabase.open(
        executor: NativeDatabase(File('${directory.path}/parent.sqlite')),
        keyStore: _Keys(),
        initialLanguage: 'en')))!;
    addTearDown(() async {
      await disk.close();
      await directory.delete(recursive: true);
    });
    final before = await tester.runAsync(() => _snapshot(disk));
    final events = visualParityManualEditOutcomeEvents();
    Object? rejection;
    await tester.pumpWidget(ProviderScope(
        overrides: [appDatabaseProvider.overrideWithValue(disk)],
        child: MaterialApp(
            home: Consumer(
                builder: (context, ref, _) => TextButton(
                    onPressed: () async {
                      try {
                        await openVisualParityManualEditOutcome(
                            context, ref, 'manualEditSaveBusy');
                      } catch (error) {
                        rejection = error;
                      }
                    },
                    child: const Text('File'))))));
    await tester.runAsync(() async {
      await tester.tap(find.text('File'));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();
    expect(rejection, isA<StateError>());
    expect(visualParityManualEditOutcomeEvents(), events);
    expect(await tester.runAsync(() => _snapshot(disk)), before);
    expect(find.byType(ManualTransactionSheet), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
