// Offline real-ledger presentation fixtures. Never imported by lib/.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:money_companion/core/backend/supabase_config.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_seed.dart';
import 'package:money_companion/data/repositories/drift_account_repository.dart';
import 'package:money_companion/data/repositories/drift_budget_repository.dart';
import 'package:money_companion/data/repositories/drift_transaction_repository.dart';
import 'package:money_companion/domain/entities/account_entity.dart';
import 'package:money_companion/domain/entities/budget_entity.dart';
import 'package:money_companion/domain/entities/transaction_entity.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/features/budgets/budgets_providers.dart';
import 'package:money_companion/features/budgets/budgets_screen.dart';
import 'package:money_companion/features/reports/reports_providers.dart';
import 'package:money_companion/features/reports/reports_screen.dart';
import 'package:money_companion/features/transactions/transactions_providers.dart';

const visualParityFinancialStateSurfaceKeys = [
  'reportsRefundNet',
  'budgetStatusHistory',
];

// Any unrelated financial row, including an archived row, rejects admission.
// Catalog/default-settings rows are intentionally outside this ledger guard.
const _emptyRelatedTables = [
  'cards', 'goals', 'goal_contributions', 'subscriptions', 'bill_payments',
  'plans', 'plan_transaction_links', 'local_offer_savings', 'ledger_sync_outbox',
  'planning_sync_outbox', 'smart_inbox_items', 'suspected_duplicates',
  'engagement_events', 'dedup_hashes',
  'sender_bank_mappings',
];

typedef _TransactionSpec = ({String suffix, int minor,
  TransactionTypeEntity type, String categoryKey, String? merchant,
  DateTime occurredAt});

Future<void> _requireIDs(AppDatabase db, String table, String column,
    Set<String> expected) async {
  final rows = await db.customSelect('SELECT $column FROM $table').get();
  final ids = rows.map((row) => row.read<String>(column)).toSet();
  if (rows.length != expected.length || !setEquals(ids, expected)) {
    throw StateError('financial_visual_requires_empty_or_exact_matching_ledger');
  }
}

Future<void> _requireEmpty(AppDatabase db, Iterable<String> tables) async {
  for (final table in tables) {
    final row = await db.customSelect('SELECT COUNT(*) AS n FROM $table').getSingle();
    if (row.read<int>('n') != 0) {
      throw StateError('financial_visual_requires_empty_or_exact_matching_ledger:$table');
    }
  }
}

Future<void> _requireMerchantCatalog(AppDatabase db,
    Map<String, String> categoryIds, Set<String> fixtureNames) async {
  // A fresh AppDatabase contains the production keyword merchant catalog.
  // Admit only that unchanged seed plus this fixture's own unmapped names.
  final seed = {for (final item in DatabaseSeed.merchantMappings) item.rawName: item};
  final rows = await db.customSelect('''
    SELECT m.raw_name, m.normalized_name, c.category_id,
      c.is_user_confirmed, c.confidence
    FROM merchants m LEFT JOIN merchant_category_map c ON c.merchant_id = m.id
  ''').get();
  if (rows.length != seed.length + fixtureNames.length) {
    throw StateError('financial_visual_existing_merchant_catalog_mismatch');
  }
  for (final row in rows) {
    final name = row.read<String>('raw_name');
    final item = seed[name];
    final mapped = row.readNullable<String>('category_id');
    if (row.read<String>('normalized_name') != AppDatabase.normalizeMerchant(name) ||
        (item == null && (!fixtureNames.contains(name) || mapped != null)) ||
        (item != null && (mapped != categoryIds[item.categoryKey] ||
            row.read<int>('is_user_confirmed') != 0 ||
            row.read<double>('confidence') != item.confidence))) {
      throw StateError('financial_visual_existing_merchant_catalog_mismatch');
    }
  }
}

Future<bool> openVisualParityFinancialStateSurface(
    BuildContext context, WidgetRef ref, String key) async {
  if (!visualParityFinancialStateSurfaceKeys.contains(key)) return false;
  if (!kDebugMode || SupabaseConfig.isConfigured) {
    throw StateError('financial_visual_requires_offline_debug');
  }
  final db = ref.read(appDatabaseProvider);
  final databases = await db.customSelect('PRAGMA database_list').get();
  if (!databases.any((row) => row.read<String>('name') == 'main' &&
      row.read<String>('file').isEmpty)) {
    throw StateError('financial_visual_requires_memory_database');
  }
  final reports = key == 'reportsRefundNet';
  final prefix = reports ? 'qa-financial-reports' : 'qa-financial-budgets';
  final accountId = '$prefix-account';
  // These are the production repositories without optional outbox queues.
  // No engagement, alert, scheduler, auth or cloud service is constructed.
  final accounts = DriftAccountRepository(db);
  final transactions = DriftTransactionRepository(db);
  final budgets = DriftBudgetRepository(db);
  late DateTime anchor;
  await db.transaction(() async {
    final existing = await accounts.getById(accountId);
    final firstOpen = existing == null;
    if (firstOpen) {
      await _requireEmpty(db, [
        'accounts', 'transactions', 'budgets', ..._emptyRelatedTables,
      ]);
      anchor = DateTime.now();
    } else {
      if (existing.metadata?['visualFixture'] != key ||
          existing.metadata?['fixtureVersion'] != 1 ||
          existing.metadata?['anchorUtc'] is! String ||
          existing.currency != 'EGP' || existing.type != AccountType.bank ||
          existing.name != (reports ? 'QA refund account' : 'QA budget states account') ||
          !existing.isDefault || existing.excludeFromTotals ||
          existing.sortOrder != 0 || existing.metadata!.length != 3 ||
          existing.bankAccountNumber != null || existing.walletProvider != null ||
          existing.creditLimitMoney != null || existing.availableCreditMoney != null ||
          existing.paymentDueDay != null ||
          existing.initialBalanceMoney != Money.zero('EGP') ||
          existing.currentBalanceMoney != Money.zero('EGP')) {
        throw StateError('financial_visual_existing_fixture_mismatch');
      }
      anchor = DateTime.parse(existing.metadata!['anchorUtc'] as String).toLocal();
      final now = DateTime.now();
      if (anchor.year != now.year || anchor.month != now.month) {
        throw StateError('financial_visual_fixture_month_expired_reset_memory');
      }
      await _requireEmpty(db, _emptyRelatedTables);
    }
    final start = DateTime(anchor.year, anchor.month);
    final previousStart = DateTime(anchor.year, anchor.month - 1);
    // Both instants are real past dates. Current is always inside this month;
    // the prior report instant is inside its matched previous-period window.
    final currentAt = start.add(Duration(
        microseconds: anchor.difference(start).inMicroseconds ~/ 2));
    final previousAt = reports ? start.subtract(const Duration(hours: 12))
        : DateTime(anchor.year, anchor.month - 1, 15, 12);
    final specs = <_TransactionSpec>[
      if (reports) ...[
        (suffix: 'current-payment', minor: 10000, type: TransactionTypeEntity.payment,
          categoryKey: 'groceries', merchant: 'QA refund market', occurredAt: currentAt),
        (suffix: 'current-refund', minor: 2000, type: TransactionTypeEntity.refund,
          categoryKey: 'groceries', merchant: 'QA refund market', occurredAt: currentAt),
        (suffix: 'current-income', minor: 25000, type: TransactionTypeEntity.income,
          categoryKey: 'income', merchant: null, occurredAt: currentAt),
        (suffix: 'previous-payment', minor: 8000, type: TransactionTypeEntity.payment,
          categoryKey: 'groceries', merchant: 'QA refund market', occurredAt: previousAt),
        (suffix: 'previous-refund', minor: 1000, type: TransactionTypeEntity.refund,
          categoryKey: 'groceries', merchant: 'QA refund market', occurredAt: previousAt),
        (suffix: 'previous-income', minor: 20000, type: TransactionTypeEntity.income,
          categoryKey: 'income', merchant: null, occurredAt: previousAt),
      ] else ...[
        for (final item in [('groceries', 5000, 6000),
            ('cafes', 8500, 11000), ('restaurants', 12000, 4000)]) ...[
          (suffix: 'current-${item.$1}', minor: item.$2,
            type: TransactionTypeEntity.payment, categoryKey: item.$1,
            merchant: 'QA budget ${item.$1}', occurredAt: currentAt),
          (suffix: 'previous-${item.$1}', minor: item.$3,
            type: TransactionTypeEntity.payment, categoryKey: item.$1,
            merchant: 'QA budget ${item.$1}', occurredAt: previousAt),
        ],
      ],
    ];
    final categories = await ref.read(categoryRepositoryProvider).getAll();
    final categoryIds = {for (final category in categories) category.key: category.id};
    if (specs.any((spec) => !categoryIds.containsKey(spec.categoryKey))) {
      throw StateError('financial_visual_requires_real_seeded_categories');
    }
    await _requireMerchantCatalog(db, categoryIds, firstOpen ? {} :
        {for (final spec in specs) if (spec.merchant != null) spec.merchant!});
    final budgetRows = <BudgetEntity>[
      if (!reports)
        for (final category in ['groceries', 'cafes', 'restaurants'])
          BudgetEntity(id: '$prefix-$category', categoryId: categoryIds[category]!,
            currency: 'EGP', amountMoney: Money(10000, 'EGP'),
            lastNotifiedSpentMoney: Money.zero('EGP'), period: BudgetPeriod.monthly,
            startDate: previousStart.toUtc(), isActive: true,
            lastNotifiedPeriodStart: previousStart.toUtc(), accountId: accountId),
    ];
    if (firstOpen) {
      await accounts.create(AccountEntity(id: accountId,
        name: reports ? 'QA refund account' : 'QA budget states account',
        currency: 'EGP', type: AccountType.bank, isDefault: true, sortOrder: 0,
        initialBalanceMoney: Money.zero('EGP'), currentBalanceMoney: Money.zero('EGP'),
        createdAt: anchor.toUtc(), updatedAt: anchor.toUtc(),
        metadata: {'visualFixture': key, 'fixtureVersion': 1,
          'anchorUtc': anchor.toUtc().toIso8601String()}));
      for (final spec in specs) {
        await transactions.saveTransaction(transaction: TransactionEntity(
          id: '$prefix-${spec.suffix}', amountMoney: Money(spec.minor, 'EGP'),
          currency: 'EGP', accountId: accountId, type: spec.type,
          source: TransactionSourceEntity.bank, occurredAt: spec.occurredAt,
          rawMessage: 'Synthetic financial presentation fixture',
          rawMerchant: spec.merchant, parseConfidence: 1,
          direction: spec.type == TransactionTypeEntity.payment
              ? TransactionDirectionEntity.debit : TransactionDirectionEntity.credit,
          status: TransactionStatus.confirmed, createdAt: anchor.toUtc(),
          updatedAt: anchor.toUtc()), categoryKey: spec.categoryKey);
      }
      for (final budget in budgetRows) {
        await budgets.save(budget);
      }
    } else {
      await _requireIDs(db, 'accounts', 'id', {accountId});
      await _requireIDs(db, 'transactions', 'id',
          {for (final spec in specs) '$prefix-${spec.suffix}'});
      await _requireIDs(db, 'budgets', 'id', {for (final budget in budgetRows) budget.id});
      for (final spec in specs) {
        final row = await transactions.getById('$prefix-${spec.suffix}');
        if (row == null || row.amountMoney != Money(spec.minor, 'EGP') ||
            row.type != spec.type || row.currency != 'EGP' ||
            row.accountId != accountId || row.status != TransactionStatus.confirmed ||
            row.categoryId != categoryIds[spec.categoryKey] ||
            row.rawMerchant != spec.merchant ||
            row.rawMessage != 'Synthetic financial presentation fixture' ||
            row.source != TransactionSourceEntity.bank || row.parseConfidence != 1 ||
            row.note != null || row.cardLast4 != null || row.balanceAfterMoney != null ||
            row.foreignMoney != null || row.serverId != null ||
            row.syncStatus != SyncStatus.localOnly ||
            row.direction != (spec.type == TransactionTypeEntity.payment
                ? TransactionDirectionEntity.debit : TransactionDirectionEntity.credit) ||
            !row.createdAt.isAtSameMomentAs(anchor) ||
            !row.updatedAt.isAtSameMomentAs(anchor) ||
            !row.occurredAt.isAtSameMomentAs(spec.occurredAt)) {
          throw StateError('financial_visual_existing_fixture_mismatch');
        }
      }
      for (final expected in budgetRows) {
        final row = await budgets.getById(expected.id);
        if (row == null || row.categoryId != expected.categoryId ||
            row.amountMoney != expected.amountMoney || row.accountId != accountId ||
            row.currency != 'EGP' || row.period != BudgetPeriod.monthly ||
            !row.isActive || row.showOnHeader ||
            row.alertThresholdPercent != BudgetEntity.defaultAlertThresholdPercent ||
            row.lastNotifiedSpentMoney != Money.zero('EGP') ||
            !row.lastNotifiedPeriodStart.isAtSameMomentAs(expected.lastNotifiedPeriodStart) ||
            !row.startDate.isAtSameMomentAs(expected.startDate)) {
          throw StateError('financial_visual_existing_fixture_mismatch');
        }
      }
    }
  });
  if (!context.mounted) return false;
  ref.read(activeAccountIdProvider.notifier).state = accountId;
  ref.read(transactionsDateRangeProvider.notifier).state = reports
      ? transactionsRangeForPreset(TransactionsDatePreset.thisMonth)
      : TransactionsDateRange(preset: TransactionsDatePreset.custom,
          from: DateTime(anchor.year, anchor.month - 1), to: DateTime.now());
  ref.invalidate(accountsProvider);
  ref.invalidate(baseCurrencyProvider);
  ref.invalidate(reportsProvider);
  ref.invalidate(budgetsViewProvider);
  if (!reports) {
    ref.read(budgetsPageTabProvider.notifier).state = 0;
    ref.read(budgetsHistoryPeriodFilterProvider.notifier).state = null;
  }
  unawaited(Navigator.of(context).push<void>(MaterialPageRoute<void>(
    builder: (_) => reports ? const ReportsScreen() : const BudgetsScreen())));
  return true;
}
