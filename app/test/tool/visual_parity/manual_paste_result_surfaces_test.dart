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
import 'package:money_companion/domain/usecases/add_transaction_usecase.dart';
import 'package:money_companion/domain/usecases/ingest_captured_message_usecase.dart';
import 'package:money_companion/l10n/app_localizations.dart';

import '../../../tool/visual_parity/manual_paste_result_surfaces.dart';

class _Keys implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'paste-test-memory';
  @override
  Future<String?> readStoredKey() async => 'paste-test-memory';
}

Future<bool>? _opening;

class _Launch extends ConsumerWidget {
  const _Launch(this.keyName);
  final String keyName;
  @override
  Widget build(BuildContext context, WidgetRef ref) => Scaffold(
      body: TextButton(
          onPressed: () {
            _opening = openVisualParityManualPasteResult(context, ref, keyName);
            _opening!.ignore();
          },
          child: const Text('Open paste fixture')));
}

Future<Map<String, Object>> _snapshot(AppDatabase db) async {
  final rows = await db
      .customSelect(
          "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name")
      .get();
  return {
    for (final row in rows)
      row.read<String>('name'): (await db
              .customSelect(
                  'SELECT * FROM "${row.read<String>('name')}" ORDER BY rowid')
              .get())
          .map((r) => r.data)
          .toList()
  };
}

Future<void> _settle(WidgetTester tester) async {
  await tester.runAsync(
      () async => Future<void>.delayed(const Duration(milliseconds: 120)));
  await tester.pump(const Duration(milliseconds: 450));
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
  for (final key in visualParityManualPasteResultKeys) {
    for (final lang in ['ar', 'en']) {
      for (final dark in [false, true]) {
        testWidgets('$key actual local pipeline $lang dark$dark',
            (tester) async {
          tester.view.physicalSize = const Size(375, 812);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          await tester.runAsync(() async {
            final fonts = FontLoader('Vazirmatn');
            for (final weight in ['Regular', 'Medium', 'SemiBold', 'Bold']) {
              fonts.addFont(
                  rootBundle.load('assets/fonts/Vazirmatn-$weight.ttf'));
            }
            await fonts.load();
          });
          final parentBefore = await _snapshot(parent);
          final closedBefore =
              visualParityManualPasteResultEvents()['${key}Closed'] ?? 0;
          await tester.pumpWidget(ProviderScope(
              overrides: [appDatabaseProvider.overrideWithValue(parent)],
              child: MaterialApp(
                  theme: dark ? AppTheme.dark : AppTheme.light,
                  locale: Locale(lang),
                  supportedLocales: AppL10n.supportedLocales,
                  localizationsDelegates: AppL10n.localizationsDelegates,
                  home: _Launch(key))));
          addTearDown(() async {
            await tester.pump(const Duration(seconds: 5));
            await tester.pumpWidget(const SizedBox.shrink());
            await _settle(tester);
          });
          await tester.runAsync(() async {
            await tester.tap(find.text('Open paste fixture'));
            expect(await _opening, true);
          });
          for (var i = 0; i < 4; i++) {
            await _settle(tester);
          }
          final field = find.byType(TextField).first;
          final context = tester.element(field);
          final l10n = AppL10n.of(context);
          final container = ProviderScope.containerOf(context);
          final child = container.read(appDatabaseProvider);
          expect(child, isNot(same(parent)));
          final childBefore = (await tester.runAsync(() => _snapshot(child)))!;
          final repository = container.read(transactionRepositoryProvider);
          final originalRows = await tester.runAsync(() => repository.getAll());
          expect(originalRows,
              hasLength(key == 'manualPasteSuspectedDuplicate' ? 1 : 0));
          final original = key == 'manualPasteSuspectedDuplicate'
              ? (await tester.runAsync(() => child
                      .customSelect('SELECT * FROM transactions')
                      .getSingle()))!
                  .data
              : null;
          await tester.enterText(field, visualParityManualPasteMessage(key));
          tester.testTextInput.hide();
          await tester.pump();
          final analyze = find.widgetWithText(FilledButton, l10n.pasteAnalyse);
          await tester.ensureVisible(analyze);
          await tester.pumpAndSettle();
          await tester.tap(analyze);
          final ingest = container.read(ingestCapturedMessageUseCaseProvider);
          CapturedMessageResult? result;
          for (var i = 0; i < 35; i++) {
            await _settle(tester);
            // This recorder delegates to super and only stores the real result.
            result = (ingest as dynamic).latest as CapturedMessageResult?;
            if (result != null &&
                (key != 'manualPasteSuspectedDuplicate' ||
                    result.addTransactionResult.outcome ==
                        AddTransactionOutcome.suspiciousDuplicate)) {
              break;
            }
          }
          expect(result, isNotNull);
          final actual = result!.addTransactionResult;
          final receipt = visualParityManualPasteResultReceipts()[key]!;
          expect(receipt['syntheticOnly'], isTrue);
          expect(receipt['outcome'], actual.outcome.name);
          expect(receipt['disposition'], result.disposition.name);
          expect(receipt['transactionId'], actual.transaction?.id);
          expect(receipt['transactionStatus'], actual.transaction?.status.name);
          expect(receipt['amountMinor'],
              actual.transaction?.amountMoney.minorUnits);
          expect(receipt['currency'], actual.transaction?.currency);
          expect(receipt['requiresConfirmation'], actual.requiresConfirmation);
          expect(receipt['aiFailureReason'], actual.aiFailureReason);
          expect(receipt.keys, isNot(contains('rawMessage')));
          final rows = await tester.runAsync(() => repository.getAll());
          if (key == 'manualPasteOffline') {
            expect(actual.outcome, AddTransactionOutcome.notTransaction);
            expect(
                actual.aiFailureReason,
                key == 'manualPasteOffline'
                    ? 'message_ignored'
                    : key == 'manualPasteAiOff'
                        ? 'consent_off'
                        : 'no_ai_client');
            expect(rows, isEmpty);
            expect(find.text(l10n.pasteAiOffline), findsOneWidget);
            expect(await tester.runAsync(() => _snapshot(child)), childBefore);
          } else if (key == 'manualPasteSuspectedDuplicate') {
            expect(actual.outcome, AddTransactionOutcome.suspiciousDuplicate);
            expect(rows, hasLength(1));
            final suspect = await tester.runAsync(() => container
                .read(suspectedDuplicateRepositoryProvider)
                .getByExistingTransactionId(rows!.single.id));
            expect(suspect, isNotNull);
            expect(actual.suspectedDuplicateId, suspect!.id);
            expect(suspect.amountMoney, Money(4500, 'SAR'));
            expect(suspect.currency, 'SAR');
            expect(suspect.senderId, isNull);
            expect(suspect.existingTransactionId, rows!.single.id);
            expect(
                (await tester.runAsync(() => child
                        .customSelect(
                            'SELECT COUNT(*) AS n FROM suspected_duplicates')
                        .getSingle()))!
                    .read<int>('n'),
                1);
            expect(
                (await tester.runAsync(() => child
                        .customSelect('SELECT * FROM transactions')
                        .getSingle()))!
                    .data,
                original);
          } else {
            expect(actual.outcome, AddTransactionOutcome.added);
            expect(
                actual.aiFailureReason,
                key == 'manualPasteOffline'
                    ? 'message_ignored'
                    : key == 'manualPasteAiOff'
                        ? 'consent_off'
                        : 'no_ai_client');
            expect(rows, hasLength(1));
            final tx = rows!.single;
            expect(tx.amountMoney,
                Money(key == 'manualPasteKnownAdded' ? 4500 : 8200, 'SAR'));
            expect(tx.currency, 'SAR');
            expect(actual.transaction!.id, tx.id);
            expect(tx.rawMessage, visualParityManualPasteMessage(key));
            expect(tx.type, TransactionTypeEntity.payment);
            expect(tx.accountId, 'qa-paste-sar');
            // Both known and new merchants remain pending under the actual
            // DB-backed coordinator and shipped local/proof gates. Do not force
            // auto-confirm merely to match an older domain-constructor example.
            expect(tx.status, TransactionStatus.pending);
            expect(actual.requiresConfirmation, isTrue);
            expect(tx.source, isNot(TransactionSourceEntity.aiParsed));
            expect(
                find.text(key == 'manualPasteAiOff'
                    ? l10n.pasteAiOff
                    : l10n.pasteAiUnavailable),
                findsWidgets);
            // Actual public host callback opened the real review using owned data.
            expect(
                visualParityManualPasteResultEvents()['${key}ActualHostReview'],
                greaterThan(0));
          }
          final childAfter = (await tester.runAsync(() => _snapshot(child)))!;
          final allowedChanges = key == 'manualPasteOffline'
              ? <String>{}
              : key == 'manualPasteSuspectedDuplicate'
                  ? {'suspected_duplicates'}
                  : {'transactions', 'merchants', 'dedup_hashes'};
          for (final table in childBefore.keys) {
            if (!allowedChanges.contains(table)) {
              expect(childAfter[table], childBefore[table],
                  reason: 'Unrelated child table $table');
            }
          }
          expect(
              visualParityManualPasteResultEvents()[
                      '${key}ForbiddenAiRequest'] ??
                  0,
              0);
          if (key == 'manualPasteAiOff') {
            expect(
                visualParityManualPasteResultEvents()[
                    '${key}ActualConsentRead'],
                greaterThan(0));
          }
          expect(await tester.runAsync(() => _snapshot(parent)), parentBefore);
          expect(nativeCalls, isEmpty);
          expect(tester.takeException(), isNull);
          // Dismiss all visible owned modals. Never Confirm/Keep/Discard.
          for (var i = 0;
              i < 4 &&
                  find
                      .text('Open paste fixture')
                      .hitTestable()
                      .evaluate()
                      .isEmpty;
              i++) {
            final elements = find.byType(Navigator).evaluate().toList();
            final navigator = tester
                .state<NavigatorState>(find.byWidget(elements.last.widget));
            if (navigator.canPop()) navigator.pop();
            await _settle(tester);
          }
          await tester.pump(const Duration(seconds: 5));
          await _settle(tester);
          expect(visualParityManualPasteResultEvents()['${key}Closed'],
              closedBefore + 1);
          expect(await tester.runAsync(() => _snapshot(parent)), parentBefore);
        });
      }
    }
  }
  testWidgets('unknown result key returns before any provider access',
      (tester) async {
    bool? handled;
    final before = visualParityManualPasteResultEvents();
    await tester.pumpWidget(ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWith(
              (ref) => throw StateError('database must not be read'))
        ],
        child: MaterialApp(
            home: Consumer(
                builder: (context, ref, _) => TextButton(
                    onPressed: () async {
                      handled = await openVisualParityManualPasteResult(
                          context, ref, 'unrelated');
                    },
                    child: const Text('Unknown'))))));
    await tester.tap(find.text('Unknown'));
    await tester.pump();
    expect(handled, isFalse);
    expect(visualParityManualPasteResultEvents(), before);
    expect(tester.takeException(), isNull);
  });
  testWidgets('file-backed parent rejected before owned capture scope exists',
      (tester) async {
    final directory = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('qirsh-paste-guard-')))!;
    final disk = (await tester.runAsync(() => AppDatabase.open(
        executor: NativeDatabase(File('${directory.path}/parent.sqlite')),
        keyStore: _Keys(),
        initialLanguage: 'en')))!;
    addTearDown(() async {
      await disk.close();
      await directory.delete(recursive: true);
    });
    final before = await tester.runAsync(() => _snapshot(disk));
    final events = visualParityManualPasteResultEvents();
    Object? rejected;
    await tester.pumpWidget(ProviderScope(
        overrides: [appDatabaseProvider.overrideWithValue(disk)],
        child: MaterialApp(
            home: Consumer(
                builder: (context, ref, _) => TextButton(
                    onPressed: () async {
                      try {
                        await openVisualParityManualPasteResult(
                            context, ref, 'manualPasteKnownAdded');
                      } catch (error) {
                        rejected = error;
                      }
                    },
                    child: const Text('File parent'))))));
    await tester.runAsync(() async {
      await tester.tap(find.text('File parent'));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();
    expect(rejected, isA<StateError>());
    expect(visualParityManualPasteResultEvents(), events);
    expect(await tester.runAsync(() => _snapshot(disk)), before);
    expect(find.byType(TextField), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
