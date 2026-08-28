import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as supabase;

import '../auth/account_deletion_service.dart';
import '../backend/metrics_client.dart';
import '../backend/rules_client.dart';
import '../backend/supabase_config.dart';
import '../sync/conflict_policy.dart';
import '../sync/conflict_resolver.dart';
import '../sync/sync_capabilities.dart';
import '../sync/sync_wakeup.dart';
import '../session/app_session.dart';
import '../session/unsynced_inventory.dart';
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
import '../../core/utils/id_generator.dart';
import '../../core/utils/install_id.dart';
import '../../data/db/app_database.dart';
import '../privacy/consent_authority.dart';
import '../../data/db/planning_canonical_invariants.dart';
import '../../data/db/planning_cutover.dart';
import '../../data/repositories/account_deletion_service.dart';
import '../../data/repositories/drift_account_repository.dart';
import '../../data/repositories/drift_card_repository.dart';
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
import '../../data/sync/exact_transport_capability.dart';
import '../../data/sync/sender_bank_mapping_sync_service.dart';
import '../../domain/entities/account_entity.dart';
import '../../domain/entities/suspected_duplicate_entity.dart';
import '../../domain/entities/smart_inbox_item_entity.dart';
import '../../domain/finance/planning_mutation_guard.dart';
import '../../domain/repositories/account_repository.dart';
import '../../domain/repositories/card_repository.dart';
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
import '../../features/report_ads/report_ads_providers.dart';
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
import '../../features/planning_sync/services/planning_child_sync_service.dart';
import '../../features/planning_sync/services/planning_pull_service.dart';
import '../../features/planning_sync/services/planning_push_service.dart';
import '../../features/planning_sync/services/planning_startup_registration_service.dart';
import '../../features/planning_sync/services/planning_sync_engine.dart';
import '../../features/planning_sync/services/startup_sync_reconcile_service.dart';
import '../../domain/services/notification_planner.dart';

final appDatabaseProvider = Provider<AppDatabase>((ref) {
  throw UnimplementedError('AppDatabase must be provided from main().');
});

/// MALI-026 (B8-3 §1) — the ACTIVATED planning money-authority seam. The DB-marker
/// coordinator resolves the real cutover state from user_settings.planning_cutover_state
/// + a canonical-invariant recount. It starts at [PlanningCutoverState.canonical]
/// (a fresh v30 DB is canonical) and MUST be refreshed at bootstrap
/// (`refreshFromDatabase()` in main) to reflect an upgraded-with-data (unresolved)
/// database. Tests inject a fixed state via override for P1/P3 scenarios.
final planningCutoverCoordinatorProvider =
    Provider<PlanningCutoverCoordinator>((ref) {
  final db = ref.watch(appDatabaseProvider);
  return DbBackedPlanningCutoverCoordinator(
    initialState: PlanningCutoverState.canonical,
    readUserVersion: () async => (await db
            .customSelect('PRAGMA user_version;')
            .getSingle())
        .read<int>('user_version'),
    readMarker: () async => (await db
            .customSelect('SELECT planning_cutover_state AS s FROM user_settings;')
            .getSingle())
        .read<int>('s'),
    countCanonicalViolations: () async =>
        (await planningCanonicalViolations(db)).length,
  );
});

/// Central P1 mutation/delete guard. It is intentionally not called by current
/// v29 repositories yet, so registering it cannot alter live behavior.
final planningMutationGuardProvider = Provider<PlanningMutationGuard>((ref) {
  return PlanningMutationGuard(ref.watch(planningCutoverCoordinatorProvider));
});

/// Whether any local data existed at the moment bootstrap finished.
/// Overridden from main(). Home uses it to show the full-page skeleton only
/// on the very first, truly-empty launch — never on a normal cold start
/// where real data is about to appear. Defaults to `true` (no skeleton) so
/// an unwired test scope can never regress into skeleton-on-every-open.
final startupHasLocalDataProvider = Provider<bool>((ref) => true);

/// A monotonically-increasing counter that ticks on **every** database write
/// (any table). Read-providers `ref.watch` this so the whole app reflects new
/// data live — a captured/added transaction, a new account, a changed setting
/// — without a hot restart or a manual `invalidate`.
final dbRevisionProvider = StreamProvider<int>((ref) {
  final db = ref.watch(appDatabaseProvider);
  var revision = 0;
  final controller = StreamController<int>();
  // Writes arrive in bursts (startup seeding, sync bookkeeping, notification
  // logs). Emitting per-write invalidated slow watchers like
  // dashboardDataProvider faster than they could complete — the Home screen
  // sat in loading forever. Coalesce: one tick after a short quiet gap, with
  // a max wait so a long steady burst still surfaces data periodically.
  Timer? quiet;
  Timer? maxWait;
  void emit() {
    quiet?.cancel();
    quiet = null;
    maxWait?.cancel();
    maxWait = null;
    if (!controller.isClosed) controller.add(++revision);
  }

  void tick() {
    if (controller.isClosed) return;
    quiet?.cancel();
    quiet = Timer(const Duration(milliseconds: 300), emit);
    maxWait ??= Timer(const Duration(seconds: 2), emit);
  }

  final tableSub = db.tableUpdates().listen((_) => tick());
  final manualSub = db.manualRevisionStream.listen((_) => tick());
  ref.onDispose(() async {
    quiet?.cancel();
    maxWait?.cancel();
    await tableSub.cancel();
    await manualSub.cancel();
    await controller.close();
  });
  return controller.stream;
});

/// MALI-029 — coalescing shared by every revision provider so a write burst
/// (startup seed, batch import, sync) collapses to ONE rebuild, matching
/// [dbRevisionProvider]'s 300ms-quiet / 2s-max-wait behavior.
StreamController<int> _coalescedRevision(
  Ref ref,
  Stream<String> source,
  bool Function(String table) accept,
) {
  var revision = 0;
  final controller = StreamController<int>();
  Timer? quiet;
  Timer? maxWait;
  void emit() {
    quiet?.cancel();
    quiet = null;
    maxWait?.cancel();
    maxWait = null;
    if (!controller.isClosed) controller.add(++revision);
  }

  void tick() {
    if (controller.isClosed) return;
    quiet?.cancel();
    quiet = Timer(const Duration(milliseconds: 300), emit);
    maxWait ??= Timer(const Duration(seconds: 2), emit);
  }

  final sub = source.where(accept).listen((_) => tick());
  ref.onDispose(() async {
    quiet?.cancel();
    maxWait?.cancel();
    await sub.cancel();
    await controller.close();
  });
  return controller;
}

/// MALI-029 — a revision that ticks ONLY when a data write targets one of the
/// comma-joined [tablesKey] tables. Financial screens watch their own domain
/// instead of the global [dbRevisionProvider], so an unrelated-table write never
/// rebuilds them. The key MUST be a sorted, comma-joined table list (a stable
/// family key); use the `k*RevisionTables` constants below. Display dependencies
/// (e.g. `categories` for transaction rows) are included in each domain so a
/// dependent write still refreshes — providers never go stale.
final scopedRevisionProvider = StreamProvider.family<int, String>((ref, tablesKey) {
  final tables = tablesKey.split(',').toSet();
  final db = ref.watch(appDatabaseProvider);
  return _coalescedRevision(ref, db.tableWriteStream, tables.contains).stream;
});

/// Tables whose writes are pure bookkeeping / background operations and must NOT
/// rebuild financial screens — the documented sync/notification "flicker" source.
/// EXCLUSION (not enumeration) is deliberate: a new financial table is included in
/// [financialRevisionProvider] automatically; only writes we are certain are
/// non-display are filtered out. Gamification DISPLAY aggregates (achievements,
/// streaks, xp_levels) are intentionally NOT here — only the engagement OUTBOX is.
const kOperationalOnlyTables = <String>{
  'notification_log_events',
  'ledger_sync_outbox',
  'planning_sync_outbox',
  'parked_child_rows',
  'sync_cursors',
  'engagement_events',
  'dedup_hashes',
  'restore_operations',
  'financial_cache_health',
  'financial_import_runs',
  'catalog_metadata',
  'pending_merchant_feedback',
  'sender_bank_mappings',
  'smart_inbox_items',
  'suspected_duplicates',
  'remote_banks',
  'remote_parsers',
  'remote_currencies',
  'remote_countries',
  'remote_categories',
  'remote_merchant_keywords',
  'remote_feature_flags',
  'remote_announcements',
  'remote_growth_campaigns',
  'remote_coupons',
};

/// Domain table sets (sorted, comma-joined → stable family keys).
const kReportsRevisionTables = 'categories,transactions';
const kBudgetsRevisionTables = 'budgets,categories,transactions';
const kTransactionsRevisionTables = 'accounts,categories,transactions';

/// A revision for broad financial screens (the dashboard) that ticks on ANY write
/// except the purely-operational tables — so a notification-log / sync-cursor /
/// catalog write no longer rebuilds the whole financial UI, while every financial
/// write (including a brand-new financial table) still refreshes it.
final financialRevisionProvider = StreamProvider<int>((ref) {
  final db = ref.watch(appDatabaseProvider);
  return _coalescedRevision(
    ref,
    db.tableWriteStream,
    (table) => !kOperationalOnlyTables.contains(table),
  ).stream;
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
  // B2-C startup: the LOCAL init (cached flags) is what makes `featureFlags`
  // usable and MUST stay on the critical path (the getter throws otherwise). The
  // remote [applyUserOverrides] is a NETWORK refresh — bootstrap passes false so
  // it does not gate the first financial frame; the post-frame `syncCatalog`
  // already re-runs this with overrides applied. A fresh install renders with
  // safe default/cached flags for the first frame, then the post-frame refresh
  // lands the server values.
  bool applyRemoteOverrides = true,
}) async {
  final id = installIdOverride ?? await InstallId.get();
  final service = FeatureFlagService(
    dao: RemoteFeatureFlagsDao(db),
    installId: id,
  );
  await service.init();
  if (applyRemoteOverrides && SupabaseConfig.isConfigured) {
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

// MALI-063n — RETIRED. Dashboard/report/budget summaries were once read
// straight from Supabase RPCs (migration 0030), which carry PRE-canonical
// financial semantics (no refund netting, no half-open windows, no unified
// exclusion). That UI→Supabase path is gone: every financial surface computes
// from the canonical Drift aggregates. The gating flags and the
// `SupabaseFinancialSummaryService` provider were removed so the switch can no
// longer be flipped back on. The RPCs remain in 0030 marked historical; the
// service class survives only for the credential-gated contract tests. Do NOT
// re-wire it for reads without canonicalizing the RPCs first.

final accountDeletionServiceProvider = Provider<AccountDeletionService>((ref) {
  return AccountDeletionService();
});

final accountDeletionStatusProvider =
    FutureProvider<AccountDeletionStatus>((ref) {
  return ref.watch(accountDeletionServiceProvider).getStatus();
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
  // Same-session flag reactivity (R4 §9): the report-ads placement gate must
  // re-evaluate after a live catalog sync (cold-start / resume) so it can act
  // as a production kill switch without an app restart.
  ref.invalidate(reportAdsEnabledProvider);
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
    isPushEnabled: () => true,
    onQueued: SyncWakeup.notify,
    getAuthUserId: () async {
      if (!SupabaseConfig.isConfigured) return null;
      try {
        return supabase.Supabase.instance.client.auth.currentUser?.id;
      } catch (_) {
        return null;
      }
    },
    coordinator: ref.watch(planningCutoverCoordinatorProvider),
  );
});

// S5: sync is a signed-in capability, not a UI routing experiment. Auth gates
// inside the queue/services keep guests local-only.
bool _planningAccountsSyncEnabled() => true;

bool _planningEntitySyncEnabled(String entityType) {
  return const {
    PlanningOutboxQueue.accountsEntityType,
    PlanningOutboxQueue.budgetsEntityType,
    PlanningOutboxQueue.subscriptionsEntityType,
    PlanningOutboxQueue.goalsEntityType,
    PlanningOutboxQueue.plansEntityType,
    PlanningOutboxQueue.cardsEntityType,
    PlanningOutboxQueue.settingsEntityType,
    PlanningOutboxQueue.categoriesEntityType,
    PlanningOutboxQueue.billPaymentsEntityType,
    PlanningOutboxQueue.goalContributionsEntityType,
    PlanningOutboxQueue.planLinksEntityType,
  }.contains(entityType);
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
    onQueued: SyncWakeup.notify,
    coordinator: ref.watch(planningCutoverCoordinatorProvider),
  );
});

final accountsPushServiceProvider = Provider<AccountsPushService>((ref) {
  final db = ref.watch(appDatabaseProvider);
  return AccountsPushService(
    db: db,
    queue: ref.watch(planningOutboxQueueProvider),
    isEnabled: _planningAccountsSyncEnabled,
    coordinator: ref.watch(planningCutoverCoordinatorProvider),
    pushCapability: () => ref.read(exactPushTransportCapabilityProvider),
    // C-3 — money must not leave the device without cloud consent. Read fresh
    // per push so a revocation is observed by the next drain, not the next boot.
    mayEgress: () => ConsentAuthority(
          () => DriftUserSettingsRepository(ref.read(appDatabaseProvider))
              .getSettings(),
        ).allows(EgressClass.financialSync),
  );
});

final accountsPullServiceProvider = Provider<AccountsPullService>((ref) {
  final pullCap = ref.watch(exactPullTransportCapabilityProvider);
  return AccountsPullService(
    db: ref.watch(appDatabaseProvider),
    // Audit H-4: accounts PULL carries money (`initial_balance::text`,
    // `current_balance::text`). It shared `_planningAccountsSyncEnabled` — a
    // bare `() => true` — with push, so an explicitly `unsupported` transport
    // could not disable it: every row would throw and wedge the cursor instead
    // of the pull simply not running.
    isEnabled: () =>
        _planningAccountsSyncEnabled() && exactPullAllowed(pullCap),
  );
});

final planningPushServiceProvider = Provider<PlanningPushService>((ref) {
  return PlanningPushService(
    db: ref.watch(appDatabaseProvider),
    queue: ref.watch(planningOutboxQueueProvider),
    isEnabled: _planningEntitySyncEnabled,
    coordinator: ref.watch(planningCutoverCoordinatorProvider),
    pushCapability: () => ref.read(exactPushTransportCapabilityProvider),
    planningCurrencyCapability: () =>
        ref.read(planningServerCurrencyCapabilityProvider),
  );
});

/// MALI-026 (B8-3 §29/§30) — budgets/goals/goal_contributions carry per-row
/// planning currency that the SERVER only supports once 0077 is deployed AND the
/// capability is externally verified. Until then their cloud sync is DEFERRED
/// (never accept a legacy / missing-currency remote payload; never reconstruct a
/// currency from the base). Every other entity is unaffected. The gate depends
/// ONLY on the explicit capabilities — never on local schema/P3 state.
const _planningCurrencyGatedEntities = {
  PlanningOutboxQueue.budgetsEntityType,
  PlanningOutboxQueue.goalsEntityType,
  PlanningOutboxQueue.goalContributionsEntityType,
};

/// Direction-aware gate: a planning money entity syncs only when the SERVER
/// planning-currency capability AND that direction's exact decimal transport are
/// BOTH verified. [transportCap] is the exact PULL transport for pulls and the
/// exact PUSH transport for pushes. Non-planning entities keep their normal gate.
bool _planningEntitySyncEnabledWithCurrency(
  String entityType,
  ExactTransportCapability planningCurrencyCap,
  ExactTransportCapability transportCap,
) {
  if (!_planningEntitySyncEnabled(entityType)) return false;
  return planningMoneyEntitySyncEnabled(
    isPlanningCurrencyGatedEntity:
        _planningCurrencyGatedEntities.contains(entityType),
    planningCurrencyCapability: planningCurrencyCap,
    transportCapability: transportCap,
  );
}

final planningPullServiceProvider = Provider<PlanningPullService>((ref) {
  final planningCap = ref.watch(planningServerCurrencyCapabilityProvider);
  final pullCap = ref.watch(exactPullTransportCapabilityProvider);
  return PlanningPullService(
    db: ref.watch(appDatabaseProvider),
    // Audit H-4: the per-entity planning-currency gate only constrains the
    // three planning-currency entities — every OTHER money-bearing entity
    // (subscriptions, plans, bill_payments) short-circuited to `true` and so
    // never consulted the pull transport at all. The capability now applies to
    // the whole pull, with the planning gate layered on top.
    isEnabled: (entityType) =>
        exactPullAllowed(pullCap) &&
        _planningEntitySyncEnabledWithCurrency(
            entityType, planningCap, pullCap),
  );
});

final planningChildSyncServiceProvider =
    Provider<PlanningChildSyncService>((ref) {
  final planningCap = ref.watch(planningServerCurrencyCapabilityProvider);
  final pushCap = ref.watch(exactPushTransportCapabilityProvider);
  final pullCap = ref.watch(exactPullTransportCapabilityProvider);
  return PlanningChildSyncService(
    db: ref.watch(appDatabaseProvider),
    queue: ref.watch(planningOutboxQueueProvider),
    // §29/§30 — goal_contributions inherit the parent goal's server currency,
    // so they are deferred until the planning-currency + exact PUSH transport
    // capabilities are both verified (this is a push-direction service).
    // Pull authority is independent from push authority. The exact pull gate
    // covers every child family; the planning-currency gate layers on top for
    // goal contributions, using the pull-direction transport capability.
    isPullEnabled: (entityType) =>
        exactPullAllowed(pullCap) &&
        _planningEntitySyncEnabledWithCurrency(
            entityType, planningCap, pullCap),
    pullCapability: () => ref.read(exactPullTransportCapabilityProvider),
    isEnabled: (entityType) => _planningEntitySyncEnabledWithCurrency(
        entityType, planningCap, pushCap),
    coordinator: ref.watch(planningCutoverCoordinatorProvider),
    pushCapability: () => ref.read(exactPushTransportCapabilityProvider),
  );
});

final planningStartupRegistrationServiceProvider =
    Provider<PlanningStartupRegistrationService>((ref) {
  return PlanningStartupRegistrationService(
    db: ref.watch(appDatabaseProvider),
    queue: ref.watch(planningOutboxQueueProvider),
    isEnabled: _planningEntitySyncEnabled,
  );
});

final planningSyncEngineProvider = Provider<PlanningSyncEngine>((ref) {
  return PlanningSyncEngine(
    accountsPushService: ref.watch(accountsPushServiceProvider),
    accountsPullService: ref.watch(accountsPullServiceProvider),
    planningPushService: ref.watch(planningPushServiceProvider),
    planningPullService: ref.watch(planningPullServiceProvider),
    planningChildSyncService: ref.watch(planningChildSyncServiceProvider),
    startupRegistrationService:
        ref.watch(planningStartupRegistrationServiceProvider),
    conflictResolver: ref.watch(conflictResolverProvider),
  );
});

final ledgerPushServiceProvider = Provider<LedgerPushService>((ref) {
  final db = ref.watch(appDatabaseProvider);
  return LedgerPushService(
    db: db,
    queue: ref.watch(ledgerOutboxQueueProvider),
    isPushEnabled: () => true,
    coordinator: ref.watch(planningCutoverCoordinatorProvider),
    pushCapability: () => ref.read(exactPushTransportCapabilityProvider),
    // C-3 — money must not leave the device without cloud consent. Read fresh
    // per push so a revocation is observed by the next drain, not the next boot.
    mayEgress: () => ConsentAuthority(
          () => DriftUserSettingsRepository(ref.read(appDatabaseProvider))
              .getSettings(),
        ).allows(EgressClass.financialSync),
  );
});

/// الواجهة تقرأ/تكتب من Drift دائمًا؛ المزامنة خلفية عبر outbox/push/pull.
final transactionRepositoryProvider = Provider<TransactionRepository>((ref) {
  final db = ref.watch(appDatabaseProvider);
  return DriftTransactionRepository(
    db,
    outboxQueue: ref.watch(ledgerOutboxQueueProvider),
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
  return DriftSmartInboxRepository(db);
});

final smartInboxItemsProvider =
    FutureProvider<List<SmartInboxItemEntity>>((ref) async {
  ref.watch(appSessionRevisionProvider);
  ref.watch(dbRevisionProvider);
  return ref.watch(smartInboxRepositoryProvider).getOpen();
});

/// S5: الواجهة تقرأ/تكتب من Drift دائمًا؛ المزامنة خلفية عبر outbox/push/pull.
final accountRepositoryProvider = Provider<AccountRepository>((ref) {
  final db = ref.watch(appDatabaseProvider);
  return DriftAccountRepository(
    db,
    outboxQueue: ref.watch(planningOutboxQueueProvider),
  );
});

/// مستودع البطاقات الحقيقية (محلي في A1؛ مزامنة Supabase تُضاف في A1b).
final cardRepositoryProvider = Provider<CardRepository>((ref) {
  final db = ref.watch(appDatabaseProvider);
  return DriftCardRepository(
    db,
    outboxQueue: ref.watch(planningOutboxQueueProvider),
  );
});

/// MALI-053n/011: pre-sign-out inventory of locally-pending user artifacts.
final unsyncedInventoryServiceProvider =
    Provider<UnsyncedInventoryService>((ref) {
  return UnsyncedInventoryService(
    ref.watch(appDatabaseProvider),
    localOnlyCardCount:
        ref.watch(cardRepositoryProvider).countCapabilityGatedUnsyncedCards,
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
  return DriftBillRepository(
    db,
    outboxQueue: ref.watch(planningOutboxQueueProvider),
  );
});

final planRepositoryProvider = Provider<PlanRepository>((ref) {
  final db = ref.watch(appDatabaseProvider);
  return DriftPlanRepository(
    db,
    outboxQueue: ref.watch(planningOutboxQueueProvider),
  );
});

final merchantCategoryRepositoryProvider =
    Provider<MerchantCategoryRepository>((ref) {
  return DriftMerchantCategoryRepository(ref.watch(appDatabaseProvider));
});

final budgetRepositoryProvider = Provider<BudgetRepository>((ref) {
  final db = ref.watch(appDatabaseProvider);
  return DriftBudgetRepository(
    db,
    outboxQueue: ref.watch(planningOutboxQueueProvider),
    coordinator: ref.watch(planningCutoverCoordinatorProvider),
  );
});

final goalRepositoryProvider = Provider<GoalRepository>((ref) {
  final db = ref.watch(appDatabaseProvider);
  return DriftGoalRepository(
    db,
    outboxQueue: ref.watch(planningOutboxQueueProvider),
    coordinator: ref.watch(planningCutoverCoordinatorProvider),
  );
});

/// MALI-022 / MALI-057n — the universal, policy-driven conflict resolver
/// (replaces the planning-only resolver). Covers all twelve synced entities;
/// the keep-local re-enqueue is wired per interactive entity via its typed
/// repository + outbox queue, so resolving carries the current local state.
final conflictResolverProvider = Provider<UniversalConflictResolver>((ref) {
  final ledgerQueue = ref.watch(ledgerOutboxQueueProvider);
  final planningQueue = ref.watch(planningOutboxQueueProvider);
  final transactions = ref.watch(transactionRepositoryProvider);
  final accounts = ref.watch(accountRepositoryProvider);
  final budgets = ref.watch(budgetRepositoryProvider);
  final goals = ref.watch(goalRepositoryProvider);
  final bills = ref.watch(billRepositoryProvider);
  final plans = ref.watch(planRepositoryProvider);

  return UniversalConflictResolver(
    db: ref.watch(appDatabaseProvider),
    reEnqueue: {
      ConflictEntities.transaction: (id) async {
        final e = await transactions.getById(id);
        if (e != null) await ledgerQueue.enqueue(OutboxOperation.update, e);
      },
      ConflictEntities.account: (id) async {
        final e = await accounts.getById(id);
        if (e != null) {
          await planningQueue.enqueueAccount(PlanningSyncOperation.update, e);
        }
      },
      ConflictEntities.budget: (id) async {
        final e = await budgets.getById(id);
        if (e != null) {
          await planningQueue.enqueueBudget(PlanningSyncOperation.update, e);
        }
      },
      ConflictEntities.goal: (id) async {
        final e = await goals.getById(id);
        if (e != null) {
          await planningQueue.enqueueGoal(PlanningSyncOperation.update, e);
        }
      },
      ConflictEntities.subscription: (id) async {
        final e = await bills.getById(id);
        if (e != null) {
          await planningQueue.enqueueSubscription(
              PlanningSyncOperation.update, e);
        }
      },
      ConflictEntities.plan: (id) async {
        final e = await plans.getById(id);
        if (e != null) {
          await planningQueue.enqueuePlan(PlanningSyncOperation.update, e);
        }
      },
    },
    baseFetcher: SupabaseConfig.isConfigured
        ? (remoteTable, serverId) async {
            try {
              // Read `revision` only when the CAS capability is on — the column
              // exists on the server exactly when 0068 is deployed (same gate).
              const cols =
                  kServerRevisionCas ? 'updated_at, revision' : 'updated_at';
              final row = await supabase.Supabase.instance.client
                  .from(remoteTable)
                  .select(cols)
                  .eq('id', serverId)
                  .maybeSingle();
              if (row == null) return null;
              return ConflictBase(
                updatedAt: row['updated_at'] as String?,
                revision: (row['revision'] as num?)?.toInt(),
              );
            } catch (_) {
              return null;
            }
          }
        : null,
  );
});

/// The current unresolved conflicts across all interactive entities (drives the
/// resolution UI + badge).
final conflictsProvider = FutureProvider<List<SyncConflict>>((ref) {
  ref.watch(dbRevisionProvider); // refresh when any DB write lands
  return ref.watch(conflictResolverProvider).listConflicts();
});

/// MALI-016 — the authoritative, dependency-aware account-deletion path
/// (detach transactions; archive cards/budgets; reassign-or-archive goals &
/// subscriptions with currency checks; atomic; structured result).
final financialAccountDeletionServiceProvider =
    Provider<FinancialAccountDeletionService>((ref) {
  return FinancialAccountDeletionService(
    db: ref.watch(appDatabaseProvider),
    accounts: ref.watch(accountRepositoryProvider),
    cards: ref.watch(cardRepositoryProvider),
    budgets: ref.watch(budgetRepositoryProvider),
    goals: ref.watch(goalRepositoryProvider),
    bills: ref.watch(billRepositoryProvider),
  );
});

/// Fail-closed account-currency edit guard. Loading/error states remain locked
/// in the form; a successful `false` is the only state that permits an empty
/// existing account to change currency.
final accountHasTransactionsProvider =
    FutureProvider.family<bool, String>((ref, accountId) {
  return ref
      .watch(financialAccountDeletionServiceProvider)
      .hasTransactions(accountId);
});

final gamificationRepositoryProvider = Provider<GamificationRepository>((ref) {
  return DriftGamificationRepository(ref.watch(appDatabaseProvider));
});

final userSettingsRepositoryProvider = Provider<UserSettingsRepository>((ref) {
  return DriftUserSettingsRepository(
    ref.watch(appDatabaseProvider),
    outboxQueue: ref.watch(planningOutboxQueueProvider),
  );
});

final categoryRepositoryProvider = Provider<CategoryRepository>((ref) {
  final db = ref.watch(appDatabaseProvider);
  // S0: القراءة من Drift دائمًا. S3: الكتابات تُدرَج في الـ outbox وتُزامَن خلفيًا.
  return DriftCategoryRepository(
    db,
    outboxQueue: ref.watch(planningOutboxQueueProvider),
  );
});

final dataPortabilityServiceProvider = Provider<DataPortabilityService>((ref) {
  return AppDataPortabilityService(
    db: ref.watch(appDatabaseProvider),
    accounts: ref.watch(accountRepositoryProvider),
    categories: ref.watch(categoryRepositoryProvider),
    transactions: ref.watch(transactionRepositoryProvider),
    settings: ref.watch(userSettingsRepositoryProvider),
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
    loadDeviceSecret:
        ref.read(captureDeviceRegistrationServiceProvider).readDeviceSecret,
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
    db: ref.watch(appDatabaseProvider),
    remoteStore: SupabaseSenderBankMappingRemoteStore(
      supabase.Supabase.instance.client,
    ),
    currentUserId: () => supabase.Supabase.instance.client.auth.currentUser?.id,
    // C-3 — which banks the user holds is a direct read on their financial
    // life. Consulted fresh on every sync so a revocation is observed.
    mayEgress: () => ConsentAuthority(
          () => DriftUserSettingsRepository(ref.read(appDatabaseProvider))
              .getSettings(),
        ).allows(EgressClass.senderBankMappings),
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
  return NotificationLogSyncService(
    db: ref.watch(appDatabaseProvider),
    // C-3 — telemetry about the user's notifications.
    mayEgress: () => ConsentAuthority(
      () => DriftUserSettingsRepository(ref.read(appDatabaseProvider))
          .getSettings(),
    ).allows(EgressClass.telemetry),
  );
});

final captureSyncServiceProvider = Provider<CaptureSyncService>((ref) {
  final db = ref.watch(appDatabaseProvider);
  return CaptureSyncService(
    settingsRepository: DriftUserSettingsRepository(db),
    // Relay captures land in Drift AND enqueue on the ledger outbox, so the
    // background push publishes them to Supabase exactly like a manual add.
    transactionRepository: DriftTransactionRepository(
      db,
      outboxQueue: ref.watch(ledgerOutboxQueueProvider),
    ),
    dedupStore: DriftDedupStore(db),
    suspectedDuplicateRepository: DriftSuspectedDuplicateRepository(db),
    registrationService: ref.watch(captureDeviceRegistrationServiceProvider),
    accountRepository: ref.watch(accountRepositoryProvider),
    client: ref.watch(captureBackendClientProvider),
    coordinator: ref.watch(planningCutoverCoordinatorProvider),
  );
});

final ledgerSyncServiceProvider = Provider<LedgerSyncService>((ref) {
  final pullCap = ref.watch(exactPullTransportCapabilityProvider);
  final db = ref.watch(appDatabaseProvider);
  return LedgerSyncService(
    db: db,
    transactionRepository: DriftTransactionRepository(db),
    dedupStore: DriftDedupStore(db),
    // Audit H-4: the ledger pull carries money (`amount::text`,
    // `balance_after::text`, `foreign_amount::text`) and had no seam to be
    // switched off.
    isPullEnabled: () => exactPullAllowed(pullCap),
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
    isPullEnabled: () => true,
    // C-3 — Smart Inbox items are user data. `isPullEnabled` above is a FEATURE
    // gate hardcoded open; consent is a separate question and must be asked.
    mayEgress: () => ConsentAuthority(
      () => DriftUserSettingsRepository(ref.read(appDatabaseProvider))
          .getSettings(),
    ).allows(EgressClass.smartInbox),
  );
});

/// One idempotent reconcile of local accounts/transactions that never reached
/// Supabase (pre-outbox data, the migration-seeded default account, or a
/// background capture that had no session at write time). See
/// [StartupSyncReconcileService].
final startupSyncReconcileServiceProvider =
    Provider<StartupSyncReconcileService>((ref) {
  return StartupSyncReconcileService(
    // Audit H-4: the backfills are a push path; same authority as the outbox.
    pushCapability: () => ref.read(exactPushTransportCapabilityProvider),
    db: ref.watch(appDatabaseProvider),
    coordinator: ref.watch(planningCutoverCoordinatorProvider),
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
    // F-016: raw catalog rules — the engine's first parsing authority.
    loadCatalogRules: ref.watch(rulesClientProvider).catalogRulesForSender,
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
              final deviceSecret = await ref
                  .read(captureDeviceRegistrationServiceProvider)
                  .readDeviceSecret();
              final res = await supabase.Supabase.instance.client.functions
                  .invoke('enrich-merchant', body: {
                'merchant_name': keyword,
                'country_code': settings.country,
                'write': true,
                'install_id': await InstallId.get(),
                if (deviceSecret != null && deviceSecret.isNotEmpty)
                  'device_secret': deviceSecret,
                'request_id': IdGenerator.uuidV4(),
                'schema_version': 1,
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
            loadDeviceSecret: ref
                .read(captureDeviceRegistrationServiceProvider)
                .readDeviceSecret,
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
    coordinator: ref.watch(planningCutoverCoordinatorProvider),
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
  // MALI-063n: the dormant Supabase budget-summary batch-fetch (pre-canonical
  // semantics) is retired — budget consumption is always the canonical Drift
  // path.
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
