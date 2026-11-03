import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/repositories/drift_account_repository.dart';
import 'package:money_companion/data/repositories/drift_card_repository.dart';
import 'package:money_companion/data/repositories/drift_transaction_repository.dart';
import 'package:money_companion/domain/entities/account_entity.dart';
import 'package:money_companion/domain/entities/card_entity.dart';
import 'package:money_companion/domain/entities/transaction_entity.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/domain/services/card_account_grouper.dart';
import 'package:money_companion/engine/parser/card_network.dart';
import 'package:money_companion/features/cards/cards_providers.dart';
import 'package:money_companion/features/cards/my_cards_screen.dart';
import 'package:money_companion/features/common/category_catalog.dart';
import 'package:money_companion/features/transactions/transaction_details_screen.dart';
import 'package:money_companion/features/transactions/transactions_providers.dart';
import 'package:money_companion/l10n/app_localizations.dart';

class _MemoryKeys implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'card-picker-memory';
  @override
  Future<String?> readStoredKey() async => 'card-picker-memory';
}

class _Fixture {
  _Fixture(this.db, this.cards, this.accounts, this.grouping, this.before);
  final AppDatabase db;
  final List<CardEntity> cards;
  final List<AccountEntity> accounts;
  final CardGrouping grouping;
  final List<Map<String, Object?>> before;
}

Future<List<Map<String, Object?>>> _ledger(AppDatabase db) async =>
    (await db.customSelect('SELECT * FROM transactions ORDER BY id').get())
        .map((row) => Map<String, Object?>.from(row.data))
        .toList();

Future<_Fixture> _open(
  WidgetTester tester,
  Future<List<CardEntity>> Function(List<CardEntity>) load, {
  String language = 'en',
  bool cardsPage = false,
  Future<List<AccountEntity>> Function(List<AccountEntity>)? loadAccounts,
  Future<CardGrouping> Function(CardGrouping)? loadGrouping,
}) async {
  tester.view.physicalSize = const Size(375, 667);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final now = DateTime(2026, 1, 15);
  final tx = TransactionEntity(
    id: 'picker-tx', amountMoney: Money(12345, 'EGP'), currency: 'EGP',
    accountId: 'own', cardLast4: '1234', rawMerchant: 'Synthetic merchant',
    type: TransactionTypeEntity.payment, source: TransactionSourceEntity.bank,
    occurredAt: now, rawMessage: 'Synthetic SMS', parseConfidence: 1,
    status: TransactionStatus.confirmed, createdAt: now, updatedAt: now,
  );
  final fixture = (await tester.runAsync(() async {
    final db = await AppDatabase.open(
        executor: NativeDatabase.memory(), keyStore: _MemoryKeys());
    final accounts = DriftAccountRepository(db);
    for (final id in ['own', 'other']) {
      await accounts.create(AccountEntity(
        id: id, name: id, currency: 'EGP', type: AccountType.bank,
        isDefault: id == 'own', sortOrder: 0, createdAt: now, updatedAt: now,
      ));
    }
    final cards = DriftCardRepository(db);
    for (final row in [('own', '1234'), ('own', '5678'), ('other', '9999')]) {
      await cards.create(CardEntity(
        id: 'card-${row.$2}', accountId: row.$1, last4: row.$2,
        network: CardNetwork.visa, source: CardSource.manual,
        createdAt: now, updatedAt: now,
      ));
    }
    final transactions = DriftTransactionRepository(db);
    await transactions.saveTransaction(
        transaction: tx, categoryKey: 'groceries');
    return _Fixture(db, await cards.getAll(), await accounts.getAll(),
        const CardAccountGrouper().group(
            await transactions.getCardAccountBreakdown()), await _ledger(db));
  }))!;
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(fixture.db.close);
  });
  await tester.pumpWidget(ProviderScope(overrides: [
    appDatabaseProvider.overrideWithValue(fixture.db),
    transactionRepositoryProvider.overrideWithValue(
        DriftTransactionRepository(fixture.db)),
    transactionByIdProvider(tx.id).overrideWith((ref) async => tx),
    accountsProvider.overrideWith((ref) => loadAccounts?.call(fixture.accounts) ??
        Future.value(fixture.accounts)),
    baseCurrencyProvider.overrideWith((ref) async => 'EGP'),
    accountCardGroupsProvider.overrideWith((ref) =>
        loadGrouping?.call(fixture.grouping) ?? Future.value(fixture.grouping)),
    categoryCatalogProvider.overrideWith(
        (ref) async => CategoryCatalog(const [])),
    allCardsProvider.overrideWith((ref) => load(fixture.cards)),
  ], child: MaterialApp(
    theme: AppTheme.light, locale: Locale(language),
    supportedLocales: AppL10n.supportedLocales,
    localizationsDelegates: AppL10n.localizationsDelegates,
    home: cardsPage ? const MyCardsScreen() :
        const TransactionDetailsScreen(transactionId: 'picker-tx'),
  )));
  if (cardsPage) {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
  } else {
    await tester.pumpAndSettle();
  }
  return fixture;
}

Future<void> _showPicker(WidgetTester tester) async {
  final l10n = AppL10n.of(tester.element(find.byType(TransactionDetailsScreen)));
  final change = find.widgetWithText(TextButton, l10n.txdChange);
  await tester.ensureVisible(change);
  await tester.tap(change);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
}

Future<void> _dismiss(WidgetTester tester) async {
  final title = find.text(AppL10n.of(
      tester.element(find.byType(TransactionDetailsScreen))).txdCardSheetTitle);
  Navigator.of(tester.element(title)).pop();
  await tester.pumpAndSettle();
}

Future<void> _unchanged(WidgetTester tester, _Fixture fixture) async {
  expect(await tester.runAsync(() => _ledger(fixture.db)), fixture.before,
      reason: 'opening, retrying and dismissing must not detach or move a transaction');
  expect(tester.takeException(), isNull);
}

void main() {
  for (final language in ['en', 'ar']) {
    testWidgets('cold card picker updates without reopening in $language',
        (tester) async {
      final pending = Completer<List<CardEntity>>();
      var loads = 0;
      final fixture = await _open(tester, (_) {
        loads++;
        return pending.future;
      }, language: language);
      expect(loads, 0, reason: 'the picker provider must actually start cold');
      await _showPicker(tester);
      expect(loads, 1);
      final l10n = AppL10n.of(
          tester.element(find.byType(TransactionDetailsScreen)));
      expect(find.descendant(of: find.byType(BottomSheet),
          matching: find.byType(CircularProgressIndicator)), findsOneWidget);
      expect(find.text(l10n.txdNoCardsOnAccount), findsNothing);
      pending.complete(fixture.cards);
      await tester.pumpAndSettle();
      expect(find.text(l10n.txdCardSheetTitle), findsOneWidget);
      expect(find.widgetWithText(ListTile, '•••• 1234'), findsOneWidget);
      expect(find.widgetWithText(ListTile, '•••• 5678'), findsOneWidget);
      expect(find.widgetWithText(ListTile, '•••• 9999'), findsNothing);
      expect(find.text(l10n.txdNoCardsOnAccount), findsNothing);
      await _dismiss(tester);
      await _unchanged(tester, fixture);
    });
  }

  testWidgets('card load error retries without an empty claim or a ledger write',
      (tester) async {
    final pending = Completer<List<CardEntity>>();
    var loads = 0;
    final fixture = await _open(tester, (cards) =>
        loads++ == 0 ? pending.future : Future.value(cards));
    await _showPicker(tester);
    pending.completeError(StateError('synthetic card read failure'));
    await tester.pumpAndSettle();
    final l10n = AppL10n.of(
        tester.element(find.byType(TransactionDetailsScreen)));
    expect(find.text(l10n.cardLoadFailed), findsOneWidget);
    expect(find.text(l10n.txdNoCardsOnAccount), findsNothing);
    await tester.tap(find.widgetWithText(TextButton, l10n.startRetry));
    await tester.pumpAndSettle();
    expect(loads, 2);
    expect(find.widgetWithText(ListTile, '•••• 1234'), findsOneWidget);
    expect(find.widgetWithText(ListTile, '•••• 5678'), findsOneWidget);
    expect(find.widgetWithText(ListTile, '•••• 9999'), findsNothing);
    expect(find.text(l10n.cardLoadFailed), findsNothing);
    await _dismiss(tester);
    await _unchanged(tester, fixture);
  });

  testWidgets('dismissing a loading picker preserves the original card after completion',
      (tester) async {
    final pending = Completer<List<CardEntity>>();
    final fixture = await _open(tester, (_) => pending.future);
    await _showPicker(tester);
    await _dismiss(tester);
    pending.complete(fixture.cards);
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsNothing);
    expect(find.text('•••• 1234'), findsOneWidget);
    await _unchanged(tester, fixture);
  });

  for (final source in ['grouping', 'accounts', 'managed cards']) {
    testWidgets('card list reports and retries a $source read failure',
        (tester) async {
      var failing = true;
      final fixture = await _open(tester, (cards) async {
        if (failing && source == 'managed cards') {
          throw StateError('synthetic managed-card read failure');
        }
        return cards;
      }, cardsPage: true, loadAccounts: (accounts) async {
        if (failing && source == 'accounts') {
          throw StateError('synthetic account read failure');
        }
        return accounts;
      }, loadGrouping: (grouping) async {
        if (failing && source == 'grouping') {
          throw StateError('synthetic grouping read failure');
        }
        return grouping;
      });
      await tester.pumpAndSettle();
      final l10n = AppL10n.of(tester.element(find.byType(MyCardsScreen)));
      expect(find.text(l10n.cardLoadFailed), findsOneWidget);
      expect(find.text(l10n.cardEmptyTitle), findsNothing,
          reason: 'a failed read cannot prove that there are no cards');
      failing = false;
      await tester.tap(find.text(l10n.startRetry));
      await tester.pumpAndSettle();
      expect(find.text(l10n.cardLoadFailed), findsNothing);
      expect(find.text(l10n.cardEmptyTitle), findsNothing);
      final manualCard = find.byKey(const ValueKey('card-activity-own|5678'));
      await tester.scrollUntilVisible(manualCard, 150,
          scrollable: find.byType(Scrollable).first);
      await tester.pumpAndSettle();
      expect(find.descendant(of: manualCard, matching: find.textContaining('5678')), findsOneWidget,
          reason: 'the manual card with no transactions must return after Retry');
      await _unchanged(tester, fixture);
    });
  }

  testWidgets('card list waits for the first managed-card read before claiming empty',
      (tester) async {
    final pending = Completer<List<CardEntity>>();
    final fixture = await _open(tester, (_) => pending.future, cardsPage: true,
        loadGrouping: (_) async => const CardGrouping(byAccount: {}, unassigned: []));
    final l10n = AppL10n.of(tester.element(find.byType(MyCardsScreen)));
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text(l10n.cardEmptyTitle), findsNothing);
    pending.complete(fixture.cards);
    await tester.pumpAndSettle();
    final manualCard = find.byKey(const ValueKey('card-activity-own|5678'));
    await tester.scrollUntilVisible(manualCard, 150,
        scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();
    expect(find.descendant(of: manualCard, matching: find.textContaining('5678')),
        findsOneWidget);
    expect(find.text(l10n.cardEmptyTitle), findsNothing);
    await _unchanged(tester, fixture);
  });
}
