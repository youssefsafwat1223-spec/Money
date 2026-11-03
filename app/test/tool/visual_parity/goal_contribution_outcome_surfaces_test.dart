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
import 'package:money_companion/features/goals/goal_details_screen.dart';
import 'package:money_companion/features/goals/goals_providers.dart';
import 'package:money_companion/l10n/app_localizations.dart';
import '../../../tool/visual_parity/goal_contribution_outcome_surfaces.dart';

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
  for (final key in visualParityGoalContributionOutcomeKeys) {
    for (final language in ['ar', 'en']) {
      for (final dark in [false, true]) {
        testWidgets('$key $language dark$dark actual contribution public form',
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
          final parentRepo = parent.read(goalRepositoryProvider);
          final beforeParent = await tester.runAsync(() => snapshot(parentDb));
          final old = visualParityGoalContributionOutcomeEvents()[key] ?? 0;
          final closed =
              visualParityGoalContributionOutcomeEvents()['${key}Closed'] ?? 0;
          final forbidden = visualParityGoalContributionOutcomeEvents()[
                  'goalContributionForbiddenWrite'] ??
              0;
          final badInput = visualParityGoalContributionOutcomeEvents()[
                  'goalContributionForbiddenInput'] ??
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
                                  openVisualParityGoalContributionOutcome(
                                      context, ref, key));
                            },
                            child: const Text('Open goal contribution')));
                  }))));
          await tester.tap(find.text('Open goal contribution'));
          expect(await opening, isTrue);
          await tester.pumpAndSettle();
          final details = find.byType(GoalDetailsScreen);
          final detailContext = tester.element(details);
          final child = ProviderScope.containerOf(detailContext);
          final childDb = child.read(appDatabaseProvider);
          final detail = await tester.runAsync(() =>
              child.read(goalDetailsProvider('qa-contribution-goal').future));
          expect(detail!.goal.currency, 'KWD');
          expect(detail.goal.savedMoney.minorUnits, 12345);
          expect(detail.contributions, isEmpty);
          final beforeChild = await tester.runAsync(() => snapshot(childDb));
          final l10n = AppL10n.of(opener);
          await tester.tap(find.text(l10n.gdAddToGoal).last);
          await tester.pumpAndSettle();
          final input = find.byType(TextField).first;
          final sheetNavigator = Navigator.of(tester.element(input));
          await tester.enterText(
              input,
              key.endsWith('Invalid')
                  ? '1.2345'
                  : language == 'ar'
                      ? '١٫٢٥٠'
                      : '1.250');
          tester.testTextInput.hide();
          await tester.pumpAndSettle();
          final save = find.byWidgetPredicate((w) =>
              w is FilledButton &&
              find
                  .descendant(
                      of: find.byWidget(w),
                      matching: find.text(l10n.gdSaveContribution))
                  .evaluate()
                  .isNotEmpty);
          // Keep the widget identity stable while its label becomes a spinner.
          final saveElement = tester.element(save);
          final saveWidget = saveElement.widget;
          await tester.ensureVisible(save);
          await tester.pumpAndSettle();
          await tester.tap(save);
          await tester.runAsync(() async =>
              Future<void>.delayed(const Duration(milliseconds: 120)));
          await tester.pump(const Duration(milliseconds: 300));
          if (key.endsWith('Invalid')) {
            expect(find.text(l10n.bfInvalidAmount), findsOneWidget);
            expect(visualParityGoalContributionOutcomeEvents()[key] ?? 0, old);
          } else {
            expect(visualParityGoalContributionOutcomeEvents()[key], old + 1);
            if (key.endsWith('Saving')) {
              expect((saveElement.widget as FilledButton).onPressed, isNull);
              expect(find.byType(CircularProgressIndicator), findsWidgets);
              await tester.tap(
                  find.byWidgetPredicate(
                      (w) => identical(w, saveElement.widget)),
                  warnIfMissed: false);
              await tester.pump();
              expect(visualParityGoalContributionOutcomeEvents()[key], old + 1);
            } else {
              expect(find.text(l10n.gdSaveFailed), findsOneWidget);
              final retry =
                  find.widgetWithText(FilledButton, l10n.gdSaveContribution);
              await tester.tap(retry);
              await tester.runAsync(() async =>
                  Future<void>.delayed(const Duration(milliseconds: 120)));
              await tester.pump(const Duration(milliseconds: 300));
              expect(visualParityGoalContributionOutcomeEvents()[key], old + 2);
            }
          }
          expect(saveWidget, isA<FilledButton>());
          expect(await tester.runAsync(() => snapshot(childDb)), beforeChild);
          expect(await tester.runAsync(() => snapshot(parentDb)), beforeParent);
          expect(identical(parent.read(goalRepositoryProvider), parentRepo),
              isTrue);
          expect(
              visualParityGoalContributionOutcomeEvents()[
                      'goalContributionForbiddenWrite'] ??
                  0,
              forbidden);
          expect(
              visualParityGoalContributionOutcomeEvents()[
                      'goalContributionForbiddenInput'] ??
                  0,
              badInput);
          await tester.pump(const Duration(seconds: 7));
          expect(tester.takeException(), isNull);
          sheetNavigator.pop();
          await tester.pumpAndSettle();
          expect(details, findsOneWidget);
          Navigator.of(tester.element(details), rootNavigator: true).pop();
          await tester.pumpAndSettle();
          for (var turn = 0;
              turn < 20 &&
                  (visualParityGoalContributionOutcomeEvents()[
                              '${key}Closed'] ??
                          0) ==
                      closed;
              turn++) {
            await tester.runAsync(() async =>
                Future<void>.delayed(const Duration(milliseconds: 30)));
            await tester.pumpAndSettle();
          }
          expect(visualParityGoalContributionOutcomeEvents()['${key}Closed'],
              closed + 1);
          expect(find.text('Open goal contribution'), findsOneWidget);
          expect(await tester.runAsync(() => snapshot(parentDb)), beforeParent);
          expect(tester.takeException(), isNull);
        });
      }
    }
  }
  testWidgets('unknown goal contribution key cannot read providers',
      (tester) async {
    final before =
        Map<String, int>.of(visualParityGoalContributionOutcomeEvents());
    Future<bool?>? opening;
    await tester.pumpWidget(ProviderScope(
        child: MaterialApp(
            home: Consumer(
                builder: (context, ref, _) => Scaffold(
                    body: TextButton(
                        onPressed: () {
                          opening = tester.runAsync(() =>
                              openVisualParityGoalContributionOutcome(
                                  context, ref, 'unknown'));
                        },
                        child: const Text('Unknown contribution')))))));
    await tester.tap(find.text('Unknown contribution'));
    expect(await opening, isFalse);
    expect(visualParityGoalContributionOutcomeEvents(), before);
    expect(tester.takeException(), isNull);
  });
  testWidgets('file-backed parent cannot open goal contribution fixture',
      (tester) async {
    late Directory directory;
    late AppDatabase db;
    await tester.runAsync(() async {
      directory = await Directory.systemTemp.createTemp('qirsh-contribution-');
      db = await AppDatabase.open(
          executor: NativeDatabase(File('${directory.path}/guard.sqlite')),
          keyStore: _Keys());
    });
    addTearDown(() async {
      await db.close();
      await directory.delete(recursive: true);
    });
    final before = await tester.runAsync(() => snapshot(db));
    final events =
        Map<String, int>.of(visualParityGoalContributionOutcomeEvents());
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
                              await openVisualParityGoalContributionOutcome(
                                  context, ref, 'goalContributionError');
                            } catch (error) {
                              failure = error;
                            }
                          });
                        },
                        child: const Text('File contribution')))))));
    await tester.tap(find.text('File contribution'));
    await opening;
    expect(failure, isA<StateError>());
    expect(visualParityGoalContributionOutcomeEvents(), events);
    expect(await tester.runAsync(() => snapshot(db)), before);
    expect(find.text('File contribution'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
