import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/repositories/drift_account_repository.dart';
import 'package:money_companion/data/repositories/drift_card_repository.dart';
import 'package:money_companion/domain/entities/account_entity.dart';
import 'package:money_companion/domain/entities/card_entity.dart';
import 'package:money_companion/engine/parser/card_network.dart';
import 'package:money_companion/features/cards/card_form_sheet.dart';
import 'package:money_companion/l10n/app_localizations.dart';

class _MemoryKeys implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'accent-test-memory';
  @override
  Future<String?> readStoredKey() async => 'accent-test-memory';
}

Future<(AppDatabase, AppL10n)> _open(WidgetTester tester,
    {required String language, CardEntity? existing}) async {
  tester.view.physicalSize = const Size(375, 667);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final db = (await tester.runAsync(() async {
    final loader = FontLoader('Vazirmatn');
    for (final weight in ['Regular', 'Medium', 'SemiBold', 'Bold']) {
      loader.addFont(rootBundle.load('assets/fonts/Vazirmatn-$weight.ttf'));
    }
    await loader.load();
    final db = await AppDatabase.open(
        executor: NativeDatabase.memory(), keyStore: _MemoryKeys());
    final now = DateTime(2026, 1, 15);
    await DriftAccountRepository(db).create(AccountEntity(
      id: 'own', name: 'Synthetic account', currency: 'EGP',
      type: AccountType.bank, isDefault: true, sortOrder: 0,
      createdAt: now, updatedAt: now,
    ));
    if (existing != null) await DriftCardRepository(db).create(existing);
    return db;
  }))!;
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(db.close);
  });
  await tester.pumpWidget(ProviderScope(overrides: [
    appDatabaseProvider.overrideWithValue(db),
    cardRepositoryProvider.overrideWithValue(DriftCardRepository(db)),
    accountsProvider.overrideWith((ref) async => const []),
  ], child: MaterialApp(
    theme: language == 'ar' ? AppTheme.dark : AppTheme.light,
    locale: Locale(language), supportedLocales: AppL10n.supportedLocales,
    localizationsDelegates: AppL10n.localizationsDelegates,
    home: Consumer(builder: (context, ref, _) => Scaffold(body: TextButton(
      onPressed: () => showCardForm(context, ref, accountId: 'own',
          card: existing, initialLast4: existing == null ? '4321' : null),
      child: const Text('Open card form')))),
  )));
  await tester.pumpAndSettle();
  final l10n = AppL10n.of(tester.element(find.text('Open card form')));
  await tester.tap(find.text('Open card form'));
  await tester.pumpAndSettle();
  return (db, l10n);
}

Future<void> _showAccent(WidgetTester tester, Finder choice) async {
  final vertical = find.descendant(of: find.byType(SingleChildScrollView).first,
      matching: find.byType(Scrollable)).first;
  await tester.scrollUntilVisible(choice, 160, scrollable: vertical);
  await tester.pumpAndSettle();
}

Future<void> _save(WidgetTester tester, AppL10n l10n, {bool edit = false}) async {
  final save = find.widgetWithText(FilledButton, edit ? l10n.txdSave : l10n.txnAdd);
  final vertical = find.descendant(of: find.byType(SingleChildScrollView).first,
      matching: find.byType(Scrollable)).first;
  await tester.scrollUntilVisible(save, 160, scrollable: vertical);
  await tester.pumpAndSettle();
  expect(save.hitTestable(), findsOneWidget);
  await tester.tap(save);
  await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
  await tester.pumpAndSettle();
}

void main() {
  const choices = [
    ('#F59E0B', 'Amber', 'كهرماني'), ('#EF4444', 'Red', 'أحمر'),
    ('#EC4899', 'Pink', 'وردي'), ('#8B5CF6', 'Purple', 'بنفسجي'),
    ('#3B82F6', 'Blue', 'أزرق'), ('#06B6D4', 'Cyan', 'سماوي'),
    ('#10B981', 'Emerald', 'زمردي'), ('#84CC16', 'Lime', 'أخضر ليموني'),
    ('#F97316', 'Orange', 'برتقالي'), ('#14B8A6', 'Teal', 'فيروزي'),
  ];
  for (final language in ['en', 'ar']) {
    testWidgets('accent choices expose names and 48px targets and save exact red in $language',
        (tester) async {
      final semantics = tester.ensureSemantics();
      try {
      final (db, l10n) = await _open(tester, language: language);
      final none = find.byKey(const ValueKey('card-accent-none'));
      await _showAccent(tester, none);
      final noneNode = tester.getSemantics(none);
      expect(noneNode.label, language == 'ar' ? 'بدون لون مميّز' : 'No accent colour');
      expect(noneNode.hasFlag(SemanticsFlag.isSelected), isTrue);
      expect(tester.getSize(none), const Size(48, 48));
      final horizontal = find.byWidget(tester.widget<Scrollable>(find.descendant(of: find.ancestor(
          of: none, matching: find.byType(ListView)).first,
          matching: find.byType(Scrollable))));
      for (final choice in choices) {
        final option = find.byKey(ValueKey('card-accent-${choice.$1}'));
        await tester.scrollUntilVisible(option, 48, scrollable: horizontal);
        await tester.pumpAndSettle();
        final node = tester.getSemantics(option);
        expect(node.label, language == 'ar' ? choice.$3 : choice.$2);
        expect(node.hasFlag(SemanticsFlag.isButton), isTrue);
        expect(node.hasFlag(SemanticsFlag.isEnabled), isTrue);
        expect(node.hasFlag(SemanticsFlag.isSelected), isFalse);
        expect(tester.getSize(option), const Size(48, 48));
        expect(tester.getSize(find.descendant(of: option,
            matching: find.byType(Container))), const Size(34, 34));
        expect(node.childrenCount, 0,
            reason: 'decorative check and ban icons must not duplicate the option label');
      }
      final red = find.byKey(const ValueKey('card-accent-#EF4444'));
      await tester.scrollUntilVisible(red, -48, scrollable: horizontal);
      await tester.pumpAndSettle();
      expect(red.hitTestable(), findsOneWidget);
      await tester.tap(red);
      await tester.pump();
      expect(tester.getSemantics(red).hasFlag(SemanticsFlag.isSelected), isTrue);
      await tester.showKeyboard(find.byType(TextField).last);
      tester.view.viewInsets = const FakeViewPadding(bottom: 260);
      await tester.pumpAndSettle();
      await _save(tester, l10n);
      final cards = (await tester.runAsync(() => DriftCardRepository(db).getAll()))!;
      expect(cards.single.accentHex, '#EF4444');
      expect(cards.single.last4, '4321');
      expect(cards.single.accountId, 'own');
      expect(tester.takeException(), isNull);
      } finally {
        semantics.dispose();
      }
    });
  }

  testWidgets('untouched Save preserves a legacy custom accent and card metadata',
      (tester) async {
    final now = DateTime(2026, 1, 15);
    final existing = CardEntity(id: 'legacy', accountId: 'own', last4: '1234',
        network: CardNetwork.visa, source: CardSource.auto, nickname: 'Legacy card',
        colorTheme: 'plum', accentHex: '#AABBCC', createdAt: now, updatedAt: now);
    final (db, l10n) = await _open(tester, language: 'en', existing: existing);
    final before = (await tester.runAsync(
        () => DriftCardRepository(db).getById(existing.id)))!;
    await _save(tester, l10n, edit: true);
    final stored = (await tester.runAsync(
        () => DriftCardRepository(db).getById(existing.id)))!;
    expect(stored.accentHex, existing.accentHex);
    expect(stored.id, existing.id);
    expect(stored.accountId, existing.accountId);
    expect(stored.last4, existing.last4);
    expect(stored.network, existing.network);
    expect(stored.source, existing.source);
    expect(stored.nickname, existing.nickname);
    expect(stored.colorTheme, existing.colorTheme);
    expect(stored.createdAt, before.createdAt);
    expect(tester.takeException(), isNull);
  });
}
