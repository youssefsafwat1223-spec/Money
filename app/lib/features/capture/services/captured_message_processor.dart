import '../../../core/privacy/consent_authority.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as supabase;

import '../../../core/backend/supabase_config.dart';
import '../../../core/backend/rules_client.dart';
import '../../../core/utils/currency.dart';
import '../../../core/utils/id_generator.dart';
import '../../../core/utils/install_id.dart';
import 'capture_device_registration_service.dart';
import '../../../data/catalog/catalog_daos.dart';
import 'dart:async';
import '../../../data/capture/proof_shadow_dao.dart';
import '../../../domain/capture/proof_commit_gate.dart';
import '../../../core/di/app_providers.dart' show featureFlags;
import '../../../data/db/app_database.dart';
import '../../../data/db/ownership_guard.dart';
import '../../../data/repositories/drift_budget_repository.dart';
import '../../../data/repositories/drift_card_repository.dart';
import '../../../data/repositories/drift_dedup_store.dart';
import '../../../data/repositories/drift_account_repository.dart';
import '../../../data/repositories/drift_gamification_repository.dart';
import '../../../data/repositories/drift_merchant_category_repository.dart';
import '../../../data/repositories/drift_sender_bank_mapping_repository.dart';
import '../../../data/repositories/drift_suspected_duplicate_repository.dart';
import '../../../data/repositories/drift_transaction_repository.dart';
import '../../../data/repositories/drift_user_settings_repository.dart';
import '../../planning_sync/services/outbox_queue_factory.dart';
import 'package:drift/drift.dart' show Variable;

import '../../../domain/entities/captured_message.dart';
import '../../../domain/entities/card_entity.dart';
import '../../../domain/entities/engagement_entities.dart';
import '../../../domain/entities/transaction_entity.dart';
import '../../../engine/parser/card_network.dart';
import '../../../domain/services/bank_discovery_service.dart';
import '../../../domain/services/budget_alert_planner.dart';
import '../../../domain/usecases/add_transaction_usecase.dart';
import '../../../domain/usecases/budget_progress_usecase.dart';
import '../../../domain/usecases/engagement_usecase.dart';
import '../../../domain/usecases/ingest_captured_message_usecase.dart';
import '../../../domain/usecases/resolve_bank_for_sender_usecase.dart';
import '../../../domain/usecases/user_settings_usecases.dart';
import '../../../engine/ai/ai_parser_client.dart';
import '../../../engine/ai/bank_discovery_client.dart';
import 'capture_notification_content.dart';
import 'local_notification_service.dart';

class CapturedMessageProcessor {
  const CapturedMessageProcessor._();

  static Future<CapturedMessageResult> process({
    required String rawMessage,
    String? senderId,
    CapturedMessageSource source = CapturedMessageSource.unknown,
    bool showNotifications = true,
    AppDatabase? database,
  }) async {
    return processCapturedMessage(
      CapturedMessage(
        text: rawMessage,
        senderId: senderId,
        source: source,
        receivedAt: DateTime.now().toUtc(),
      ),
      showNotifications: showNotifications,
      database: database,
    );
  }

  static Future<CapturedMessageResult> processCapturedMessage(
    CapturedMessage message, {
    bool showNotifications = true,
    AppDatabase? database,
  }) async {
    // MALI-069n §6/§Blocker-1 — when no shared database is supplied this is a
    // bounded SECONDARY connection to the same encrypted file: same key + PRAGMA
    // contract, no concurrent migrations, and it holds a CROSS-ISOLATE shared
    // lease (refused while file-exclusive maintenance is in progress). Always
    // closed in the finally below (which releases the lease).
    final shouldCloseDatabase = database == null;
    // MALI-069n §Blocker-1 — this background isolate does not share the owner
    // object in memory, so it binds to the current ADMISSION GENERATION and
    // re-validates at every boundary (points 1/2 in openSecondary, points 3/4/5
    // below). A previous session's capture never commits or notifies under a new
    // admission (sign-out / wipe / ownership change / same-UID re-login).
    final ownershipGuard = shouldCloseDatabase ? OwnershipGuard() : null;
    final admissionToken =
        ownershipGuard != null ? await ownershipGuard.capture() : null;
    final db = database ??
        await AppDatabase.openSecondary(
          leaseManager: await AppDatabase.appSupportLeaseManager(),
          ownershipGuard: ownershipGuard,
          admissionToken: admissionToken,
        );
    try {
      final settingsRepository = DriftUserSettingsRepository(db);
      // MALI-060n — the AI/enrichment endpoints authenticate on the server-
      // verified device secret. Read it once here and hand it to each client.
      final deviceRegistration = CaptureDeviceRegistrationService(
          settingsRepository: settingsRepository);
      Future<String?> loadDeviceSecret() =>
          deviceRegistration.readDeviceSecret();
      // Background/native captures must enter the sync pipeline like every
      // other write. The queues are auth-gated internally (guest → local-only).
      final ledgerOutbox = buildLedgerOutboxQueue(db);
      final planningOutbox = buildPlanningOutboxQueue(db);
      final engagementUseCase = RecordEngagementUseCase(
        gamificationRepository: DriftGamificationRepository(db),
        transactionRepository: DriftTransactionRepository(db),
        userSettingsRepository: settingsRepository,
      );
      final notificationPreferences =
          await LoadNotificationPreferencesUseCase(settingsRepository).call();
      // في الـ background isolate لا يكون historyStore مضبوطاً من main —
      // نربطه هنا حتى تظهر إشعارات الالتقاط في شاشة الرسائل أيضاً.
      LocalNotificationService.instance.historyStore ??= (entry) async {
        final preferences =
            await LoadNotificationPreferencesUseCase(settingsRepository).call();
        await SaveNotificationPreferencesUseCase(settingsRepository).call(
          preferences.copyWith(
            inboxState: preferences.inboxState.addHistory(entry),
          ),
        );
      };
      final senderBankMappingRepository = DriftSenderBankMappingRepository(db);
      final aiParserClient = SupabaseConfig.isConfigured
          ? SupabaseAiParserClient(
              edgeFunctionUrl: '${SupabaseConfig.url}/functions/v1/parse-sms',
              getAnonJwt: () async =>
                  supabase.Supabase.instance.client.auth.currentSession
                      ?.accessToken ??
                  SupabaseConfig.anonKey,
              loadDeviceSecret: loadDeviceSecret,
            )
          : null;
      final bankDiscoveryClient = SupabaseConfig.isConfigured
          ? GeminiBankDiscoveryClient(
              edgeFunctionUrl:
                  '${SupabaseConfig.url}/functions/v1/bank-discovery',
              getAnonJwt: () async => supabase
                  .Supabase.instance.client.auth.currentSession?.accessToken,
              loadDeviceSecret: loadDeviceSecret,
            )
          : null;
      final ingestUseCase = IngestCapturedMessageUseCase(
        AddTransactionUseCase(
          // PHASE 11 — the background capture path MUST carry the same Proof
          // wiring as the foreground one. This is where automatic bank SMS
          // actually flows, so a use case constructed without it would default
          // to shadow (safe) but record NOTHING — and Tier 2 would count zero
          // from the only path that matters at volume.
          proofGateMode: () => featureFlags.getBool('enable_proof_autocommit')
              ? ProofGateMode.armed
              : ProofGateMode.shadow,
          proofParserConfidenceMinPermille: () {
            final v = featureFlags.getInt('proof_parser_confidence_min');
            // Tune-upward-only, identical to the foreground clamp.
            return (v > ProofCommitGate.defaultParserConfidenceMinPermille &&
                    v <= 1000)
                ? v
                : ProofCommitGate.defaultParserConfidenceMinPermille;
          },
          recordProofShadow: (record) {
            unawaited(ProofShadowDao(db).record(record));
          },
          transactionRepository:
              DriftTransactionRepository(db, outboxQueue: ledgerOutbox),
          merchantCategoryRepository: DriftMerchantCategoryRepository(db),
          recordEngagementUseCase: engagementUseCase,
          loadBankProfiles: RulesClient(database: db).localBankProfiles,
          // F-016: raw catalog rules — the engine's first parsing authority.
          loadCatalogRules: RulesClient(database: db).catalogRulesForSender,
          loadRemoteKeywords: () async {
            final settings = await settingsRepository.getSettings();
            final country = settings.country;
            return country.isEmpty
                ? RemoteMerchantKeywordsDao(db).getAll()
                : RemoteMerchantKeywordsDao(db).getActiveForCountry(country);
          },
          noteMerchantFeedback: (keyword) =>
              PendingMerchantFeedbackDao(db).record(keyword),
          resolveMerchantCategory: SupabaseConfig.isConfigured
              ? (keyword) async {
                  try {
                    final settings = await settingsRepository.getSettings();
                    final deviceSecret = await loadDeviceSecret();
                    final res = await supabase
                        .Supabase.instance.client.functions
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
          aiClient: aiParserClient,
          loadAiConsent: () async =>
              ConsentAuthority.decide(EgressClass.aiProcessing,
                          await settingsRepository.getSettings()),
          loadInstallId: InstallId.get,
          accountRepository:
              DriftAccountRepository(db, outboxQueue: planningOutbox),
          dedupStore: DriftDedupStore(db),
          suspectedDuplicateRepository: DriftSuspectedDuplicateRepository(db),
          resolveBankForSenderUseCase: ResolveBankForSenderUseCase(
            mappingRepository: senderBankMappingRepository,
          ),
          bankDiscoveryService: bankDiscoveryClient == null
              ? null
              : BankDiscoveryService(
                  mappingRepository: senderBankMappingRepository,
                  client: bankDiscoveryClient,
                  loadAiConsent: () async =>
                      ConsentAuthority.decide(EgressClass.aiProcessing,
                          await settingsRepository.getSettings()),
                  loadInstallId: InstallId.get,
                ),
        ),
      );

      // Point 3 — re-validate immediately before the Drift commit. If the
      // admission changed while we were preparing, abort WITHOUT writing: the
      // capture belongs to a session that no longer owns this database.
      if (ownershipGuard != null &&
          admissionToken != null &&
          !await ownershipGuard.isCurrent(admissionToken)) {
        throw const StaleOwnershipException();
      }

      final result = await ingestUseCase.fromCapturedMessage(message);

      if (result.addTransactionResult.outcome == AddTransactionOutcome.added) {
        await _autoDetectCard(db, result.addTransactionResult.transaction);
      }

      if (showNotifications &&
          result.addTransactionResult.outcome == AddTransactionOutcome.added) {
        await checkBudgetAlert(db, notificationPreferences);
      }

      // Points 4/5 — re-validate before the native acknowledgement / any
      // notification side effect. A superseded session must never surface a
      // banner to whoever owns the device now.
      final ownershipStillValid = ownershipGuard == null ||
          admissionToken == null ||
          await ownershipGuard.isCurrent(admissionToken);
      if (showNotifications && ownershipStillValid) {
        switch (result.disposition) {
          case CapturedMessageDisposition.ignored:
            break;
          case CapturedMessageDisposition.notifyOnly:
            final content = buildConfirmedCaptureContent(
                result.addTransactionResult.transaction);
            await LocalNotificationService.instance
                .showLightCaptureNotification(
              title: content.title,
              body: content.body,
              preferences: notificationPreferences,
              stableId: result.notificationStableId,
            );
          case CapturedMessageDisposition.requestConfirmation:
            final transaction = result.addTransactionResult.transaction;
            if (transaction != null) {
              final content = buildReviewCaptureContent(
                  result.addTransactionResult.transaction);
              await LocalNotificationService.instance.showReviewNotification(
                transactionId: transaction.id,
                title: content.title,
                body: content.body,
                preferences: notificationPreferences,
              );
            }
          case CapturedMessageDisposition.suspiciousDuplicate:
            final content = buildDuplicateCaptureContent(
                result.addTransactionResult.transaction);
            await LocalNotificationService.instance
                .showLightCaptureNotification(
              title: content.title,
              body: content.body,
              preferences: notificationPreferences,
              stableId: result.notificationStableId,
            );
          case CapturedMessageDisposition.unprocessable:
            await LocalNotificationService.instance
                .showLightCaptureNotification(
              title: 'رسالة لم نتمكن من تحليلها',
              body: 'افتح قرش والصق الرسالة يدوياً للإضافة.',
              preferences: notificationPreferences,
              stableId: result.notificationStableId,
            );
        }
      }

      return result;
    } finally {
      if (shouldCloseDatabase) {
        await db.close();
      }
    }
  }

  /// Checks every active budget (any category, any period) against current
  /// spend and fires a local alert for each one crossing the 75%/90%/100%
  /// thresholds. Public so both the capture pipeline (below) and manual
  /// transaction entry (manual_transaction_sheet.dart) can call it after
  /// adding a transaction — a budget can be blown by either path.
  /// يربط عملية مُلتقَطة ببطاقة حقيقية: لو الحساب معروف وفيه آخر 4 أرقام ولا
  /// توجد بطاقة مطابقة، يُنشئ بطاقة تلقائية (source=auto). لو الحساب غير معروف
  /// أو لا يوجد رقم بطاقة، تُترك للتجميع المُشتَقّ («غير مخصّصة»). أفضل جهد —
  /// لا يكسر خط الالتقاط.
  static Future<void> _autoDetectCard(
    AppDatabase db,
    TransactionEntity? transaction,
  ) async {
    if (transaction == null) return;
    final accountId = transaction.accountId;
    final last4 = normalizeLast4(transaction.cardLast4);
    if (accountId == null || last4 == null) return;
    try {
      final cardRepo =
          DriftCardRepository(db, outboxQueue: buildPlanningOutboxQueue(db));
      if (await cardRepo.findByAccountAndLast4(accountId, last4) != null) {
        return;
      }
      await cardRepo.create(CardEntity(
        id: '',
        accountId: accountId,
        last4: last4,
        network: CardNetworkDetector.detect(transaction.rawMessage),
        source: CardSource.auto,
        createdAt: DateTime.now().toUtc(),
        updatedAt: DateTime.now().toUtc(),
      ));
    } catch (_) {
      // فشل ربط البطاقة يجب ألا يوقف الالتقاط.
    }
  }

  static Future<void> checkBudgetAlert(
    AppDatabase db,
    NotificationPreferences prefs,
  ) async {
    final progress = await BudgetProgressUseCase(
      budgetRepository: DriftBudgetRepository(db),
      transactionRepository: DriftTransactionRepository(db),
    )();
    if (progress.entries.isEmpty) return;

    final accountRepo = DriftAccountRepository(db);
    final defaultAccount = await accountRepo.getDefault();
    const planner = BudgetAlertPlanner();
    final now = DateTime.now().toUtc();

    for (final entry in progress.entries) {
      final budgetAccountId = entry.budget.accountId;
      final account = budgetAccountId == null
          ? defaultAccount
          : await accountRepo.getById(budgetAccountId);
      final currencyLabel = Currency.arabicLabel(
        account?.currency ?? defaultAccount?.currency ?? '',
      );
      final categoryLabel = entry.budget.isAllExpenses
          ? 'ميزانيتك الكلية'
          : await _categoryNameAr(db, entry.budget.categoryId) ??
              'ميزانية الفئة';

      final content = planner.plan(
        entry: entry,
        now: now,
        currencyLabel: currencyLabel,
        categoryLabel: categoryLabel,
        // UX-037 — the account was already resolved right here and never
        // reached the notification text.
        accountLabel: account?.name ?? defaultAccount?.name,
      );
      if (content == null) continue;

      await LocalNotificationService.instance.showBudgetAlert(
        title: content.title,
        body: content.body,
        type: content.type,
        preferences: prefs,
        notifId: content.notifId,
      );
    }
  }

  static Future<String?> _categoryNameAr(
    AppDatabase db,
    String categoryId,
  ) async {
    final rows = await db.customSelect(
      'SELECT name_ar FROM categories WHERE id = ? LIMIT 1;',
      variables: [Variable.withString(categoryId)],
    ).get();
    return rows.firstOrNull?.read<String>('name_ar');
  }
}
