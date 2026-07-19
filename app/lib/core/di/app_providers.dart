import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as supabase;

import '../auth/account_deletion_service.dart';
import '../backend/metrics_client.dart';
import '../backend/rules_client.dart';
import '../backend/supabase_config.dart';
import '../session/app_session.dart';
import '../data_portability/app_data_portability_service.dart';
import '../data_portability/data_portability_models.dart';
import '../../engine/ai/ai_parser_client.dart';
import '../../engine/ai/bank_discovery_client.dart';
import '../../data/catalog/announcement_service.dart';
import '../../data/catalog/catalog_daos.dart';
import '../../data/catalog/catalog_sync_service.dart';
import '../../data/catalog/feature_flag_service.dart';
import '../../data/catalog/growth_campaign_service.dart';
import '../../data/catalog/seed_loader.dart';
import '../../core/utils/install_id.dart';
import '../../data/db/app_database.dart';
import '../../data/repositories/drift_account_repository.dart';
import '../../data/repositories/financial_cache_repair_service.dart';
import '../../data/repositories/routed_account_repository.dart';
import '../../data/repositories/routed_category_repository.dart';
import '../../data/repositories/routed_bill_repository.dart';
import '../../data/repositories/routed_budget_repository.dart';
import '../../data/repositories/routed_goal_repository.dart';
import '../../data/repositories/routed_plan_repository.dart';
import '../../data/repositories/routed_smart_inbox_repository.dart';
import '../../data/repositories/routed_transaction_repository.dart';
import '../../data/repositories/supabase_account_repository.dart';
import '../../data/repositories/supabase_category_repository.dart';
import '../../data/repositories/supabase_bill_repository.dart';
import '../../data/repositories/supabase_budget_repository.dart';
import '../../data/repositories/supabase_financial_summary_service.dart';
import '../../data/repositories/supabase_goal_repository.dart';
import '../../data/repositories/supabase_plan_repository.dart';
import '../../data/repositories/supabase_smart_inbox_repository.dart';
import '../../data/repositories/supabase_transaction_repository.dart';
import '../../data/repositories/drift_bill_repository.dart';
import '../../data/repositories/drift_plan_repository.dart';
import '../../data/repositories/drift_budget_repository.dart';
import '../../data/repositories/drift_category_repository.dart';
import '../../data/repositories/drift_dedup_store.dart';
import '../../data/repositories/drift_gamification_repository.dart';
import '../../data/repositories/drift_suspected_duplicate_repository.dart';
import '../../data/repositories/drift_goal_repository.dart';
import '../../data/repositories/drift_merchant_category_repository.dart';
import '../../data/repositories/drift_sender_bank_mapping_repository.dart';
import '../../data/repositories/drift_smart_inbox_repository.dart';
import '../../data/repositories/drift_transaction_repository.dart';
import '../../data/repositories/drift_user_settings_repository.dart';
import '../../data/sync/sender_bank_mapping_sync_service.dart';
import '../../domain/entities/account_entity.dart';
import '../../domain/entities/suspected_duplicate_entity.dart';
import '../../domain/entities/smart_inbox_item_entity.dart';
import '../../domain/repositories/account_repository.dart';
import '../../domain/repositories/budget_repository.dart';
import '../../domain/repositories/bill_repository.dart';
import '../../domain/repositories/plan_repository.dart';
import '../../domain/repositories/category_repository.dart';
import '../../domain/repositories/gamification_repository.dart';
import '../../domain/repositories/goal_repository.dart';
import '../../domain/repositories/merchant_category_repository.dart';
import '../../domain/repositories/sender_bank_mapping_repository.dart';
import '../../domain/repositories/suspected_duplicate_repository.dart';
import '../../domain/repositories/smart_inbox_repository.dart';
import '../../domain/repositories/transaction_repository.dart';
import '../../domain/repositories/user_settings_repository.dart';
import '../../domain/services/bank_discovery_service.dart';
import '../../domain/usecases/add_transaction_usecase.dart';
import '../../domain/usecases/budget_progress_usecase.dart';
import '../../domain/usecases/confirm_transaction_usecase.dart';
import '../../domain/usecases/correct_category_usecase.dart';
import '../../domain/usecases/engagement_usecase.dart';
import '../../domain/usecases/goal_details_usecase.dart';
import '../../domain/usecases/ingest_captured_message_usecase.dart';
import '../../domain/usecases/resolve_bank_for_sender_usecase.dart';
import '../../domain/usecases/save_budget_usecase.dart';
import '../../domain/usecases/save_goal_usecase.dart';
import '../../domain/usecases/user_settings_usecases.dart';
import '../../features/app/celebration_runtime.dart';
import '../../features/capture/services/local_notification_service.dart';
import '../../features/capture/services/notification_journey_service.dart';
import '../../features/capture/services/capture_backend_client.dart';
import '../../features/capture/services/capture_device_registration_service.dart';
import '../../features/capture/services/capture_sync_service.dart';
import '../../features/capture/services/notification_log_service.dart';
import '../../features/capture/services/notification_log_sync_service.dart';
import '../../features/capture/services/ledger_outbox_queue.dart';
import '../../features/capture/services/ledger_push_service.dart';
import '../../features/capture/services/ledger_sync_engine.dart';
import '../../features/capture/services/ledger_sync_service.dart';
import '../../features/capture/services/smart_inbox_sync_service.dart';
import '../../features/planning_sync/services/accounts_pull_service.dart';
import '../../features/planning_sync/services/accounts_push_service.dart';
import '../../features/planning_sync/services/planning_outbox_queue.dart';
import '../../features/planning_sync/services/planning_pull_service.dart';
import '../../features/planning_sync/services/planning_push_service.dart';
import '../../features/planning_sync/services/planning_sync_engine.dart';
import '../../domain/services/notification_planner.dart';

final appDatabaseProvider = Provider<AppDatabase>((ref) {
  throw UnimplementedError('AppDatabase must be provided from main().');
});

/// A monotonically-increasing counter that ticks on **every** database write
/// (any table). Read-providers `ref.watch` this so the whole app reflects new
/// data live — a captured/added transaction, a new account, a changed setting
/// — without a hot restart or a manual `invalidate`.
final dbRevisionProvider = StreamProvider<int>((ref) {
  final db = ref.watch(appDatabaseProvider);
  var revision = 0;
  final controller = StreamController<int>();
  void tick() {
    if (!controller.isClosed) controller.add(++revision);
  }

  final tableSub = db.tableUpdates().listen((_) => tick());
  final manualSub = db.manualRevisionStream.listen((_) => tick());
  ref.onDispose(() async {
    await tableSub.cancel();
    await manualSub.cancel();
    await controller.close();
  });
  return controller.stream;
});

final metricsClientProvider = Provider<MetricsClient>((ref) {
  return MetricsClient();
});

final rulesClientProvider = Provider<RulesClient>((ref) {
  return RulesClient(database: ref.watch(appDatabaseProvider));
});

final announcementServiceProvider = Provider<AnnouncementService>((ref) {
  return AnnouncementService(
    dao: RemoteAnnouncementsDao(ref.watch(appDatabaseProvider)),
  );
});

final activeAnnouncementsProvider =
    FutureProvider<List<RemoteAnnouncement>>((ref) {
  return ref.watch(announcementServiceProvider).getActiveAnnouncements();
});

final growthCampaignServiceProvider = Provider<GrowthCampaignService>((ref) {
  return GrowthCampaignService(
    database: ref.watch(appDatabaseProvider),
    dao: RemoteGrowthCampaignsDao(ref.watch(appDatabaseProvider)),
    loadPreferences: ref.watch(loadNotificationPreferencesUseCaseProvider),
    savePreferences: ref.watch(saveNotificationPreferencesUseCaseProvider),
  );
});

final activeDashboardCampaignsProvider =
    FutureProvider<List<RemoteGrowthCampaign>>((ref) {
  ref.watch(dbRevisionProvider);
  return ref.watch(growthCampaignServiceProvider).visibleDashboardBanners();
});

final hasForceUpdateProvider = FutureProvider<bool>((ref) async {
  final announcements = await ref.watch(activeAnnouncementsProvider.future);
  return announcements.any((a) => a.isForceUpdate);
});

FeatureFlagService? _featureFlagInstance;

/// Initialises the authoritative runtime FeatureFlagService and loads flags
/// from Drift. Call at startup and after catalog flag sync completes.
Future<FeatureFlagService> initFeatureFlagService(
  AppDatabase db, {
  String? installIdOverride,
}) async {
  final id = installIdOverride ?? await InstallId.get();
  final service = FeatureFlagService(
    dao: RemoteFeatureFlagsDao(db),
    installId: id,
  );
  await service.init();
  if (SupabaseConfig.isConfigured) {
    final client = supabase.Supabase.instance.client;
    await service.applyUserOverrides(client, client.auth.currentUser?.id);
  }
  _featureFlagInstance = service;
  return service;
}

FeatureFlagService get featureFlags {
  if (_featureFlagInstance != null) return _featureFlagInstance!;
  throw StateError(
      'FeatureFlagService not initialised. Call syncCatalog first.');
}

/// Summary RPCs use Supabase account UUIDs, so they are safe only after both
/// account and transaction primary repositories have been enabled for the
/// same QA user. Every flag remains false by default.
bool supabaseDashboardSummaryEnabled() {
  try {
    return featureFlags.getBool('dashboard_supabase_summary') &&
        featureFlags.getBool('accounts_supabase_primary') &&
        featureFlags.getBool('transactions_supabase_primary');
  } catch (_) {
    return false;
  }
}

bool supabaseBudgetProgressSummaryEnabled() {
  try {
    return featureFlags.getBool('budget_progress_supabase_rpc') &&
        featureFlags.getBool('budgets_supabase_primary') &&
        featureFlags.getBool('accounts_supabase_primary') &&
        featureFlags.getBool('transactions_supabase_primary');
  } catch (_) {
    return false;
  }
}

final accountDeletionServiceProvider = Provider<AccountDeletionService>((ref) {
  return AccountDeletionService();
});

final accountDeletionStatusProvider =
    FutureProvider<AccountDeletionStatus>((ref) {
  return ref.watch(accountDeletionServiceProvider).getStatus();
});

final supabaseFinancialSummaryServiceProvider =
    Provider<SupabaseFinancialSummaryService>((ref) {
  return SupabaseFinancialSummaryService();
});

final financialCacheRepairServiceProvider =
    Provider<FinancialCacheRepairService>((ref) {
  final db = ref.watch(appDatabaseProvider);
  return FinancialCacheRepairService(
    db: db,
    accountsRepo: SupabaseAccountRepository(db: db),
    transactionsRepo: SupabaseTransactionRepository(db: db),
    budgetsRepo: SupabaseBudgetRepository(db: db),
    goalsRepo: SupabaseGoalRepository(db: db),
    billsRepo: SupabaseBillRepository(db: db),
    plansRepo: SupabasePlanRepository(db: db),
    smartInboxRepo: SupabaseSmartInboxRepository(db: db),
  );
});

final catalogSyncServiceProvider = Provider<CatalogSyncService>((ref) {
  final db = ref.watch(appDatabaseProvider);
  return CatalogSyncService(
    database: db,
    client: supabase.Supabase.instance.client,
    metadataDao: CatalogMetadataDao(db),
    announcementService: ref.watch(announcementServiceProvider),
  );
});

Future<void> syncCatalog(
  WidgetRef ref, {
  String? countryCode,
  bool force = false,
}) async {
  final database = ref.read(appDatabaseProvider);
  await const SeedLoader().seedIfEmpty(database);
  // Init feature flags from seed data before first frame.
  await initFeatureFlagService(database);
  if (!SupabaseConfig.isConfigured) return;
  if (!force && !await _catalogSyncIsStale(database)) return;
  await ref.read(catalogSyncServiceProvider).syncAll(countryCode: countryCode);
  // Catalog sync replaces remote_feature_flags in Drift; refresh the same
  // runtime singleton used by sync gates before any outbox/pull work runs.
  await initFeatureFlagService(database);
  // Invalidate announcement providers so UI rebuilds with fresh data.
  ref.invalidate(activeAnnouncementsProvider);
  ref.invalidate(hasForceUpdateProvider);
}

Future<bool> _catalogSyncIsStale(AppDatabase database) async {
  final metadata = CatalogMetadataDao(database);
  final cutoff = DateTime.now().toUtc().subtract(const Duration(minutes: 15));
  for (final category in CatalogCategories.syncable) {
    final version = await metadata.getVersion(category);
    final syncedAt = version?.lastSyncedAt;
    if (syncedAt == null || syncedAt.isBefore(cutoff)) return true;
  }
  return false;
}

final activeCurrenciesProvider = FutureProvider<List<RemoteCurrency>>((ref) {
  return RemoteCurrenciesDao(ref.watch(appDatabaseProvider))
      .getActiveCurrencies();
});

final supportedCountriesProvider = FutureProvider<List<RemoteCountry>>((ref) {
  return RemoteCountriesDao(ref.watch(appDatabaseProvider))
      .getSupportedCountries();
});

final ledgerOutboxQueueProvider = Provider<LedgerOutboxQueue>((ref) {
  final db = ref.watch(appDatabaseProvider);
  return LedgerOutboxQueue(
    db: db,
    isPushEnabled: () {
      try {
        return featureFlags.getBool('ledger_push_sync');
      } catch (_) {
        return false;
      }
    },
    getAuthUserId: () async {
      if (!SupabaseConfig.isConfigured) return null;
      try {
        return supabase.Supabase.instance.client.auth.currentUser?.id;
      } catch (_) {
        return null;
      }
    },
  );
});

bool _planningAccountsSyncEnabled() {
  try {
    return featureFlags.getBool('planning_accounts_sync') &&
        !featureFlags.getBool('accounts_supabase_primary');
  } catch (_) {
    return false;
  }
}

bool _planningEntitySyncEnabled(String entityType) {
  final key = switch (entityType) {
    PlanningOutboxQueue.accountsEntityType => 'planning_accounts_sync',
    PlanningOutboxQueue.budgetsEntityType => 'planning_budgets_sync',
    PlanningOutboxQueue.subscriptionsEntityType =>
      'planning_subscriptions_sync',
    PlanningOutboxQueue.goalsEntityType => 'planning_goals_sync',
    PlanningOutboxQueue.plansEntityType => 'planning_plans_sync',
    _ => '',
  };
  if (key.isEmpty) return false;
  try {
    final primaryKey = switch (entityType) {
      PlanningOutboxQueue.accountsEntityType => 'accounts_supabase_primary',
      PlanningOutboxQueue.budgetsEntityType => 'budgets_supabase_primary',
      PlanningOutboxQueue.subscriptionsEntityType =>
        'subscriptions_supabase_primary',
      PlanningOutboxQueue.goalsEntityType => 'goals_supabase_primary',
      PlanningOutboxQueue.plansEntityType => 'plans_supabase_primary',
      _ => '',
    };
    return featureFlags.getBool(key) &&
        (primaryKey.isEmpty || !featureFlags.getBool(primaryKey));
  } catch (_) {
    return false;
  }
}

Future<String?> _currentSupabaseUserId() async {
  if (!SupabaseConfig.isConfigured) return null;
  try {
    return supabase.Supabase.instance.client.auth.currentUser?.id;
  } catch (_) {
    return null;
  }
}

final planningOutboxQueueProvider = Provider<PlanningOutboxQueue>((ref) {
  final db = ref.watch(appDatabaseProvider);
  return PlanningOutboxQueue(
    db: db,
    isSyncEnabled: _planningEntitySyncEnabled,
    getAuthUserId: _currentSupabaseUserId,
  );
});

final accountsPushServiceProvider = Provider<AccountsPushService>((ref) {
  final db = ref.watch(appDatabaseProvider);
  return AccountsPushService(
    db: db,
    queue: ref.watch(planningOutboxQueueProvider),
    isEnabled: _planningAccountsSyncEnabled,
  );
});

final accountsPullServiceProvider = Provider<AccountsPullService>((ref) {
  return AccountsPullService(
    db: ref.watch(appDatabaseProvider),
    isEnabled: _planningAccountsSyncEnabled,
  );
});

final planningPushServiceProvider = Provider<PlanningPushService>((ref) {
  return PlanningPushService(
    db: ref.watch(appDatabaseProvider),
    queue: ref.watch(planningOutboxQueueProvider),
    isEnabled: _planningEntitySyncEnabled,
  );
});

final planningPullServiceProvider = Provider<PlanningPullService>((ref) {
  return PlanningPullService(
    db: ref.watch(appDatabaseProvider),
    isEnabled: _planningEntitySyncEnabled,
  );
});

final planningSyncEngineProvider = Provider<PlanningSyncEngine>((ref) {
  return PlanningSyncEngine(
    accountsPushService: ref.watch(accountsPushServiceProvider),
    accountsPullService: ref.watch(accountsPullServiceProvider),
    planningPushService: ref.watch(planningPushServiceProvider),
    planningPullService: ref.watch(planningPullServiceProvider),
  );
});

final ledgerPushServiceProvider = Provider<LedgerPushService>((ref) {
  final db = ref.watch(appDatabaseProvider);
  return LedgerPushService(
    db: db,
    queue: ref.watch(ledgerOutboxQueueProvider),
    isPushEnabled: () {
      try {
        return featureFlags.getBool('ledger_push_sync') &&
            !featureFlags.getBool('transactions_supabase_primary');
      } catch (_) {
        return false;
      }
    },
  );
});

/// المرحلة 2: يوجّه القراءة/الكتابة إلى Supabase مباشرة عندما تكون علامة
/// transactions_supabase_primary مفعّلة لهذا المستخدم، وإلا فـ Drift كالمعتاد.
final transactionRepositoryProvider = Provider<TransactionRepository>((ref) {
  final db = ref.watch(appDatabaseProvider);
  return RoutedTransactionRepository(
    db: db,
    drift: DriftTransactionRepository(
      db,
      outboxQueue: ref.watch(ledgerOutboxQueueProvider),
    ),
    supabase: SupabaseTransactionRepository(db: db),
    flags: () => featureFlags,
  );
});

final suspectedDuplicateRepositoryProvider =
    Provider<SuspectedDuplicateRepository>((ref) {
  return DriftSuspectedDuplicateRepository(ref.watch(appDatabaseProvider));
});

final suspectedDuplicatesProvider =
    FutureProvider<List<SuspectedDuplicateEntity>>((ref) async {
  ref.watch(dbRevisionProvider);
  return ref.watch(suspectedDuplicateRepositoryProvider).getAll();
});

final smartInboxRepositoryProvider = Provider<SmartInboxRepository>((ref) {
  final db = ref.watch(appDatabaseProvider);
  return RoutedSmartInboxRepository(
    db: db,
    drift: DriftSmartInboxRepository(db),
    supabase: SupabaseSmartInboxRepository(db: db),
    flags: () => featureFlags,
  );
});

final smartInboxItemsProvider =
    FutureProvider<List<SmartInboxItemEntity>>((ref) async {
  ref.watch(appSessionRevisionProvider);
  ref.watch(dbRevisionProvider);
  return ref.watch(smartInboxRepositoryProvider).getOpen();
});

/// المرحلة 2: يوجّه القراءة/الكتابة إلى Supabase مباشرة عندما تكون علامة
/// accounts_supabase_primary مفعّلة لهذا المستخدم، وإلا فـ Drift كالمعتاد.
final accountRepositoryProvider = Provider<AccountRepository>((ref) {
  final db = ref.watch(appDatabaseProvider);
  return RoutedAccountRepository(
    db: db,
    drift: DriftAccountRepository(
      db,
      outboxQueue: ref.watch(planningOutboxQueueProvider),
    ),
    supabase: SupabaseAccountRepository(db: db),
    flags: () => featureFlags,
  );
});

/// قائمة الحسابات (تتحدّث عند الإضافة/التعديل عبر invalidate).
final accountsProvider = FutureProvider<List<AccountEntity>>((ref) async {
  ref.watch(appSessionRevisionProvider);
  ref.watch(dbRevisionProvider);
  return ref.watch(accountRepositoryProvider).getAll();
});

/// Makes authenticated data providers account-aware. The root ProviderScope
/// survives sign-out/sign-in, so without this dependency a FutureProvider can
/// keep the previous user's successful value in memory.
final appSessionRevisionProvider = StateProvider<int>((ref) {
  void onSessionChanged() => ref.controller.state += 1;

  AppSession.instance.addListener(onSessionChanged);
  ref.onDispose(
    () => AppSession.instance.removeListener(onSessionChanged),
  );
  return 0;
});

/// الحساب النشط عبر الشاشات الرئيسية. null يعني الحساب الافتراضي الحالي.
final activeAccountIdProvider = StateProvider<String?>((ref) {
  void resetSelectedAccount() => ref.controller.state = null;

  AppSession.instance.addListener(resetSelectedAccount);
  ref.onDispose(
    () => AppSession.instance.removeListener(resetSelectedAccount),
  );
  return null;
});

/// عملة الأساس للعرض في الشاشات العامة — من الحساب النشط، ثم الافتراضي، ثم
/// إعدادات المستخدم.
final baseCurrencyProvider = FutureProvider<String>((ref) async {
  ref.watch(dbRevisionProvider);
  final accountRepo = ref.watch(accountRepositoryProvider);
  final activeAccountId = ref.watch(activeAccountIdProvider);
  final activeAccount = activeAccountId == null
      ? null
      : await accountRepo.getById(activeAccountId);
  if (activeAccount != null) return activeAccount.currency;
  final account = await accountRepo.getDefault();
  if (account != null) return account.currency;
  final settings =
      await ref.watch(userSettingsRepositoryProvider).getSettings();
  return settings.currency;
});

/// Admin-managed brand logos keyed by uppercase merchant keyword. Empty until
/// the synced catalog carries `logo_url` values. UI resolves a merchant name
/// against these to show a real logo.
final merchantLogosProvider = FutureProvider<Map<String, String>>((ref) async {
  final db = ref.watch(appDatabaseProvider);
  final keywords = await RemoteMerchantKeywordsDao(db).getAll();
  return {
    for (final kw in keywords)
      if (kw.logoUrl != null && kw.logoUrl!.isNotEmpty)
        kw.keyword.toUpperCase(): kw.logoUrl!,
  };
});

final billRepositoryProvider = Provider<BillRepository>((ref) {
  final db = ref.watch(appDatabaseProvider);
  return RoutedBillRepository(
    db: db,
    drift: DriftBillRepository(
      db,
      outboxQueue: ref.watch(planningOutboxQueueProvider),
    ),
    supabase: SupabaseBillRepository(db: db),
    flags: () => featureFlags,
  );
});

final planRepositoryProvider = Provider<PlanRepository>((ref) {
  final db = ref.watch(appDatabaseProvider);
  return RoutedPlanRepository(
    db: db,
    drift: DriftPlanRepository(
      db,
      outboxQueue: ref.watch(planningOutboxQueueProvider),
    ),
    supabase: SupabasePlanRepository(db: db),
    flags: () => featureFlags,
  );
});

final merchantCategoryRepositoryProvider =
    Provider<MerchantCategoryRepository>((ref) {
  return DriftMerchantCategoryRepository(ref.watch(appDatabaseProvider));
});

final budgetRepositoryProvider = Provider<BudgetRepository>((ref) {
  final db = ref.watch(appDatabaseProvider);
  return RoutedBudgetRepository(
    db: db,
    drift: DriftBudgetRepository(
      db,
      outboxQueue: ref.watch(planningOutboxQueueProvider),
    ),
    supabase: SupabaseBudgetRepository(db: db),
    flags: () => featureFlags,
  );
});

final goalRepositoryProvider = Provider<GoalRepository>((ref) {
  final db = ref.watch(appDatabaseProvider);
  return RoutedGoalRepository(
    db: db,
    drift: DriftGoalRepository(
      db,
      outboxQueue: ref.watch(planningOutboxQueueProvider),
    ),
    supabase: SupabaseGoalRepository(db: db),
    flags: () => featureFlags,
  );
});

final gamificationRepositoryProvider = Provider<GamificationRepository>((ref) {
  return DriftGamificationRepository(ref.watch(appDatabaseProvider));
});

final userSettingsRepositoryProvider = Provider<UserSettingsRepository>((ref) {
  return DriftUserSettingsRepository(ref.watch(appDatabaseProvider));
});

final categoryRepositoryProvider = Provider<CategoryRepository>((ref) {
  final db = ref.watch(appDatabaseProvider);
  return RoutedCategoryRepository(
    drift: DriftCategoryRepository(db),
    supabase: SupabaseCategoryRepository(db: db),
    flags: () => featureFlags,
  );
});

final dataPortabilityServiceProvider = Provider<DataPortabilityService>((ref) {
  return AppDataPortabilityService(
    db: ref.watch(appDatabaseProvider),
    accounts: ref.watch(accountRepositoryProvider),
    categories: ref.watch(categoryRepositoryProvider),
    transactions: ref.watch(transactionRepositoryProvider),
    settings: ref.watch(userSettingsRepositoryProvider),
    flags: () => featureFlags,
    getSupabase: SupabaseConfig.isConfigured
        ? () => supabase.Supabase.instance.client
        : null,
    repairFinancialCache:
        ref.watch(financialCacheRepairServiceProvider).repairAll,
  );
});

final recordEngagementUseCaseProvider =
    Provider<RecordEngagementUseCase>((ref) {
  return RecordEngagementUseCase(
    gamificationRepository: ref.watch(gamificationRepositoryProvider),
    transactionRepository: ref.watch(transactionRepositoryProvider),
    userSettingsRepository: ref.watch(userSettingsRepositoryProvider),
    onUpdate: (update) =>
        CelebrationRuntime.instance.pushAll(update.celebrations),
  );
});

final senderBankMappingRepositoryProvider =
    Provider<SenderBankMappingRepository>((ref) {
  return DriftSenderBankMappingRepository(ref.watch(appDatabaseProvider));
});

final resolveBankForSenderUseCaseProvider =
    Provider<ResolveBankForSenderUseCase>((ref) {
  return ResolveBankForSenderUseCase(
    mappingRepository: ref.watch(senderBankMappingRepositoryProvider),
  );
});

final bankDiscoveryClientProvider = Provider<BankDiscoveryClient?>((ref) {
  if (!SupabaseConfig.isConfigured) return null;
  return GeminiBankDiscoveryClient(
    edgeFunctionUrl: '${SupabaseConfig.url}/functions/v1/bank-discovery',
    getAnonJwt: () async =>
        supabase.Supabase.instance.client.auth.currentSession?.accessToken ??
        SupabaseConfig.anonKey,
  );
});

final bankDiscoveryServiceProvider = Provider<BankDiscoveryService?>((ref) {
  final client = ref.watch(bankDiscoveryClientProvider);
  if (client == null) return null;
  return BankDiscoveryService(
    mappingRepository: ref.watch(senderBankMappingRepositoryProvider),
    client: client,
    loadAiConsent: () async {
      final settings = await DriftUserSettingsRepository(
        ref.read(appDatabaseProvider),
      ).getSettings();
      return settings.aiConsentGranted;
    },
    loadInstallId: InstallId.get,
  );
});

final senderBankMappingSyncServiceProvider =
    Provider<SenderBankMappingSyncService?>((ref) {
  if (!SupabaseConfig.isConfigured) return null;
  return SenderBankMappingSyncService(
    repository: ref.watch(senderBankMappingRepositoryProvider),
    remoteStore: SupabaseSenderBankMappingRemoteStore(
      supabase.Supabase.instance.client,
    ),
    currentUserId: () => supabase.Supabase.instance.client.auth.currentUser?.id,
  );
});

final installIdProvider = FutureProvider<String>((ref) => InstallId.get());

final captureBackendClientProvider = Provider<CaptureBackendClient?>((ref) {
  if (!SupabaseConfig.isConfigured) return null;
  return CaptureBackendClient(
    supabaseUrl: SupabaseConfig.url,
    anonKey: SupabaseConfig.anonKey,
  );
});

final captureDeviceRegistrationServiceProvider =
    Provider<CaptureDeviceRegistrationService>((ref) {
  return CaptureDeviceRegistrationService(
    settingsRepository:
        DriftUserSettingsRepository(ref.watch(appDatabaseProvider)),
    client: ref.watch(captureBackendClientProvider),
  );
});

/// Phase 1 notification tracking (docs/NOTIFICATION_PIPELINE_AUDIT.md).
final notificationLogServiceProvider = Provider<NotificationLogService>((ref) {
  return NotificationLogService(ref.watch(appDatabaseProvider));
});

final notificationLogSyncServiceProvider =
    Provider<NotificationLogSyncService>((ref) {
  return NotificationLogSyncService(db: ref.watch(appDatabaseProvider));
});

final captureSyncServiceProvider = Provider<CaptureSyncService>((ref) {
  final db = ref.watch(appDatabaseProvider);
  final directTransactions = SupabaseTransactionRepository(db: db);
  return CaptureSyncService(
    settingsRepository: DriftUserSettingsRepository(db),
    transactionRepository: DriftTransactionRepository(db),
    dedupStore: DriftDedupStore(db),
    suspectedDuplicateRepository: DriftSuspectedDuplicateRepository(db),
    registrationService: ref.watch(captureDeviceRegistrationServiceProvider),
    accountRepository: ref.watch(accountRepositoryProvider),
    client: ref.watch(captureBackendClientProvider),
    directTransactionRepository: directTransactions,
    isSupabasePrimaryEnabled: () {
      try {
        return featureFlags.getBool('transactions_supabase_primary');
      } catch (_) {
        return false;
      }
    },
  );
});

final ledgerSyncServiceProvider = Provider<LedgerSyncService>((ref) {
  final db = ref.watch(appDatabaseProvider);
  return LedgerSyncService(
    db: db,
    transactionRepository: DriftTransactionRepository(db),
    dedupStore: DriftDedupStore(db),
    isPullEnabled: () {
      try {
        return featureFlags.getBool('ledger_pull_sync') &&
            !featureFlags.getBool('transactions_supabase_primary');
      } catch (_) {
        return false;
      }
    },
  );
});

final ledgerSyncEngineProvider = Provider<LedgerSyncEngine>((ref) {
  return LedgerSyncEngine(
    pushService: ref.watch(ledgerPushServiceProvider),
    pullService: ref.watch(ledgerSyncServiceProvider),
  );
});

final smartInboxSyncServiceProvider = Provider<SmartInboxSyncService>((ref) {
  final db = ref.watch(appDatabaseProvider);
  return SmartInboxSyncService(
    db: db,
    isPullEnabled: () {
      try {
        return featureFlags.getBool('smart_inbox_pull_sync') &&
            !featureFlags.getBool('smart_inbox_supabase_primary');
      } catch (_) {
        return false;
      }
    },
  );
});

final addTransactionUseCaseProvider = Provider<AddTransactionUseCase>((ref) {
  // Capture the DB once at build time. The async callbacks below run later
  // (during a slow AI call); reading `ref` inside them would throw if this
  // provider rebuilt in the meantime (e.g. installId resolving).
  final db = ref.watch(appDatabaseProvider);
  return AddTransactionUseCase(
    transactionRepository: ref.watch(transactionRepositoryProvider),
    merchantCategoryRepository: ref.watch(merchantCategoryRepositoryProvider),
    recordEngagementUseCase: ref.watch(recordEngagementUseCaseProvider),
    logMetric: ref.watch(metricsClientProvider).logEvent,
    loadBankProfiles: ref.watch(rulesClientProvider).localBankProfiles,
    loadRemoteKeywords: () async {
      final settings = await DriftUserSettingsRepository(db).getSettings();
      final country = settings.country;
      return country.isEmpty
          ? RemoteMerchantKeywordsDao(db).getAll()
          : RemoteMerchantKeywordsDao(db).getActiveForCountry(country);
    },
    noteMerchantFeedback: (keyword) =>
        PendingMerchantFeedbackDao(db).record(keyword),
    // Real-time category assist for unknown merchants: when neither rules nor
    // AI know the merchant, the enrich-merchant Edge Function looks it up via
    // Google Places, returns a category, and writes it to merchant_keywords for
    // every device. Only available when the backend is configured.
    resolveMerchantCategory: SupabaseConfig.isConfigured
        ? (keyword) async {
            try {
              final settings =
                  await DriftUserSettingsRepository(db).getSettings();
              final res = await supabase.Supabase.instance.client.functions
                  .invoke('enrich-merchant', body: {
                'merchant_name': keyword,
                'country_code': settings.country,
                'write': true,
                'install_id': await InstallId.get(),
              });
              final data = res.data;
              if (data is Map && data['matched'] == true) {
                return data['category'] as String?;
              }
            } catch (_) {
              // Network/auth failure — fall back to the feedback queue.
            }
            return null;
          }
        : null,
    accountRepository: ref.watch(accountRepositoryProvider),
    dedupStore: DriftDedupStore(db),
    aiClient: SupabaseConfig.isConfigured
        ? SupabaseAiParserClient(
            edgeFunctionUrl: '${SupabaseConfig.url}/functions/v1/parse-sms',
            getAnonJwt: () async =>
                supabase.Supabase.instance.client.auth.currentSession
                    ?.accessToken ??
                SupabaseConfig.anonKey,
          )
        : null,
    loadAiConsent: () async {
      final settings = await DriftUserSettingsRepository(db).getSettings();
      return settings.aiConsentGranted;
    },
    loadInstallId: InstallId.get,
    resolveBankForSenderUseCase: ref.watch(resolveBankForSenderUseCaseProvider),
    bankDiscoveryService: ref.watch(bankDiscoveryServiceProvider),
    suspectedDuplicateRepository:
        ref.watch(suspectedDuplicateRepositoryProvider),
  );
});

final saveManualTransactionUseCaseProvider =
    Provider<SaveManualTransactionUseCase>((ref) {
  return SaveManualTransactionUseCase(
    transactionRepository: ref.watch(transactionRepositoryProvider),
    recordEngagementUseCase: ref.watch(recordEngagementUseCaseProvider),
    logMetric: ref.watch(metricsClientProvider).logEvent,
    accountRepository: ref.watch(accountRepositoryProvider),
    suspectedDuplicateRepository:
        ref.watch(suspectedDuplicateRepositoryProvider),
  );
});

final ingestCapturedMessageUseCaseProvider =
    Provider<IngestCapturedMessageUseCase>((ref) {
  return IngestCapturedMessageUseCase(
    ref.watch(addTransactionUseCaseProvider),
  );
});

final confirmTransactionUseCaseProvider =
    Provider<ConfirmTransactionUseCase>((ref) {
  return ConfirmTransactionUseCase(
    ref.watch(transactionRepositoryProvider),
    recordEngagementUseCase: ref.watch(recordEngagementUseCaseProvider),
  );
});

final correctCategoryUseCaseProvider = Provider<CorrectCategoryUseCase>((ref) {
  return CorrectCategoryUseCase(
    transactionRepository: ref.watch(transactionRepositoryProvider),
    merchantCategoryRepository: ref.watch(merchantCategoryRepositoryProvider),
    recordEngagementUseCase: ref.watch(recordEngagementUseCaseProvider),
  );
});

final saveBudgetUseCaseProvider = Provider<SaveBudgetUseCase>((ref) {
  return SaveBudgetUseCase(
    ref.watch(budgetRepositoryProvider),
    recordEngagementUseCase: ref.watch(recordEngagementUseCaseProvider),
  );
});

final deleteBudgetUseCaseProvider = Provider<DeleteBudgetUseCase>((ref) {
  return DeleteBudgetUseCase(ref.watch(budgetRepositoryProvider));
});

final saveGoalUseCaseProvider = Provider<SaveGoalUseCase>((ref) {
  return SaveGoalUseCase(
    ref.watch(goalRepositoryProvider),
    recordEngagementUseCase: ref.watch(recordEngagementUseCaseProvider),
  );
});

final deleteGoalUseCaseProvider = Provider<DeleteGoalUseCase>((ref) {
  return DeleteGoalUseCase(ref.watch(goalRepositoryProvider));
});

final addGoalContributionUseCaseProvider =
    Provider<AddGoalContributionUseCase>((ref) {
  return AddGoalContributionUseCase(
    ref.watch(goalRepositoryProvider),
    recordEngagementUseCase: ref.watch(recordEngagementUseCaseProvider),
    notifyGoalMilestone: (goal, beforeProgress, afterProgress) async {
      final loadPrefs = ref.read(loadNotificationPreferencesUseCaseProvider);
      final savePrefs = ref.read(saveNotificationPreferencesUseCaseProvider);
      final preferences = await loadPrefs();
      final notification = const NotificationPlanner().planGoalMilestone(
        preferences: preferences,
        goal: goal,
        beforeProgress: beforeProgress,
        afterProgress: afterProgress,
      );
      if (notification == null) return;
      await LocalNotificationService.instance.showGoalMilestoneNotification(
        notification: notification,
        preferences: preferences,
      );
      await savePrefs(
        preferences.copyWith(
          notifiedGoalMilestones: {
            ...preferences.notifiedGoalMilestones,
            goal.id: notification.milestone,
          },
        ),
      );
    },
  );
});

final budgetProgressUseCaseProvider = Provider<BudgetProgressUseCase>((ref) {
  final useSupabaseSummary = supabaseBudgetProgressSummaryEnabled();
  final summaryService = ref.watch(supabaseFinancialSummaryServiceProvider);
  return BudgetProgressUseCase(
    budgetRepository: ref.watch(budgetRepositoryProvider),
    transactionRepository: ref.watch(transactionRepositoryProvider),
    recordEngagementUseCase: ref.watch(recordEngagementUseCaseProvider),
    fetchBatchSpent: useSupabaseSummary
        ? ({required from, required to}) =>
            summaryService.budgetProgressSummary(from: from, to: to)
        : null,
  );
});

final goalDetailsUseCaseProvider = Provider<GoalDetailsUseCase>((ref) {
  return GoalDetailsUseCase(ref.watch(goalRepositoryProvider));
});

final loadNotificationPreferencesUseCaseProvider =
    Provider<LoadNotificationPreferencesUseCase>((ref) {
  return LoadNotificationPreferencesUseCase(
    ref.watch(userSettingsRepositoryProvider),
  );
});

final saveNotificationPreferencesUseCaseProvider =
    Provider<SaveNotificationPreferencesUseCase>((ref) {
  return SaveNotificationPreferencesUseCase(
    ref.watch(userSettingsRepositoryProvider),
  );
});

final notificationJourneyServiceProvider =
    Provider<NotificationJourneyService>((ref) {
  return NotificationJourneyService(
    database: ref.watch(appDatabaseProvider),
    loadPreferences: ref.watch(loadNotificationPreferencesUseCaseProvider),
    savePreferences: ref.watch(saveNotificationPreferencesUseCaseProvider),
    campaignsDao: RemoteGrowthCampaignsDao(ref.watch(appDatabaseProvider)),
  );
});

final loadUserSettingsUseCaseProvider =
    Provider<LoadUserSettingsUseCase>((ref) {
  return LoadUserSettingsUseCase(ref.watch(userSettingsRepositoryProvider));
});

final saveCountryCurrencyUseCaseProvider =
    Provider<SaveCountryCurrencyUseCase>((ref) {
  return SaveCountryCurrencyUseCase(
    ref.watch(userSettingsRepositoryProvider),
    ref.watch(accountRepositoryProvider),
    ref.watch(transactionRepositoryProvider),
  );
});

final saveLanguageUseCaseProvider = Provider<SaveLanguageUseCase>((ref) {
  return SaveLanguageUseCase(ref.watch(userSettingsRepositoryProvider));
});
