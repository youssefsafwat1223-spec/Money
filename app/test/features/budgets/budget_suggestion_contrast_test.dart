import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/theme/app_colors.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/repositories/drift_account_repository.dart';
import 'package:money_companion/data/repositories/drift_transaction_repository.dart';
import 'package:money_companion/domain/entities/account_entity.dart';
import 'package:money_companion/domain/entities/transaction_entity.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/features/budgets/budget_form_screen.dart';
import 'package:money_companion/features/common/category_catalog.dart';
import 'package:money_companion/l10n/app_localizations.dart';

class _MemoryKeys implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'suggestion-contrast-memory';
  @override
  Future<String?> readStoredKey() async => 'suggestion-contrast-memory';
}

void main() {
  for (final lang in ['ar', 'en']) {
    for (final dark in [false, true]) {
      testWidgets('actual budget suggestion action contrast $lang dark$dark',
          (tester) async {
        tester.view.physicalSize = const Size(375, 667);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final db = await AppDatabase.open(
            executor: NativeDatabase.memory(), keyStore: _MemoryKeys());
        final now = DateTime.now();
        final accounts = DriftAccountRepository(db);
        await accounts.create(AccountEntity(
            id: 'qa-suggestion-account',
            name: 'QA account',
            currency: 'EGP',
            type: AccountType.bank,
            isDefault: true,
            sortOrder: 0,
            createdAt: now,
            updatedAt: now,
            initialBalanceMoney: Money.zero('EGP'),
            currentBalanceMoney: Money.zero('EGP')));
        final transactions = DriftTransactionRepository(db);
        await transactions.saveTransaction(
            transaction: TransactionEntity(
                id: 'qa-suggestion-expense',
                accountId: 'qa-suggestion-account',
                amountMoney: Money(12345, 'EGP'),
                currency: 'EGP',
                type: TransactionTypeEntity.payment,
                source: TransactionSourceEntity.card,
                occurredAt: now.subtract(const Duration(days: 1)),
                rawMerchant: 'QA groceries',
                rawMessage: 'Synthetic presentation fixture',
                parseConfidence: 1,
                status: TransactionStatus.confirmed,
                createdAt: now,
                updatedAt: now),
            categoryKey: 'groceries');
        final before = (await db
                .customSelect('SELECT * FROM transactions ORDER BY id')
                .get())
            .map((r) => r.data)
            .toList();
        await tester.pumpWidget(ProviderScope(
            overrides: [
              appDatabaseProvider.overrideWithValue(db),
              categoryCatalogProvider.overrideWith(
                  (ref) async => CategoryCatalog([], languageCode: lang))
            ],
            child: MaterialApp(
                theme: dark ? AppTheme.dark : AppTheme.light,
                locale: Locale(lang),
                supportedLocales: AppL10n.supportedLocales,
                localizationsDelegates: AppL10n.localizationsDelegates,
                home: Builder(
                    builder: (context) => Scaffold(
                        body: TextButton(
                            onPressed: () =>
                                BudgetFormScreen.showSheet(context),
                            child: const Text('Open')))))));
        await tester.runAsync(
            () async => Future<void>.delayed(const Duration(milliseconds: 80)));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Open'));
        for (var i = 0; i < 5; i++) {
          await tester.runAsync(() async =>
              Future<void>.delayed(const Duration(milliseconds: 40)));
          await tester.pump(const Duration(milliseconds: 100));
        }
        await tester.pumpAndSettle();
        final l10n = lookupAppL10n(Locale(lang));
        final label = find.text(l10n.bfsUseIt);
        await tester.scrollUntilVisible(label, 240, scrollable: find.byType(Scrollable).first);
        await tester.pumpAndSettle();
        expect(label.hitTestable(), findsOneWidget);
        expect(find.text(l10n.bfsSuggestion(l10n.bfsPeriodMonthly, '130.00')),
            findsOneWidget);
        final colors = tester.element(label).colors;
        final background = Color.alphaBlend(
            colors.primary.withValues(alpha: .08), colors.surface);
        final foreground =
            tester.renderObject<RenderParagraph>(label).text.style!.color!;
        final a = foreground.computeLuminance();
        final b = background.computeLuminance();
        final contrast = ((a > b ? a : b) + .05) / ((a < b ? a : b) + .05);
        await tester.tap(label);
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(find.byType(TextFormField), -240, scrollable: find.byType(Scrollable).first);
        expect(
            tester
                .widget<TextFormField>(find.byType(TextFormField).first)
                .controller!
                .text,
            '130.00');
        expect((await db.customSelect('SELECT * FROM budgets').get()), isEmpty);
        expect(
            (await db
                    .customSelect('SELECT * FROM transactions ORDER BY id')
                    .get())
                .map((r) => r.data)
                .toList(),
            before);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        await db.close();
        expect(contrast, greaterThanOrEqualTo(4.5),
            reason:
                'Actual rendered Use-it paragraph over actual suggestion card fill must meet text contrast');
      });
    }
  }
}
