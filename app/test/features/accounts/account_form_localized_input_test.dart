import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/data/catalog/catalog_daos.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/repositories/drift_account_repository.dart';
import 'package:money_companion/domain/entities/account_entity.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/features/accounts/account_form_sheet.dart';
import 'package:money_companion/l10n/app_localizations.dart';

class _Keys implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'memory';
  @override
  Future<String?> readStoredKey() async => 'memory';
}

void main() {
  late AppDatabase db;
  late DriftAccountRepository repository;
  late AccountEntity account;
  var savedCalls = 0;
  setUp(() async {
    db = await AppDatabase.open(executor: NativeDatabase.memory(), keyStore: _Keys());
    repository = DriftAccountRepository(db);
    final now = DateTime.utc(2026, 10, 1);
    account = AccountEntity(id: 'synthetic-input-account', name: 'Synthetic account',
      currency: 'KWD', type: AccountType.bank, isDefault: true, sortOrder: 0,
      createdAt: now, updatedAt: now, initialBalanceMoney: Money.zero('KWD'),
      currentBalanceMoney: Money.zero('KWD'));
    savedCalls = 0;
  });
  tearDown(() async => db.close());

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      if (!tester.binding.hasScheduledFrame) return;
    }
  }

  Future<AppL10n> open(WidgetTester tester, String language, {bool card = false}) async {
    tester.view.physicalSize = const Size(375, 667);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    if (card) account = account.copyWith(type: AccountType.card);
    await repository.create(account);
    await tester.pumpWidget(ProviderScope(overrides: [
      appDatabaseProvider.overrideWithValue(db),
      accountRepositoryProvider.overrideWithValue(repository),
      accountsProvider.overrideWith((ref) async => [account]),
      accountHasTransactionsProvider.overrideWith((ref, id) async => false),
      activeCurrenciesProvider.overrideWith((ref) async => [RemoteCurrency(
        code: 'KWD', nameAr: 'دينار', nameEn: 'KWD', symbol: 'KWD',
        decimalPlaces: 3, countryCodes: const [], isActive: true,
        isDeleted: false, updatedAt: DateTime.utc(2026))]),
    ], child: MaterialApp(theme: language == 'ar' ? AppTheme.dark : AppTheme.light,
      locale: Locale(language), supportedLocales: AppL10n.supportedLocales,
      localizationsDelegates: AppL10n.localizationsDelegates,
      home: Scaffold(body: AccountFormPanel(account: account,
        onSaved: () => savedCalls++)),
    )));
    await settle(tester);
    return AppL10n.of(tester.element(find.byType(AccountFormPanel)));
  }

  Future<void> enterAndSave(WidgetTester tester, String label, String input) async {
    final field = find.widgetWithText(TextField, label);
    await tester.ensureVisible(field);
    await tester.enterText(field, input);
    expect(tester.widget<TextField>(field).controller!.text, input,
        reason: 'typed digits, separators and sign must reach the exact parser intact');
    tester.testTextInput.hide();
    await settle(tester);
    final save = find.byKey(const ValueKey('account-save-button'));
    await tester.ensureVisible(save);
    await tester.tap(save);
    await settle(tester);
  }

  for (final language in ['ar', 'en']) {
    for (final spec in [('١٢٫٣٤٥', 12345), ('12,345.678', 12345678), ('-١٢٫٣٤٥', -12345)]) {
      testWidgets('account raw localized opening balance ${spec.$1} saves exact Money in $language', (tester) async {
        final l10n = await open(tester, language);
        await enterAndSave(tester, l10n.afOpeningBalance, spec.$1);
        final saved = (await repository.getById(account.id))!;
        expect(savedCalls, 1);
        expect(saved.initialBalanceMoney, Money(spec.$2, 'KWD'));
        expect(saved.id, account.id);
        expect(saved.currency, account.currency);
        expect(saved.name, account.name);
        expect(await repository.getAll(), hasLength(1));
        expect(tester.takeException(), isNull);
      });
    }
    for (final input in ['1,23', '12.3456']) {
      testWidgets('account rejects raw ambiguous or overprecision $input without edits in $language', (tester) async {
        final l10n = await open(tester, language);
        await enterAndSave(tester, l10n.afOpeningBalance, input);
        expect(savedCalls, 0);
        expect((await repository.getById(account.id))!.initialBalanceMoney, account.initialBalanceMoney);
        expect(find.text(l10n.bfInvalidAmount), findsOneWidget);
        final field = find.widgetWithText(TextField, l10n.afOpeningBalance);
        expect(tester.widget<TextField>(field).controller!.text, input);
        expect(tester.takeException(), isNull);
        await tester.pump(const Duration(seconds: 4));
        await settle(tester);
      });
    }
    testWidgets('credit card due day accepts Arabic integer without losing its value in $language', (tester) async {
      final l10n = await open(tester, language, card: true);
      await enterAndSave(tester, l10n.afPaymentDay, '٢٥');
      expect(savedCalls, 1);
      expect((await repository.getById(account.id))!.paymentDueDay, 25);
      expect(tester.takeException(), isNull);
    });
    for (final input in ['-5', '12.5']) {
      testWidgets('credit card due day rejects $input instead of changing it in $language', (tester) async {
        final l10n = await open(tester, language, card: true);
        await enterAndSave(tester, l10n.afPaymentDay, input);
        expect(savedCalls, 0);
        expect((await repository.getById(account.id))!.paymentDueDay, isNull);
        expect(find.text(l10n.afPaymentDayRange), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pump(const Duration(seconds: 4));
        await settle(tester);
      });
    }
  }
}
