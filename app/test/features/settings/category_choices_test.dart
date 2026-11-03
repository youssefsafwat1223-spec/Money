import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/domain/entities/category_entity.dart';
import 'package:money_companion/domain/entities/engagement_entities.dart';
import 'package:money_companion/domain/entities/supporting_entities.dart';
import 'package:money_companion/domain/repositories/category_repository.dart';
import 'package:money_companion/features/common/category_catalog.dart';
import 'package:money_companion/features/settings/settings_providers.dart';
import 'package:money_companion/features/settings/settings_screen.dart';
import 'package:money_companion/l10n/app_localizations.dart';

class _Categories implements CategoryRepository {
  _Categories(this.rows);
  final List<CategoryEntity> rows;
  CategoryEntity? saved;
  @override
  Future<List<CategoryEntity>> getAll() async => rows;
  @override
  Future<CategoryEntity> createCategory({required String nameAr,
      required String icon, required String color, required bool isIncome}) async {
    return saved = CategoryEntity(id: 'new', key: 'new', nameAr: nameAr,
        icon: icon, color: color, isIncome: isIncome, sort: 42);
  }
  @override
  Future<CategoryEntity> updateCategory(CategoryEntity category) async =>
      saved = category;
  @override
  Future<void> deleteCategory(String id) async {}
}

Future<AppL10n> _open(WidgetTester tester, _Categories repository,
    {required String language, bool edit = false}) async {
  tester.view.physicalSize = const Size(320, 720);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  FlutterSecureStorage.setMockInitialValues({});
  await tester.pumpWidget(ProviderScope(overrides: [
    categoryRepositoryProvider.overrideWithValue(repository),
    categoryCatalogProvider.overrideWith((ref) async =>
      CategoryCatalog(repository.rows, languageCode: language)),
    userSettingsProvider.overrideWith((ref) async => UserSettingsEntity(
      id: 'settings', country: 'EG', currency: 'EGP', language: language,
      theme: 'system', inputMethod: 'manual', notificationsJson: '{}',
      privacyModeEnabled: false,
    )),
    notificationPreferencesProvider.overrideWith((ref) async =>
      const NotificationPreferences()),
    captureHealthStatusProvider.overrideWith((ref) async =>
      CaptureHealthStatus(lastCaptureAt: null, now: DateTime.utc(2026))),
    supportedCountriesProvider.overrideWith((ref) async => const []),
    activeCurrenciesProvider.overrideWith((ref) async => const []),
  ], child: MaterialApp(
    theme: language == 'ar' ? AppTheme.dark : AppTheme.light,
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
  await tester.tap(edit ? find.byTooltip(l10n.setEdit).first
      : find.text(l10n.setAddCategory));
  await tester.pumpAndSettle();
  return l10n;
}

Future<void> _reveal(WidgetTester tester, Finder finder) async {
  await tester.scrollUntilVisible(finder, 180,
      scrollable: find.byType(Scrollable).last);
  await tester.pumpAndSettle();
}

void main() {
  for (final language in ['ar', 'en']) {
    testWidgets('category choices are visual and save exact values in $language',
        (tester) async {
      final repository = _Categories([]);
      final l10n = await _open(tester, repository, language: language);
      await tester.enterText(find.byType(TextField), 'Weekend');
      await tester.tap(find.byType(SwitchListTile).last);
      final icon = find.byKey(const ValueKey('category-icon-plane'));
      await _reveal(tester, icon);
      await tester.tap(icon);
      await tester.pump();
      expect(tester.widget<Semantics>(find.descendant(of: icon,
          matching: find.byType(Semantics)).first).properties.selected, isTrue);
      expect(find.byTooltip(l10n.setCategoryIconName('travel')), findsOneWidget);
      final colour = find.byKey(const ValueKey('category-colour-#00897B'));
      await _reveal(tester, colour);
      await tester.tap(colour);
      await tester.pump();
      expect(tester.widget<Semantics>(find.descendant(of: colour,
          matching: find.byType(Semantics)).first).properties.selected, isTrue);
      expect(find.byTooltip(l10n.setCategoryColourName('teal')), findsOneWidget);
      expect(find.text('plane'), findsNothing);
      expect(find.text('#00897B'), findsNothing);
      final add = find.widgetWithText(FilledButton, l10n.setAdd);
      await _reveal(tester, add);
      await tester.tap(add);
      await tester.pumpAndSettle();
      expect(repository.saved?.nameAr, 'Weekend');
      expect(repository.saved?.icon, 'plane');
      expect(repository.saved?.color, '#00897B');
      expect(repository.saved?.isIncome, isTrue);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('editing preserves custom icon colour and stable identity',
      (tester) async {
    const category = CategoryEntity(id: 'original', key: 'custom-identity',
        nameAr: 'Custom', icon: 'hotel', color: '#AABBCC',
        isIncome: false, sort: 117);
    final repository = _Categories([category]);
    final l10n = await _open(tester, repository, language: 'en', edit: true);
    expect(find.byKey(const ValueKey('category-icon-hotel')), findsOneWidget);
    final colour = find.byKey(const ValueKey('category-colour-#AABBCC'));
    await _reveal(tester, colour);
    expect(colour, findsOneWidget);
    final save = find.widgetWithText(FilledButton, l10n.setSaveChanges);
    await _reveal(tester, save);
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(repository.saved?.id, category.id);
    expect(repository.saved?.key, category.key);
    expect(repository.saved?.sort, category.sort);
    expect(repository.saved?.icon, category.icon);
    expect(repository.saved?.color, category.color);
    expect(repository.saved?.isIncome, category.isIncome);
    expect(tester.takeException(), isNull);
  });
}
