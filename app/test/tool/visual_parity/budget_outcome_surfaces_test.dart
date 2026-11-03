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
import 'package:money_companion/features/common/app_button.dart';
import 'package:money_companion/features/common/app_sheet_scaffold.dart';
import 'package:money_companion/l10n/app_localizations.dart';
import '../../../tool/visual_parity/budget_outcome_surfaces.dart';

class _Keys implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'budget-test-memory';
  @override
  Future<String?> readStoredKey() async => 'budget-test-memory';
}

Future<Map<String, Object>> snapshot(AppDatabase db) async {
  final tables = await db
      .customSelect(
          "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name")
      .get();
  return {
    for (final row in tables)
      row.read<String>('name'): (await db
              .customSelect(
                  'SELECT * FROM "${row.read<String>('name')}" ORDER BY rowid')
              .get())
          .map((r) => r.data)
          .toList()
  };
}

void main() {
  for (final key in visualParityBudgetOutcomeKeys) {
    for (final language in ['ar', 'en']) {
      for (final dark in [false, true]) {
        testWidgets(
            '$key $language dark$dark actual public before-write outcome',
            (tester) async {
          tester.view.physicalSize = const Size(375, 667);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          late AppDatabase parentDb;
          await tester.runAsync(() async {
            final font = FontLoader('Vazirmatn');
            for (final weight in ['Regular', 'Medium', 'SemiBold', 'Bold']) {
              font.addFont(
                  rootBundle.load('assets/fonts/Vazirmatn-$weight.ttf'));
            }
            await font.load();
            parentDb = await AppDatabase.open(
                executor: NativeDatabase.memory(), keyStore: _Keys());
          });
          final parent = ProviderContainer(
              overrides: [appDatabaseProvider.overrideWithValue(parentDb)]);
          addTearDown(() async {
            parent.dispose();
            await parentDb.close();
          });
          final parentRepository = parent.read(budgetRepositoryProvider);
          final beforeParent = await tester.runAsync(() => snapshot(parentDb));
          final old = visualParityBudgetOutcomeEvents()[key] ?? 0;
          final closed = visualParityBudgetOutcomeEvents()['${key}Closed'] ?? 0;
          final forbidden = visualParityBudgetOutcomeEvents()[
                  'budgetOutcomeForbiddenDelete'] ??
              0;
          Future<bool?>? opening;
          late BuildContext opener;
          await tester.pumpWidget(UncontrolledProviderScope(
              container: parent,
              child: MaterialApp(
                  theme: dark ? AppTheme.dark : AppTheme.light,
                  locale: Locale(language),
                  supportedLocales: AppL10n.supportedLocales,
                  localizationsDelegates: AppL10n.localizationsDelegates,
                  home: Consumer(builder: (context, ref, _) {
                    opener = context;
                    return Scaffold(
                        body: TextButton(
                            onPressed: () {
                              opening = tester.runAsync(() =>
                                  openVisualParityBudgetOutcome(
                                      context, ref, key));
                            },
                            child: const Text('Open budget fixture')));
                  }))));
          await tester.tap(find.text('Open budget fixture'));
          await opening;
          await tester.pumpAndSettle();
          final l10n = AppL10n.of(opener);
          final allocation = key.startsWith('allocate');
          final childContext = tester.element(allocation
              ? find.byType(AppSheetScaffold)
              : find.byType(TextFormField).first);
          final child = ProviderScope.containerOf(childContext);
          final childNavigator = Navigator.of(childContext);
          final childDb = child.read(appDatabaseProvider);
          expect(identical(childDb, parentDb), isFalse);
          final beforeChild = await tester.runAsync(() => snapshot(childDb));
          expect(
              await tester
                  .runAsync(() => child.read(goalRepositoryProvider).getAll()),
              isEmpty);
          Finder save;
          if (allocation) {
            final income = find.byType(TextField).first;
            await tester.enterText(income, '1000');
            tester.testTextInput.hide();
            await tester.pumpAndSettle();
            await tester.tap(find.text(l10n.aiSuggestSplit));
            await tester.pumpAndSettle();
            // Formula is actual public local allocation suggestion; creates no rows.
            expect(tester.widget<TextField>(income).controller!.text, '1000');
            final goalHint = find.text(l10n.aiCreateGoalHint);
            await tester.ensureVisible(goalHint);
            await tester.pumpAndSettle();
            expect(goalHint, findsOneWidget);
            save = find.byType(FilledButton).last;
          } else {
            save = find.byWidgetPredicate(
                (w) => w is AppPrimaryButton && w.label == l10n.bfsSaveBudget);
          }
          if (!allocation) {
            await tester.scrollUntilVisible(save, 240,
                scrollable: find.byType(Scrollable).first);
          } else {
            await tester.ensureVisible(save);
          }
          await tester.pumpAndSettle();
          await tester.tap(save);
          await tester.runAsync(() async =>
              Future<void>.delayed(const Duration(milliseconds: 120)));
          await tester.pump(const Duration(milliseconds: 400));
          expect(visualParityBudgetOutcomeEvents()[key], old + 1);
          if (key.endsWith('Saving')) {
            if (allocation) {
              expect(tester.widget<FilledButton>(save).onPressed, isNull);
              expect(find.text(l10n.aiSaving), findsOneWidget);
            } else {
              expect(tester.widget<AppPrimaryButton>(save).loading, isTrue);
            }
            await tester.tap(save, warnIfMissed: false);
            await tester.pump(const Duration(milliseconds: 200));
            expect(visualParityBudgetOutcomeEvents()[key], old + 1);
          } else {
            expect(find.text(l10n.bfSaveFailed), findsOneWidget);
            await tester.tap(save);
            await tester.runAsync(() async =>
                Future<void>.delayed(const Duration(milliseconds: 120)));
            await tester.pump(const Duration(milliseconds: 400));
            expect(visualParityBudgetOutcomeEvents()[key], old + 2);
            await tester.pump(const Duration(seconds: 7));
          }
          expect(await tester.runAsync(() => snapshot(childDb)), beforeChild);
          expect(await tester.runAsync(() => snapshot(parentDb)), beforeParent);
          expect(
              identical(
                  parent.read(budgetRepositoryProvider), parentRepository),
              isTrue);
          expect(
              visualParityBudgetOutcomeEvents()[
                      'budgetOutcomeForbiddenDelete'] ??
                  0,
              forbidden);
          expect(tester.takeException(), isNull);
          childNavigator.pop();
          await tester.pumpAndSettle();
          for (var turn = 0;
              turn < 20 &&
                  (visualParityBudgetOutcomeEvents()['${key}Closed'] ?? 0) ==
                      closed;
              turn++) {
            await tester.runAsync(() async =>
                Future<void>.delayed(const Duration(milliseconds: 30)));
            await tester.pumpAndSettle();
          }
          expect(visualParityBudgetOutcomeEvents()['${key}Closed'], closed + 1);
          expect(find.text('Open budget fixture'), findsOneWidget);
          expect(await tester.runAsync(() => snapshot(parentDb)), beforeParent);
          expect(tester.takeException(), isNull);
        });
      }
    }
  }
  testWidgets('unknown key cannot obtain a database or create a child',
      (tester) async {
    final before = Map<String, int>.of(visualParityBudgetOutcomeEvents());
    Future<bool?>? opening;
    await tester.pumpWidget(ProviderScope(
        child: MaterialApp(
            home: Consumer(
                builder: (context, ref, _) => Scaffold(
                    body: TextButton(
                        onPressed: () {
                          opening = tester.runAsync(() =>
                              openVisualParityBudgetOutcome(
                                  context, ref, 'unknown'));
                        },
                        child: const Text('Unknown fixture')))))));
    await tester.tap(find.text('Unknown fixture'));
    expect(await opening, isFalse);
    expect(visualParityBudgetOutcomeEvents(), before);
    expect(tester.takeException(), isNull);
  });
  testWidgets('file-backed parent is rejected before owned fixture creation',
      (tester) async {
    late Directory directory;
    late AppDatabase db;
    await tester.runAsync(() async {
      directory = await Directory.systemTemp.createTemp('qirsh-budget-guard-');
      db = await AppDatabase.open(
          executor: NativeDatabase(File('${directory.path}/guard.sqlite')),
          keyStore: _Keys());
    });
    addTearDown(() async {
      await db.close();
      await directory.delete(recursive: true);
    });
    final before = await tester.runAsync(() => snapshot(db));
    final events = Map<String, int>.of(visualParityBudgetOutcomeEvents());
    final parent = ProviderContainer(
        overrides: [appDatabaseProvider.overrideWithValue(db)]);
    addTearDown(parent.dispose);
    Future<void>? opening;
    Object? failure;
    await tester.pumpWidget(UncontrolledProviderScope(
        container: parent,
        child: MaterialApp(
            home: Consumer(
                builder: (context, ref, _) => Scaffold(
                    body: TextButton(
                        onPressed: () {
                          opening = tester.runAsync(() async {
                            try {
                              await openVisualParityBudgetOutcome(
                                  context, ref, 'budgetFormError');
                            } catch (error) {
                              failure = error;
                            }
                          });
                        },
                        child: const Text('File fixture')))))));
    await tester.tap(find.text('File fixture'));
    await opening;
    expect(failure, isA<StateError>());
    expect(visualParityBudgetOutcomeEvents(), events);
    expect(await tester.runAsync(() => snapshot(db)), before);
    expect(find.text('File fixture'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
