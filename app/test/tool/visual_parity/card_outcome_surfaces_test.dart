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
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/l10n/app_localizations.dart';

import '../../../tool/visual_parity/card_outcome_surfaces.dart';

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
  for (final key in visualParityCardOutcomeKeys) {
    for (final language in ['ar', 'en']) {
      for (final dark in [false, true]) {
        testWidgets('$key actual sibling-root card form $language dark$dark',
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
              final loader = FontLoader(family);
              for (final weight in ['Regular', 'Medium', 'SemiBold', 'Bold']) {
                loader.addFont(
                    rootBundle.load('assets/fonts/$family-$weight.ttf'));
              }
              await loader.load();
            }
            parentDb = await AppDatabase.open(
                executor: NativeDatabase.memory(), keyStore: _Keys());
          });
          final parent = ProviderContainer(
              overrides: [appDatabaseProvider.overrideWithValue(parentDb)]);
          addTearDown(() async {
            final closing = closeVisualParityCardOutcome();
            await tester.pumpAndSettle();
            await tester.runAsync(() => closing);
            parent.dispose();
            await parentDb.close();
          });
          final parentRepository = parent.read(cardRepositoryProvider);
          final parentBefore = await tester.runAsync(() => _snapshot(parentDb));
          final originalNavigator = GlobalKey<NavigatorState>();
          Future<bool?>? opening;
          await tester.pumpWidget(UncontrolledProviderScope(
              container: parent,
              child: MaterialApp(
                  navigatorKey: originalNavigator,
                  theme: dark ? AppTheme.dark : AppTheme.light,
                  locale: Locale(language),
                  supportedLocales: AppL10n.supportedLocales,
                  localizationsDelegates: AppL10n.localizationsDelegates,
                  builder: (context, child) => Stack(
                        fit: StackFit.expand,
                        children: [
                          child!,
                          ValueListenableBuilder<Widget?>(
                              valueListenable: visualParityCardOutcomeOverlay,
                              builder: (_, overlay, __) =>
                                  overlay ?? const SizedBox.shrink()),
                        ],
                      ),
                  home: Consumer(builder: (context, ref, _) {
                    return Scaffold(
                        body: TextButton(
                            onPressed: () {
                              opening = tester.runAsync(() =>
                                  openVisualParityCardOutcome(
                                      context, ref, key));
                            },
                            child: const Text('Original router page')));
                  }))));
          final originalState = originalNavigator.currentState;
          final originalElement =
              tester.element(find.text('Original router page'));
          final admissions = visualParityCardOutcomeEvents()[key] ?? 0;
          final closed = visualParityCardOutcomeEvents()['${key}Closed'] ?? 0;
          final forbidden =
              visualParityCardOutcomeEvents()['cardOutcomeForbiddenWrite'] ?? 0;
          await tester.tap(find.text('Original router page'));
          expect(await opening, isTrue);
          await tester.pumpAndSettle();
          await _io(tester);
          final field = find.byType(TextField).first;
          final formContext = tester.element(field);
          final owned = Navigator.of(formContext);
          expect(Navigator.of(formContext, rootNavigator: true), same(owned));
          expect(owned, isNot(same(originalState)));
          expect(visualParityCardOutcomeInspectionContext, isNotNull);
          expect(Navigator.of(visualParityCardOutcomeInspectionContext!),
              same(owned));
          expect(originalNavigator.currentState, same(originalState));
          expect(originalElement.mounted, isTrue);
          final child = ProviderScope.containerOf(formContext);
          final childDb = child.read(appDatabaseProvider);
          expect(childDb, isNot(same(parentDb)));
          final repository = child.read(cardRepositoryProvider);
          final actualCard = await tester
              .runAsync(() => repository.getById('qa-card-outcome-card'));
          expect(actualCard!.last4, '4521');
          expect(actualCard.accountId, 'qa-card-outcome-account');
          expect(actualCard.nickname, 'QA card');
          expect((await tester.runAsync(() => repository.getAll()))!,
              hasLength(1));
          final childBefore = await tester.runAsync(() => _snapshot(childDb));
          final l10n = AppL10n.of(formContext);
          final saving = key.startsWith('cardFormSav');
          final busy = key.endsWith('Saving') || key.endsWith('Deleting');
          final save = find.widgetWithText(FilledButton, l10n.txdSave);
          final delete = find.widgetWithText(TextButton, l10n.cfDeleteCard);
          Future<void> deleteDialog({required bool confirm}) async {
            await tester.ensureVisible(delete);
            await tester.pumpAndSettle();
            await tester.tap(delete);
            await tester.pumpAndSettle();
            expect(find.byType(GlassAlertDialog), findsOneWidget);
            final action = find.widgetWithText(
                TextButton, confirm ? l10n.setDelete : l10n.commonCancel);
            final dialogContext = tester.element(action);
            expect(Navigator.of(dialogContext), same(owned));
            expect(
                Navigator.of(dialogContext, rootNavigator: true), same(owned));
            await tester.tap(action);
            await tester.pump(const Duration(milliseconds: 350));
            await _io(tester);
          }

          if (saving) {
            await tester.enterText(field, 'QA revised card');
            tester.testTextInput.hide();
            await tester.pumpAndSettle();
            await tester.ensureVisible(save);
            await tester.pumpAndSettle();
            await tester.tap(save);
            await _io(tester);
          } else {
            await deleteDialog(confirm: false);
            expect(find.byType(GlassAlertDialog), findsNothing);
            expect(visualParityCardOutcomeEvents()[key] ?? 0, admissions);
            expect(
                await tester.runAsync(() => _snapshot(childDb)), childBefore);
            expect(visualParityCardOutcomeOverlay.value, isNotNull);
            await deleteDialog(confirm: true);
          }
          expect(visualParityCardOutcomeEvents()[key], admissions + 1);
          expect(originalElement.mounted, isTrue);
          expect(originalNavigator.currentState, same(originalState));
          if (busy) {
            final actualSave = find.byType(FilledButton);
            expect(tester.widget<FilledButton>(actualSave).onPressed, isNull);
            expect(tester.widget<TextButton>(delete).onPressed, isNull);
            for (final input
                in tester.widgetList<TextField>(find.byType(TextField))) {
              expect(input.enabled, isFalse);
            }
            expect(find.byType(CircularProgressIndicator), findsWidgets);
            final accent = tester.widget<Semantics>(
                find.byKey(const ValueKey('card-accent-none')));
            expect(accent.properties.enabled, isFalse);
            await tester.tap(actualSave, warnIfMissed: false);
            await tester.tap(delete, warnIfMissed: false);
            await tester.pump();
            expect(visualParityCardOutcomeEvents()[key], admissions + 1);
            expect(find.byType(GlassAlertDialog), findsNothing);
          } else {
            expect(find.text(saving ? l10n.cfSaveFailed : l10n.cfDeleteFailed),
                findsOneWidget);
            expect(find.textContaining('private_card_'), findsNothing);
            if (saving) {
              await tester.tap(save);
              await _io(tester);
            } else {
              await deleteDialog(confirm: true);
            }
            expect(visualParityCardOutcomeEvents()[key], admissions + 2);
          }
          expect(await tester.runAsync(() => _snapshot(childDb)), childBefore);
          expect(
              await tester.runAsync(() => _snapshot(parentDb)), parentBefore);
          expect(
              identical(parent.read(cardRepositoryProvider), parentRepository),
              isTrue);
          expect(
              visualParityCardOutcomeEvents()['cardOutcomeForbiddenWrite'] ?? 0,
              forbidden);
          final stillThere = await tester
              .runAsync(() => repository.getById('qa-card-outcome-card'));
          expect(stillThere!.nickname, 'QA card');
          expect(stillThere.last4, '4521');
          await tester.pump(const Duration(seconds: 7));
          // Also exercise the future QA endpoint's close path while deleting.
          Future<void>? closing;
          if (key == 'cardFormSaveError' && language == 'en' && !dark) {
            await tester.ensureVisible(delete);
            await tester.pumpAndSettle();
            await tester.tap(delete);
            await tester.pumpAndSettle();
            expect(find.byType(GlassAlertDialog), findsOneWidget);
            expect(Navigator.of(tester.element(find.byType(GlassAlertDialog))),
                same(owned));
            closing = closeVisualParityCardOutcome();
            expect(closeVisualParityCardOutcome(), same(closing),
                reason: 'Closing a real dialog and sheet is idempotent');
          } else if (saving) {
            owned.pop();
          } else {
            closing = closeVisualParityCardOutcome();
          }
          await tester.pumpAndSettle();
          for (var turn = 0;
              turn < 20 &&
                  (visualParityCardOutcomeEvents()['${key}Closed'] ?? 0) ==
                      closed;
              turn++) {
            await _io(tester);
            await tester.pumpAndSettle();
          }
          if (closing != null) await tester.runAsync(() => closing!);
          expect(visualParityCardOutcomeEvents()['${key}Closed'], closed + 1);
          expect(visualParityCardOutcomeOverlay.value, isNull);
          expect(visualParityCardOutcomeInspectionContext, isNull);
          expect(originalElement.mounted, isTrue);
          expect(originalNavigator.currentState, same(originalState));
          expect(
              find.text('Original router page').hitTestable(), findsOneWidget);
          expect(
              await tester.runAsync(() => _snapshot(parentDb)), parentBefore);
          expect(tester.takeException(), isNull);
        });
      }
    }
  }

  for (final guard in ['unknown', 'file', 'readOnly']) {
    testWidgets('$guard rejects card fixture before owned allocation',
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
      final events = Map<String, int>.of(visualParityCardOutcomeEvents());
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
                                result = await openVisualParityCardOutcome(
                                    context,
                                    ref,
                                    guard == 'unknown'
                                        ? 'unknown'
                                        : 'cardFormSaveError');
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
      expect(visualParityCardOutcomeOverlay.value, isNull);
      expect(visualParityCardOutcomeEvents(), events);
      if (db != null) {
        expect(await tester.runAsync(() => _snapshot(db!)), before);
      }
      expect(tester.takeException(), isNull);
    });
  }
}
