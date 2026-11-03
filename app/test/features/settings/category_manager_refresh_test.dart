import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/domain/entities/category_entity.dart';
import 'package:money_companion/domain/entities/engagement_entities.dart';
import 'package:money_companion/domain/entities/supporting_entities.dart';
import 'package:money_companion/domain/repositories/category_repository.dart';
import 'package:money_companion/features/settings/settings_providers.dart';
import 'package:money_companion/features/settings/settings_screen.dart';
import 'package:money_companion/l10n/app_localizations.dart';

// A stateful local repository boundary: writes actually change subsequent reads.
// The category catalog itself and every public Settings control stay production.
class _Categories implements CategoryRepository {
  final rows = <CategoryEntity>[
    const CategoryEntity(id: 'original', key: 'qa-original', nameAr: 'QA original',
        icon: 'shapes', color: '#9E9E9E', isIncome: false, sort: 42),
  ];
  final writes = <String>[];
  bool delayNextRead = false;
  Completer<List<CategoryEntity>>? pendingRead;
  @override
  Future<List<CategoryEntity>> getAll() async {
    if (delayNextRead) {
      delayNextRead = false;
      return (pendingRead = Completer<List<CategoryEntity>>()).future;
    }
    return List.of(rows);
  }
  @override
  Future<CategoryEntity> createCategory({required String nameAr,
      required String icon, required String color, required bool isIncome}) async {
    final created = CategoryEntity(id: 'created', key: 'qa-created',
        nameAr: nameAr, icon: icon, color: color, isIncome: isIncome, sort: 43);
    rows.add(created);
    writes.add('create');
    return created;
  }
  @override
  Future<CategoryEntity> updateCategory(CategoryEntity category) async {
    rows[rows.indexWhere((row) => row.id == category.id)] = category;
    writes.add('update');
    return category;
  }
  @override
  Future<void> deleteCategory(String id) async {
    rows.removeWhere((row) => row.id == id);
    writes.add('delete');
  }
}

Future<void> _reveal(WidgetTester tester, Finder finder) async {
  await tester.scrollUntilVisible(finder, 180,
      scrollable: find.byType(Scrollable).last);
  await tester.pumpAndSettle();
}

Future<AppL10n> _open(WidgetTester tester, _Categories repository,
    String language, bool dark) async {
  tester.view.physicalSize = const Size(375, 812);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  FlutterSecureStorage.setMockInitialValues({});
  await tester.runAsync(() async {
    final font = FontLoader('Vazirmatn');
    for (final weight in ['Regular', 'Medium', 'SemiBold', 'Bold']) {
      font.addFont(rootBundle.load('assets/fonts/Vazirmatn-$weight.ttf'));
    }
    await font.load();
  });
  await tester.pumpWidget(ProviderScope(overrides: [
    categoryRepositoryProvider.overrideWithValue(repository),
    userSettingsProvider.overrideWith((ref) async => UserSettingsEntity(
      id: 'settings', country: 'EG', currency: 'EGP', language: language,
      theme: dark ? 'dark' : 'light', inputMethod: 'manual', notificationsJson: '{}',
      privacyModeEnabled: false,
    )),
    notificationPreferencesProvider.overrideWith((ref) async =>
      const NotificationPreferences()),
    captureHealthStatusProvider.overrideWith((ref) async =>
      CaptureHealthStatus(lastCaptureAt: null, now: DateTime.utc(2026))),
    supportedCountriesProvider.overrideWith((ref) async => const []),
    activeCurrenciesProvider.overrideWith((ref) async => const []),
  ], child: MaterialApp(
    theme: dark ? AppTheme.dark : AppTheme.light,
    locale: Locale(language), supportedLocales: AppL10n.supportedLocales,
    localizationsDelegates: AppL10n.localizationsDelegates,
    home: const SettingsScreen(),
  )));
  await tester.pumpAndSettle();
  final l10n = AppL10n.of(tester.element(find.byType(SettingsScreen)));
  await tester.scrollUntilVisible(find.text(l10n.setCategories), 300,
      scrollable: find.byType(Scrollable).first);
  await tester.tap(find.text(l10n.setCategories));
  await tester.pumpAndSettle();
  expect(find.text('QA original'), findsOneWidget);
  return l10n;
}

void main() {
  for (final language in ['ar', 'en']) {
    for (final dark in [false, true]) {
      for (final operation in ['create', 'update', 'delete']) {
        testWidgets('open category manager refreshes $operation $language dark$dark without reopening', (tester) async {
          final repository = _Categories();
          final l10n = await _open(tester, repository, language, dark);
          if (operation == 'delete') {
            final row = find.ancestor(of: find.text('QA original'), matching: find.byType(ListTile));
            await tester.tap(find.descendant(of: row,
                matching: find.byTooltip(l10n.setDelete)));
            await tester.pumpAndSettle();
            await tester.tap(find.widgetWithText(TextButton, l10n.setDelete));
            await tester.pumpAndSettle();
            // Persistence assertions precede visible-state assertions.
            expect(repository.rows, isEmpty);
            expect(repository.writes, ['delete']);
            expect(find.text('QA original'), findsNothing);
          } else {
            if (operation == 'create') {
              await tester.tap(find.widgetWithText(FilledButton, l10n.setAddCategory));
            } else {
              final row = find.ancestor(of: find.text('QA original'), matching: find.byType(ListTile));
              await tester.tap(find.descendant(of: row,
                  matching: find.byTooltip(l10n.setEdit)));
            }
            await tester.pumpAndSettle();
            final name = operation == 'create' ? 'QA newly added' : 'QA renamed';
            await tester.enterText(find.byType(TextField), name);
            tester.testTextInput.hide();
            await tester.pumpAndSettle();
            final save = find.widgetWithText(FilledButton,
                operation == 'create' ? l10n.setAdd : l10n.setSaveChanges);
            await _reveal(tester, save);
            if (operation == 'create') repository.delayNextRead = true;
            await tester.tap(save);
            await tester.pumpAndSettle();
            expect(repository.writes, [operation]);
            expect(repository.rows.where((row) => row.nameAr == name), hasLength(1));
            if (operation == 'update') {
              expect(repository.rows.single.id, 'original');
              expect(repository.rows.single.key, 'qa-original');
              expect(repository.rows.single.sort, 42);
              expect(find.text('QA original'), findsNothing);
            }
            if (operation == 'create') {
              // A genuine pending repository reload retains the initial manager.
              expect(repository.pendingRead, isNotNull);
              expect(find.text('QA original'), findsOneWidget);
              expect(find.byType(CircularProgressIndicator), findsNothing);
              repository.pendingRead!.complete(List.of(repository.rows));
              await tester.pumpAndSettle();
            }
            expect(find.text(name), findsOneWidget);
          }
          // The original manager remains open; no full Settings/sheet reopen.
          expect(find.widgetWithText(FilledButton, l10n.setAddCategory), findsOneWidget);
          expect(find.byType(TextField), findsNothing);
          expect(tester.takeException(), isNull);
        });
      }
    }
  }
}
