import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/domain/usecases/ingest_captured_message_usecase.dart';
import 'package:money_companion/l10n/app_localizations.dart';

import '../../../tool/visual_parity/paste_outcome_surfaces.dart';

class _Keys implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'paste-outcome-memory-only';
  @override
  Future<String?> readStoredKey() async => 'paste-outcome-memory-only';
}

class _ParentIngest implements IngestCapturedMessageUseCase {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw StateError('parent_ingest_must_not_run');
}

Future<Map<String, Object>> _snapshot(AppDatabase db) async {
  final tables = await db.customSelect(
      "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name").get();
  return {
    for (final row in tables)
      row.read<String>('name'): (await db.customSelect(
          'SELECT * FROM "${row.read<String>('name')}" ORDER BY rowid').get())
          .map((value) => value.data).toList(),
  };
}

void main() {
  late AppDatabase db;
  setUp(() async {
    db = await AppDatabase.open(executor: NativeDatabase.memory(),
        keyStore: _Keys(), initialLanguage: 'en');
  });
  tearDown(() async => db.close());

  for (final key in visualParityPasteOutcomeKeys) {
    for (final language in ['ar', 'en']) {
      for (final dark in [false, true]) {
        testWidgets('$key $language dark$dark public modal failure has no data or authority', (tester) async {
          tester.view.physicalSize = const Size(375, 667);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          await tester.runAsync(() async {
            final font = FontLoader('Vazirmatn');
            for (final weight in ['Regular', 'Medium', 'SemiBold', 'Bold']) {
              font.addFont(rootBundle.load('assets/fonts/Vazirmatn-$weight.ttf'));
            }
            await font.load();
          });
          final parent = _ParentIngest();
          final container = ProviderContainer(overrides: [
            appDatabaseProvider.overrideWithValue(db),
            ingestCapturedMessageUseCaseProvider.overrideWithValue(parent),
          ]);
          addTearDown(container.dispose);
          final before = await _snapshot(db);
          final admissions = visualParityPasteOutcomeEvents()[key] ?? 0;
          await tester.pumpWidget(UncontrolledProviderScope(container: container,
            child: MaterialApp(theme: dark ? AppTheme.dark : AppTheme.light,
              locale: Locale(language), supportedLocales: AppL10n.supportedLocales,
              localizationsDelegates: AppL10n.localizationsDelegates,
              home: Consumer(builder: (context, ref, _) => Scaffold(body: TextButton(
                onPressed: () async => openVisualParityPasteOutcome(context, ref, key),
                child: const Text('Open paste fixture'),
              ))))));
          await tester.tap(find.text('Open paste fixture'));
          await tester.runAsync(() async => Future<void>.delayed(const Duration(milliseconds: 80)));
          await tester.pumpAndSettle();
          const first = 'Your Debit Card purchase EGP 250.00 at QA SHOP on 01/11';
          const second = 'Your Debit Card purchase EGP 350.00 at QA STORE on 01/11';
          final input = key == 'manualPasteBatchError' ? '$first\n\n$second' : first;
          await tester.enterText(find.byType(TextField), input);
          tester.testTextInput.hide();
          await tester.pumpAndSettle();
          final l10n = AppL10n.of(tester.element(find.byType(TextField)));
          final analyze = find.widgetWithText(FilledButton, l10n.pasteAnalyse);
          await tester.ensureVisible(analyze);
          await tester.pumpAndSettle();
          final position = tester.getCenter(analyze);
          await tester.tap(analyze);
          await tester.pump(const Duration(milliseconds: 200));
          expect(visualParityPasteOutcomeEvents()[key], admissions + 1);
          if (key == 'manualPasteSaving') {
            expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed, isNull);
            expect(find.byType(CircularProgressIndicator), findsWidgets);
            await tester.tapAt(position);
            await tester.pump(const Duration(milliseconds: 80));
            expect(visualParityPasteOutcomeEvents()[key], admissions + 1);
          } else {
            expect(find.text(l10n.txnError), findsOneWidget);
            expect(find.textContaining('private_synthetic'), findsNothing);
            expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, input);
            expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed, isNotNull);
            await tester.ensureVisible(find.widgetWithText(FilledButton, l10n.pasteAnalyse));
            await tester.tap(find.widgetWithText(FilledButton, l10n.pasteAnalyse));
            await tester.pump(const Duration(milliseconds: 300));
            expect(visualParityPasteOutcomeEvents()[key], admissions + 2);
            await tester.pump(const Duration(seconds: 7));
          }
          expect(await _snapshot(db), before);
          expect(identical(container.read(ingestCapturedMessageUseCaseProvider), parent), isTrue);
          expect(tester.takeException(), isNull);
          // Actual close of modal then its presentation-only host restores the
          // original application scope, including its untouched ingest writer.
          Navigator.of(tester.element(find.byType(TextField))).pop();
          await tester.pumpAndSettle();
          expect(find.text('Open paste fixture'), findsOneWidget);
          expect(await _snapshot(db), before);
          expect(identical(container.read(ingestCapturedMessageUseCaseProvider), parent), isTrue);
        });
      }
    }
  }
}
