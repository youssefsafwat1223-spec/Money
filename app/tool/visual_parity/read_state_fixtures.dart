// Disposable offline UI read outcomes only; never imported by lib/.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:money_companion/core/backend/supabase_config.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/sync/conflict_resolver.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/catalog/catalog_daos.dart';
import 'package:money_companion/data/repositories/drift_transaction_repository.dart';
import 'package:money_companion/domain/repositories/transaction_repository.dart';
import 'package:money_companion/domain/entities/card_entity.dart';
import 'package:money_companion/domain/entities/bill_entity.dart';
import 'package:money_companion/domain/entities/budget_entity.dart';
import 'package:money_companion/domain/entities/engagement_entities.dart';
import 'package:money_companion/domain/entities/supporting_entities.dart';
import 'package:money_companion/domain/entities/transaction_entity.dart';
import 'package:money_companion/domain/services/card_account_grouper.dart';
import 'package:money_companion/features/achievements/achievements_providers.dart';
import 'package:money_companion/features/accounts/accounts_providers.dart';
import 'package:money_companion/features/budgets/budgets_providers.dart';
import 'package:money_companion/features/cards/cards_providers.dart';
import 'package:money_companion/features/coupons/savings_providers.dart';
import 'package:money_companion/features/coupons/savings_repository.dart';
import 'package:money_companion/features/common/category_catalog.dart';
import 'package:money_companion/features/goals/goals_providers.dart';
import 'package:money_companion/features/plans/plans_providers.dart';
import 'package:money_companion/features/subscriptions/subscriptions_providers.dart';
import 'package:money_companion/features/transactions/transactions_providers.dart';
import 'package:money_companion/features/settings/settings_providers.dart';

Future<T> _readOutcome<T>(String mode) => mode == 'loading'
    ? Completer<T>().future
    : Future<T>.error(StateError('synthetic_visual_read_failure'));

// The real list UI consumes its actual AsyncNotifier type. Only build's read
// outcome is replaced; no data branch is emitted and loadMore is never invoked.
class _ReadOutcomeTransactions extends TransactionsListNotifier {
  _ReadOutcomeTransactions(this.mode);
  final String mode;
  @override
  Future<TransactionsView> build() => _readOutcome<TransactionsView>(mode);
}

int _planLinkReadCount = 0;
int _cardAttachReadCount = 0;
int _planningConflictsReadCount = 0;
final _settingsReadCounts = <String, int>{};

class _PlanLinkReadOutcomeRepository extends DriftTransactionRepository {
  _PlanLinkReadOutcomeRepository(super.database, this.mode);
  final String mode;

  @override
  Future<List<TransactionEntity>> getTransactionPage({required int limit,
      TransactionPageCursor? after, TransactionPageFilter filter = const TransactionPageFilter()}) {
    if (limit == 500 && after == null && filter.kind == TransactionPageKind.expenses) {
      _planLinkReadCount++;
      return _readOutcome<List<TransactionEntity>>(mode);
    }
    return super.getTransactionPage(limit: limit, after: after, filter: filter);
  }
}

const visualParityReadStateTargets = <String, String>{
  'cards': 'accountCardGroupsProvider',
  'cardPicker': 'allCardsProvider',
  'cardAttach': 'pickTransactionsProvider(*) bounded local candidate read',
  'planningConflicts': 'conflictsProvider local read only; resolver authority never obtained',
  'settings': 'userSettingsProvider local read only; settings writer unchanged',
  'settingsCountries': 'supportedCountriesProvider local catalog read only',
  'settingsCurrencies': 'activeCurrenciesProvider local catalog read only',
  'settingsNotifications': 'notificationPreferencesProvider local read only',
  'planDetails': 'planProgressProvider(*)',
  'planHistory': 'planTransactionsProvider(*)',
  'planLink': 'transactionRepositoryProvider: initial expense page limit500 only',
  'accountHistory': 'accountRecentTransactionsProvider(*)',
  'budgetDetail': 'budgetByIdProvider(*)',
  'budgetCategories': 'categoryCatalogProvider',
  'activity': 'transactionsListProvider (build outcome only)',
  'subscriptions': 'savedBillsProvider',
};

Future<List<Override>> visualParityReadStateOverrides({
  required AppDatabase database,
  required String mode,
  String? outcomeTarget,
}) async {
  if (!kDebugMode || SupabaseConfig.isConfigured) {
    throw StateError('visual_read_outcomes_require_offline_debug');
  }
  final rows = await database.customSelect('PRAGMA database_list').get();
  if (!rows.any((row) => row.read<String>('name') == 'main' &&
      row.read<String>('file').isEmpty)) {
    throw StateError('visual_read_outcomes_require_memory_database');
  }
  _planLinkReadCount = 0;
  _cardAttachReadCount = 0;
  _planningConflictsReadCount = 0;
  _settingsReadCounts.clear();
  if (mode != 'loading' && mode != 'error') return const [];
  if (outcomeTarget == 'settings' || outcomeTarget == 'settingsCountries' ||
      outcomeTarget == 'settingsCurrencies' || outcomeTarget == 'settingsNotifications') {
    Future<T> outcome<T>() {
      _settingsReadCounts.update(outcomeTarget!, (n) => n + 1, ifAbsent: () => 1);
      return _readOutcome<T>(mode);
    }
    return switch (outcomeTarget) {
      'settings' => [userSettingsProvider.overrideWith((ref) => outcome<UserSettingsEntity>())],
      'settingsCountries' => [supportedCountriesProvider.overrideWith((ref) => outcome<List<RemoteCountry>>())],
      'settingsNotifications' => [notificationPreferencesProvider.overrideWith((ref) => outcome<NotificationPreferences>())],
      _ => [activeCurrenciesProvider.overrideWith((ref) => outcome<List<RemoteCurrency>>())],
    };
  }
  if (outcomeTarget == 'planningConflicts') {
    return [conflictsProvider.overrideWith((ref) {
      _planningConflictsReadCount++;
      return _readOutcome<List<SyncConflict>>(mode);
    })];
  }
  if (outcomeTarget == 'planLink') {
    return [transactionRepositoryProvider.overrideWithValue(
        _PlanLinkReadOutcomeRepository(database, mode))];
  }
  if (outcomeTarget == 'cardAttach') {
    return [pickTransactionsProvider.overrideWith((ref, query) {
      _cardAttachReadCount++;
      return _readOutcome<List<TransactionEntity>>(mode);
    })];
  }
  if (outcomeTarget == 'cardPicker') {
    return [allCardsProvider.overrideWith((ref) =>
        _readOutcome<List<CardEntity>>(mode))];
  }
  if (outcomeTarget == 'cards') {
    return [accountCardGroupsProvider.overrideWith((ref) =>
        _readOutcome<CardGrouping>(mode))];
  }
  if (outcomeTarget == 'planDetails') {
    return [planProgressProvider.overrideWith((ref, id) =>
        _readOutcome<PlanProgress?>(mode))];
  }
  if (outcomeTarget == 'planHistory') {
    return [planTransactionsProvider.overrideWith((ref, id) =>
        _readOutcome<List<TransactionEntity>>(mode))];
  }
  if (outcomeTarget == 'accountHistory') {
    return [accountRecentTransactionsProvider.overrideWith((ref, id) =>
        _readOutcome<List<TransactionEntity>>(mode))];
  }
  if (outcomeTarget == 'budgetDetail') {
    return [budgetByIdProvider.overrideWith((ref, id) =>
        _readOutcome<BudgetEntity?>(mode))];
  }
  if (outcomeTarget == 'budgetCategories') {
    return [categoryCatalogProvider.overrideWith((ref) =>
        _readOutcome<CategoryCatalog>(mode))];
  }
  if (outcomeTarget == 'activity') {
    return [transactionsListProvider.overrideWith(() =>
        _ReadOutcomeTransactions(mode))];
  }
  if (outcomeTarget == 'subscriptions') {
    return [savedBillsProvider.overrideWith((ref) =>
        _readOutcome<List<BillEntity>>(mode))];
  }
  if (outcomeTarget != null) {
    throw ArgumentError.value(outcomeTarget, 'outcomeTarget');
  }
  return [
    transactionByIdProvider.overrideWith((ref, id) =>
        _readOutcome<TransactionEntity?>(mode)),
    cardTransactionsProvider.overrideWith((ref, last4) =>
        _readOutcome<List<TransactionEntity>>(mode)),
    accountCardGroupsProvider.overrideWith((ref) =>
        _readOutcome<CardGrouping>(mode)),
    goalDetailsProvider.overrideWith((ref, goalId) =>
        _readOutcome<GoalDetailsEntity?>(mode)),
    achievementsViewProvider.overrideWith((ref) =>
        _readOutcome<AchievementsView>(mode)),
    savingsTotalsProvider.overrideWith((ref) =>
        _readOutcome<SavingsTotals>(mode)),
    accountRecentTransactionsProvider.overrideWith((ref, id) =>
        _readOutcome<List<TransactionEntity>>(mode)),
    budgetByIdProvider.overrideWith((ref, id) =>
        _readOutcome<BudgetEntity?>(mode)),
    transactionsListProvider.overrideWith(() =>
        _ReadOutcomeTransactions(mode)),
    savedBillsProvider.overrideWith((ref) =>
        _readOutcome<List<BillEntity>>(mode)),
  ];
}

/// Describes provider provenance, not successful workflows. The controller's
/// separate fixture field identifies the current mode. Retry invalidates the
/// same synthetic future; it does not make a failed backend recover.
Map<String, Object> get visualParityReadStateManifest => {
  ..._visualParityReadStateManifest,
  'readCounts': {'planLink': _planLinkReadCount, 'cardAttach': _cardAttachReadCount,
    'planningConflicts': _planningConflictsReadCount, ..._settingsReadCounts},
};

const _visualParityReadStateManifest = <String, Object>{
  'qualification': 'Offline memory-only presentation futures; no authentication, '
      'consent, entitlement, notification delivery, or backend outcome is simulated.',
  'overridesApplyIn': ['loading', 'error'],
  'selectiveTargets': visualParityReadStateTargets,
  'targetQualification': 'With a non-null outcomeTarget, only its named provider '
      'is overridden. Root and secondary global read overrides stay off; all '
      'parent screens and other reads use actual synthetic local data. Retry '
      'repeats the same selected synthetic outcome.',
  'selectivePlanSurfaces': {
    'entry': 'Open /preview/plans, then tap a real synthetic plan name.',
    'planDetails': {
      'provider': 'planProgressProvider(*)',
      'loading': 'CircularProgressIndicator inside real details sheet',
      'errorL10n': 'plLoadFailed / annTryAgainSoon',
    },
    'planHistory': {
      'provider': 'planTransactionsProvider(*)',
      'loading': 'CircularProgressIndicator in history section',
      'errorL10n': 'plTxLoadFailed / annTryAgainSoon',
      'qualification': 'Plan progress and list remain actual synthetic reads.',
    },
    'planLink': {
      'entry': 'Open a real synthetic plan, then its Link transaction action.',
      'provider': 'DriftTransactionRepository subclass: only initial '
          'getTransactionPage(limit:500, kind:expenses) gets a synthetic read outcome.',
      'loading': 'CircularProgressIndicator in the real link picker',
      'errorL10n': 'txnError / annTryAgainSoon / startRetry',
      'qualification': 'All other queries and parents use actual memory Drift '
          'data. Retry repeats the same synthetic error; it never claims recovery '
          'or successful linking. readCounts.planLink records each selected read.',
    },
  },
  'newReadOverrides': {
    '/cards Link existing transaction': {
      'entry': 'Open actual /cards then tap a real card Link existing transaction action.',
      'target': 'cardAttach',
      'provider': 'pickTransactionsProvider(*) bounded local candidate read only',
      'loading': 'CircularProgressIndicator inside actual attach sheet',
      'errorL10n': 'txnError / annTryAgainSoon / startRetry',
      'qualification': 'Parent card grouping, accounts and managed cards remain actual '
          'memory reads. Retry repeats the current-query synthetic read; '
          'readCounts.cardAttach records admissions, not successful recovery or linking. '
          'Data mode leaves the real bounded query unchanged.',
    },
    '/subscriptions': {
      'provider': 'savedBillsProvider',
      'loading': 'SkeletonList(rows: 4) under the actual pinned header',
      'errorL10n': 'txnError / annTryAgainSoon',
      'qualification': 'subscriptions target changes only the local saved-bill '
          'read outcome; account scope and recurring suggestions stay actual '
          'synthetic reads. No billing/payment completion is simulated.',
    },
    'Activity tab': {
      'provider': 'transactionsListProvider',
      'loading': 'SkeletonList(rows: 6)',
      'errorL10n': 'txnError / annTryAgainSoon',
      'qualification': 'Actual notifier subtype, read build outcome only. '
          'No success data or loadMore behavior is simulated.',
    },
    '/account/:id recent transactions': {
      'provider': 'accountRecentTransactionsProvider(*)',
      'loading': 'CircularProgressIndicator in transactions section',
      'errorL10n': 'txnError / annTryAgainSoon',
      'qualification': 'Use outcomeTarget accountHistory to keep account '
          'lookup real; global mode also fails accountsProvider.',
    },
    '/budgets/:id/edit': {
      'provider': 'budgetByIdProvider(*)',
      'loading': 'CircularProgressIndicator',
      'errorL10n': 'txnError / annTryAgainSoon',
      'qualification': 'budgetCategories target isolates category catalog '
          'failure for new or edit forms.',
    },
    '/transaction/:id': {
      'provider': 'transactionByIdProvider(*)',
      'loading': 'CircularProgressIndicator',
      'errorL10n': 'txnError',
    },
    '/card/:last4': {
      'provider': 'cardTransactionsProvider(*)',
      'loading': 'CircularProgressIndicator in the transactions section',
      'errorL10n': 'txnError',
      'qualification': 'Card summary remains a real read of the synthetic ledger.',
    },
    '/cards': {
      'provider': 'accountCardGroupsProvider',
      'loading': 'CircularProgressIndicator',
      'errorL10n': 'cardLoadFailed / cardLoadFailedBody',
      'qualification': 'Use outcomeTarget cards to isolate grouping failure '
          'while accounts and managed cards remain actual local reads.',
    },
    '/goals/:id': {
      'provider': 'goalDetailsProvider(*)',
      'loading': 'CircularProgressIndicator',
      'errorL10n': 'txnError',
    },
    '/achievements': {
      'provider': 'achievementsViewProvider',
      'loading': 'SkeletonList(rows: 5)',
      'errorL10n': 'txnError',
    },
    '/savings': {
      'provider': 'savingsTotalsProvider',
      'loadingL10n': 'couponsLoading',
      'errorL10n': 'couponsErrorTitle / couponsErrorBody',
    },
  },
  'existingIndirectOutcomes': {
    '/coupons/merchant/:merchantId': {
      'provider': 'cachedCouponsProvider through couponsByMerchantProvider',
      'loadingL10n': 'couponsLoading',
      'errorL10n': 'couponsErrorTitle / couponsErrorBody',
    },
    '/announcements': {
      'provider': 'notificationPreferencesProvider',
      'loadingL10n': 'annLoading',
      'errorL10n': 'annLoadFailed / annTryAgainSoon',
      'qualification': 'Catalog/campaign values remain real local reads. '
          'Their own failures have no separate screen branch.',
    },
    'Settings notifications tab': {
      'provider': 'notificationPreferencesProvider',
      'loading': 'CircularProgressIndicator',
      'errorL10n': 'setSettingsLoadFailed',
    },
  },
  'notSimulated': {
    'userSettingsProvider': 'No dedicated loading/error UI branch is simulated. '
        'The selected settings target supports loading/error reads; General '
        'settings renders its existing valueOrNull fallback without granting '
        'consent or changing stored settings.',
    'activeAnnouncementsProvider / activeDashboardCampaignsProvider':
        'Screen uses valueOrNull; no separate catalog failure UI is invented.',
    'savingsHistoryProvider': 'SavingsScreen reads totals, not this history provider.',
  },
};
