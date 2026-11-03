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
import 'package:money_companion/features/plans/plans_screen.dart';
import 'package:money_companion/features/plans/plans_providers.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/l10n/app_localizations.dart';

import '../../../tool/visual_parity/plan_delete_outcome_surfaces.dart';

class _Keys implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'card-outcome-test-memory';
  @override
  Future<String?> readStoredKey() async => 'card-outcome-test-memory';
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
  for (final key in visualParityPlanDeleteOutcomeKeys) {
    for (final language in ['ar', 'en']) {
      for (final dark in [false, true]) {
        testWidgets('$key actual Plans list delete $language dark$dark',
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
              for (final weight in ['Regular', 'Medium', 'SemiBold', 'Bold']) {
                font.addFont(
                    rootBundle.load('assets/fonts/$family-$weight.ttf'));
              }
              await font.load();
            }
            parentDb = await AppDatabase.open(
                executor: NativeDatabase.memory(), keyStore: _Keys());
          });
          final parent = ProviderContainer(
              overrides: [appDatabaseProvider.overrideWithValue(parentDb)]);
          addTearDown(() async {
            final close = closeVisualParityPlanDeleteOutcome();
            await tester.pumpAndSettle();
            await tester.runAsync(() => close);
            parent.dispose();
            await parentDb.close();
          });
          final beforeParent = await tester.runAsync(() => _snapshot(parentDb));
          final parentRepo = parent.read(planRepositoryProvider);
          final events = visualParityPlanDeleteOutcomeEvents();
          int delta(String suffix) =>
              (visualParityPlanDeleteOutcomeEvents()['$key$suffix'] ?? 0) -
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
                                visualParityPlanDeleteOutcomeOverlay,
                            builder: (_, overlay, __) =>
                                overlay ?? const SizedBox.shrink())
                      ]),
                  home: Consumer(
                      builder: (context, ref, _) => Scaffold(
                          body: TextButton(
                              onPressed: () {
                                opening = tester.runAsync(() =>
                                    openVisualParityPlanDeleteOutcome(
                                        context, ref, key));
                              },
                              child: const Text('Original router')))))));
          final rootState = root.currentState;
          final original = tester.element(find.text('Original router'));
          await tester.tap(find.text('Original router'));
          expect(await opening, isTrue);
          await tester.pumpAndSettle();
          await _io(tester);
          final screen = find.byType(PlansScreen);
          final screenContext = tester.element(screen);
          final ownNavigator = Navigator.of(screenContext);
          expect(Navigator.of(screenContext, rootNavigator: true),
              same(ownNavigator));
          expect(ownNavigator, isNot(same(rootState)));
          expect(Navigator.of(visualParityPlanDeleteOutcomeInspectionContext!),
              same(ownNavigator));
          final child = ProviderScope.containerOf(screenContext);
          final childDb = child.read(appDatabaseProvider);
          final repo = child.read(planRepositoryProvider);
          final actual =
              await tester.runAsync(() => repo.getById('qa-plan-delete-plan'));
          expect(actual!.budgetAmountMoney.minorUnits, 123450);
          expect(actual.currency, 'KWD');
          final progress = await tester
              .runAsync(() => child.read(plansWithSpentProvider.future));
          expect(progress!.single.plan.id, actual.id);
          expect(progress.single.spent.minorUnits, 0);
          final beforeChild = await tester.runAsync(() => _snapshot(childDb));
          final l10n = AppL10n.of(screenContext);
          final options = find.byTooltip(l10n.plPlanOptions);
          Future<void> confirm({required bool yes}) async {
            await tester.ensureVisible(options);
            await tester.pumpAndSettle();
            await tester.tap(options);
            await tester.pumpAndSettle();
            // Real public action-list control, then real confirmation dialog.
            await tester.tap(find.widgetWithText(ListTile, l10n.setDelete));
            await tester.pumpAndSettle();
            expect(find.byType(GlassAlertDialog), findsOneWidget);
            final action = find.widgetWithText(
                TextButton, yes ? l10n.setDelete : l10n.commonCancel);
            expect(Navigator.of(tester.element(action)), same(ownNavigator));
            await tester.tap(action);
            await _io(tester);
          }

          await confirm(yes: false);
          expect(visualParityPlanDeleteOutcomeEvents()[key] ?? 0,
              events[key] ?? 0);
          expect(await tester.runAsync(() => _snapshot(childDb)), beforeChild);
          await confirm(yes: true);
          expect(visualParityPlanDeleteOutcomeEvents()[key],
              (events[key] ?? 0) + 1);
          if (key == 'planDeleteProgress') {
            expect(find.byType(CircularProgressIndicator), findsOneWidget);
            expect(find.text(l10n.plDeleteFailed), findsNothing);
            // Actual progress barrier prevents physical access; no invented busy flag.
            expect(options.hitTestable(), findsNothing);
            final position = tester.getCenter(options);
            await tester.tapAt(position);
            await tester.pump();
            expect(visualParityPlanDeleteOutcomeEvents()[key],
                (events[key] ?? 0) + 1);
          } else {
            expect(find.byType(CircularProgressIndicator), findsNothing);
            expect(find.text(l10n.plDeleteFailed), findsOneWidget);
            expect(find.textContaining('private_plan_'), findsNothing);
            await tester.pump(const Duration(seconds: 5));
            await confirm(yes: true);
            expect(visualParityPlanDeleteOutcomeEvents()[key],
                (events[key] ?? 0) + 2);
          }
          expect(await tester.runAsync(() => _snapshot(childDb)), beforeChild);
          expect(
              await tester.runAsync(() => _snapshot(parentDb)), beforeParent);
          expect(parent.read(planRepositoryProvider), same(parentRepo));
          expect(root.currentState, same(rootState));
          expect(original.mounted, isTrue);
          expect((await tester.runAsync(() => repo.getById(actual.id)))!.name,
              actual.name);
          await tester.pump(const Duration(seconds: 5));
          final close = closeVisualParityPlanDeleteOutcome();
          expect(closeVisualParityPlanDeleteOutcome(), same(close));
          await tester.pump();
          expect(screenContext.mounted, isFalse,
              reason: 'Unmount public handler before held rejection');
          for (var i = 0; i < 25 && delta('Closed') == 0; i++) {
            await _io(tester);
            await tester.pumpAndSettle();
          }
          await tester.runAsync(() => close);
          expect(delta('Closed'), 1);
          expect(delta('AllSqlUnchanged'), 1);
          expect(delta('UnmountedBeforeCancel'), 1);
          if (key == 'planDeleteProgress') {
            expect(delta('Cancelled'), 1);
            expect(delta('Settled'), 1);
          }
          expect(
              visualParityPlanDeleteOutcomeEvents()[
                      'planDeleteForbiddenWrite'] ??
                  0,
              events['planDeleteForbiddenWrite'] ?? 0);
          expect(visualParityPlanDeleteOutcomeOverlay.value, isNull);
          expect(visualParityPlanDeleteOutcomeInspectionContext, isNull);
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
    testWidgets('$guard rejects plan fixture before owned allocation',
        (tester) async {
      Directory? directory;
      AppDatabase? db;
      if (guard == 'file') {
        await tester.runAsync(() async {
          directory =
              await Directory.systemTemp.createTemp('qirsh-card-guard-');
          db = await AppDatabase.open(
              executor: NativeDatabase(File('${directory!.path}/guard.sqlite')),
              keyStore: _Keys());
        });
      }
      final before =
          db == null ? null : await tester.runAsync(() => _snapshot(db!));
      final events = Map<String, int>.of(visualParityPlanDeleteOutcomeEvents());
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
                                    await openVisualParityPlanDeleteOutcome(
                                        context,
                                        ref,
                                        guard == 'unknown'
                                            ? 'unknown'
                                            : 'planDeleteError');
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
      expect(visualParityPlanDeleteOutcomeOverlay.value, isNull);
      expect(visualParityPlanDeleteOutcomeEvents(), events);
      if (db != null) {
        expect(await tester.runAsync(() => _snapshot(db!)), before);
      }
      expect(tester.takeException(), isNull);
    });
  }
}
