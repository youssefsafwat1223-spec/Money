import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/core/utils/currency.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/repositories/drift_account_repository.dart';
import 'package:money_companion/data/repositories/drift_bill_repository.dart';
import 'package:money_companion/data/repositories/drift_transaction_repository.dart';
import 'package:money_companion/domain/entities/account_entity.dart';
import 'package:money_companion/domain/entities/bill_entity.dart';
import 'package:money_companion/domain/entities/transaction_entity.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/domain/finance/money_format.dart';
import 'package:money_companion/features/transactions/transactions_providers.dart';
import 'package:money_companion/features/transactions/transactions_screen.dart';
import 'package:money_companion/l10n/app_localizations.dart';

class _MemoryKeys implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'activity-exact-display-memory';
  @override
  Future<String?> readStoredKey() async => 'activity-exact-display-memory';
}

Future<void> _settle(WidgetTester tester) async {
  await tester.runAsync(() async => Future<void>.delayed(const Duration(milliseconds: 100)));
  await tester.pumpAndSettle();
}

Future<void> _reveal(WidgetTester tester, Finder finder) async {
  await tester.scrollUntilVisible(finder, 160,
      scrollable: find.byType(Scrollable).last);
  await tester.pumpAndSettle();
}

void _expectCompleteAmount(WidgetTester tester, Finder finder) {
  expect(finder, findsOneWidget);
  final paragraph = tester.renderObject<RenderParagraph>(finder);
  expect(paragraph.didExceedMaxLines, isFalse,
      reason: 'Every canonical monetary glyph must be visible.');
  final bounds = tester.getRect(finder);
  expect(bounds.left, greaterThanOrEqualTo(0));
  expect(bounds.right, lessThanOrEqualTo(375));
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
        keyStore: _MemoryKeys(), initialLanguage: 'en');
  });
  tearDown(() async => db.close());

  for (final scope in ['subscription', 'suggestion', 'installment']) {
    for (final language in ['ar', 'en']) {
      for (final dark in [false, true]) {
        for (final minor in [12345, 9007199254740993]) {
          testWidgets('Activity Bills $scope KWD$minor $language dark$dark exact leaves do not write', (tester) async {
            tester.view.physicalSize = const Size(375, 812);
            tester.view.devicePixelRatio = 1;
            addTearDown(tester.view.reset);
            await tester.runAsync(() async {
              final fonts = FontLoader('Vazirmatn');
              for (final weight in ['Regular', 'Medium', 'SemiBold', 'Bold']) {
                fonts.addFont(rootBundle.load('assets/fonts/Vazirmatn-$weight.ttf'));
              }
              await fonts.load();
            });
            final now = DateTime.now().toUtc();
            Money amount(int delta) => Money(minor + delta, 'KWD');
            final accounts = DriftAccountRepository(db);
            await accounts.create(AccountEntity(id: 'qa-activity-kwd', name: 'QA KWD account',
                currency: 'KWD', type: AccountType.bank, isDefault: true, sortOrder: 0,
                initialBalanceMoney: Money.zero('KWD'), currentBalanceMoney: Money.zero('KWD'),
                createdAt: now, updatedAt: now));
            final bills = DriftBillRepository(db);
            await bills.save(BillEntity(id: 'qa-activity-sub', name: 'QA activity subscription',
                amountMoney: amount(0), currency: 'KWD', type: BillType.subscription,
                frequency: BillFrequency.monthly, nextDueDate: now.add(const Duration(days: 10)),
                reminderOn: false, isConfirmed: true, createdAt: now, accountId: 'qa-activity-kwd'));
            await bills.save(BillEntity(id: 'qa-activity-inst', name: 'QA activity installment',
                amountMoney: amount(2), totalPurchaseMoney: amount(21), manualPaidMoney: amount(20),
                currency: 'KWD', type: BillType.installment, frequency: BillFrequency.monthly,
                totalInstallments: 3, paidCount: 1,
                nextDueDate: now.add(const Duration(days: 11)), reminderOn: false,
                isConfirmed: true, createdAt: now, accountId: 'qa-activity-kwd'));
            final transactions = DriftTransactionRepository(db);
            for (var month = 1; month <= 3; month++) {
              await transactions.saveTransaction(transaction: TransactionEntity(
                  id: 'qa-activity-recurring-$month', amountMoney: amount(18), currency: 'KWD',
                  type: TransactionTypeEntity.payment, source: TransactionSourceEntity.card,
                  accountId: 'qa-activity-kwd', occurredAt: DateTime.utc(now.year, now.month - month, 15),
                  rawMerchant: 'QA activity recurring', rawMessage: 'Synthetic display-only activity recurrence',
                  parseConfidence: 1, status: TransactionStatus.confirmed,
                  createdAt: now, updatedAt: now), categoryKey: 'groceries');
            }
            final before = await _snapshot(db);
            final container = ProviderContainer(overrides: [
              appDatabaseProvider.overrideWithValue(db),
              baseCurrencyProvider.overrideWith((_) async => 'KWD'),
            ]);
            addTearDown(container.dispose);
            await tester.pumpWidget(UncontrolledProviderScope(container: container,
              child: MaterialApp(theme: dark ? AppTheme.dark : AppTheme.light,
                locale: Locale(language), supportedLocales: AppL10n.supportedLocales,
                localizationsDelegates: AppL10n.localizationsDelegates,
                home: const TransactionsScreen())));
            await _settle(tester);
            final l10n = AppL10n.of(tester.element(find.byType(TransactionsScreen)));
            final currency = Currency.label(tester.element(find.byType(TransactionsScreen)), 'KWD');
            final billsTab = find.text(l10n.txnTabBills);
            await tester.ensureVisible(billsTab);
            await tester.tap(billsTab);
            await _settle(tester);
            expect(container.read(transactionsPageTabProvider), 1);
            final actualView = container.read(billsViewProvider).requireValue;
            expect(actualView.suggestions.single.estimatedAmountMoney, amount(18));
            expect(actualView.suggestions.single.monthsSeen, 3);
            if (scope == 'subscription') {
              final value = find.text(formatMoney(amount(0)));
              await _reveal(tester, find.text('QA activity subscription'));
              _expectCompleteAmount(tester, value);
            } else if (scope == 'suggestion') {
              final value = find.text(l10n.txnEstPerMonth(formatMoney(amount(18)), currency));
              await _reveal(tester, find.text('QA activity recurring'));
              _expectCompleteAmount(tester, value);
            } else {
              final installmentsTab = find.text(l10n.txnBillsInstalments);
              await tester.ensureVisible(installmentsTab);
              await tester.tap(installmentsTab);
              await _settle(tester);
              await _reveal(tester, find.text('QA activity installment'));
              _expectCompleteAmount(tester, find.text(formatMoney(amount(2))));
              for (final value in [amount(21), amount(20)]) {
                final finder = find.text('${formatMoney(value)} $currency');
                await _reveal(tester, finder);
                _expectCompleteAmount(tester, finder);
              }
            }
            expect(tester.takeException(), isNull);
            expect(await _snapshot(db), before,
                reason: 'Public Bills tab navigation must not change any raw user-table row.');
            await tester.pumpWidget(const SizedBox.shrink());
            await tester.pumpAndSettle();
          });
        }
      }
    }
  }
}
