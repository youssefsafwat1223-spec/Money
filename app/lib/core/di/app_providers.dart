import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as supabase;

import '../backend/metrics_client.dart';
import '../backend/rules_client.dart';
import '../backend/supabase_config.dart';
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
import '../../data/repositories/drift_transaction_repository.dart';
import '../../data/repositories/drift_user_settings_repository.dart';
import '../../data/sync/sender_bank_mapping_sync_service.dart';
import '../../domain/entities/account_entity.dart';
import '../../domain/entities/suspected_duplicate_entity.dart';
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

final featureFlagServiceProvider = Provider<FeatureFlagService>((ref) {
  return FeatureFlagService(
    dao: RemoteFeatureFlagsDao(ref.watch(appDatabaseProvider)),
    installId: '', // replaced at runtime via initFeatureFlagService()
  );
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

/// Initialises the FeatureFlagService with the real install ID and loads
/// flags from Drift. Call once at startup before the first frame.
Future<FeatureFlagService> initFeatureFlagService(AppDatabase db) async {
  final id = await InstallId.get();
  final service = FeatureFlagService(
    dao: RemoteFeatureFlagsDao(db),
    installId: id,
  );
  await service.init();
  _featureFlagInstance = service;
  return service;
}

FeatureFlagService get featureFlags {
  if (_featureFlagInstance != null) return _featureFlagInstance!;
  throw StateError(
      'FeatureFlagService not initialised. Call syncCatalog first.');
}

final catalogSyncServiceProvider = Provider<CatalogSyncService>((ref) {
  final db = ref.watch(appDatabaseProvider);
  return CatalogSyncService(
    database: db,
    client: supabase.Supabase.instance.client,
    metadataDao: CatalogMetadataDao(db),
    featureFlagService: ref.watch(featureFlagServiceProvider),
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

final transactionRepositoryProvider = Provider<TransactionRepository>((ref) {
  return DriftTransactionRepository(ref.watch(appDatabaseProvider));
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

final accountRepositoryProvider = Provider<AccountRepository>((ref) {
  return DriftAccountRepository(ref.watch(appDatabaseProvider));
});

/// قائمة الحسابات (تتحدّث عند الإضافة/التعديل عبر invalidate).
final accountsProvider = FutureProvider<List<AccountEntity>>((ref) async {
  ref.watch(dbRevisionProvider);
  return ref.watch(accountRepositoryProvider).getAll();
});

/// الحساب النشط عبر الشاشات الرئيسية. null يعني الحساب الافتراضي الحالي.
final activeAccountIdProvider = StateProvider<String?>((ref) => null);

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
  return DriftBillRepository(ref.watch(appDatabaseProvider));
});

final planRepositoryProvider = Provider<PlanRepository>((ref) {
  return DriftPlanRepository(ref.watch(appDatabaseProvider));
});

final merchantCategoryRepositoryProvider =
    Provider<MerchantCategoryRepository>((ref) {
  return DriftMerchantCategoryRepository(ref.watch(appDatabaseProvider));
});

final budgetRepositoryProvider = Provider<BudgetRepository>((ref) {
  return DriftBudgetRepository(ref.watch(appDatabaseProvider));
});

final goalRepositoryProvider = Provider<GoalRepository>((ref) {
  return DriftGoalRepository(ref.watch(appDatabaseProvider));
});

final gamificationRepositoryProvider = Provider<GamificationRepository>((ref) {
  return DriftGamificationRepository(ref.watch(appDatabaseProvider));
});

final userSettingsRepositoryProvider = Provider<UserSettingsRepository>((ref) {
  return DriftUserSettingsRepository(ref.watch(appDatabaseProvider));
});

final categoryRepositoryProvider = Provider<CategoryRepository>((ref) {
  return DriftCategoryRepository(ref.watch(appDatabaseProvider));
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
  return BudgetProgressUseCase(
    budgetRepository: ref.watch(budgetRepositoryProvider),
    transactionRepository: ref.watch(transactionRepositoryProvider),
    recordEngagementUseCase: ref.watch(recordEngagementUseCaseProvider),
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

final saveThemeModeUseCaseProvider = Provider<SaveThemeModeUseCase>((ref) {
  return SaveThemeModeUseCase(ref.watch(userSettingsRepositoryProvider));
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
