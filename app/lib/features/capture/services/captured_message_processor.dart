import 'package:supabase_flutter/supabase_flutter.dart' as supabase;

import '../../../core/backend/supabase_config.dart';
import '../../../core/backend/rules_client.dart';
import '../../../core/utils/currency.dart';
import '../../../core/utils/install_id.dart';
import '../../../data/catalog/catalog_daos.dart';
import '../../../data/db/app_database.dart';
import '../../../data/repositories/drift_dedup_store.dart';
import '../../../data/repositories/drift_account_repository.dart';
import '../../../data/repositories/drift_gamification_repository.dart';
import '../../../data/repositories/drift_merchant_category_repository.dart';
import '../../../data/repositories/drift_sender_bank_mapping_repository.dart';
import '../../../data/repositories/drift_suspected_duplicate_repository.dart';
import '../../../data/repositories/drift_transaction_repository.dart';
import '../../../data/repositories/drift_user_settings_repository.dart';
import 'package:drift/drift.dart' show Variable;

import '../../../domain/entities/captured_message.dart';
import '../../../domain/entities/engagement_entities.dart';
import '../../../domain/services/bank_discovery_service.dart';
import '../../../domain/usecases/add_transaction_usecase.dart';
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
    final db = database ?? await AppDatabase.open();
    final shouldCloseDatabase = database == null;
    try {
      final settingsRepository = DriftUserSettingsRepository(db);
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
            )
          : null;
      final bankDiscoveryClient = SupabaseConfig.isConfigured
          ? GeminiBankDiscoveryClient(
              edgeFunctionUrl:
                  '${SupabaseConfig.url}/functions/v1/bank-discovery',
              getAnonJwt: () async => supabase
                  .Supabase.instance.client.auth.currentSession?.accessToken,
            )
          : null;
      final ingestUseCase = IngestCapturedMessageUseCase(
        AddTransactionUseCase(
          transactionRepository: DriftTransactionRepository(db),
          merchantCategoryRepository: DriftMerchantCategoryRepository(db),
          recordEngagementUseCase: engagementUseCase,
          loadBankProfiles: RulesClient(database: db).localBankProfiles,
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
                    final res = await supabase
                        .Supabase.instance.client.functions
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
          aiClient: aiParserClient,
          loadAiConsent: () async =>
              (await settingsRepository.getSettings()).aiConsentGranted,
          loadInstallId: InstallId.get,
          accountRepository: DriftAccountRepository(db),
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
                      (await settingsRepository.getSettings()).aiConsentGranted,
                  loadInstallId: InstallId.get,
                ),
        ),
      );

      final result = await ingestUseCase.fromCapturedMessage(message);

      if (showNotifications &&
          result.addTransactionResult.outcome == AddTransactionOutcome.added) {
        await _checkBudgetAlert(db, notificationPreferences);
      }

      if (showNotifications) {
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
            );
          case CapturedMessageDisposition.unprocessable:
            await LocalNotificationService.instance
                .showLightCaptureNotification(
              title: 'رسالة لم نتمكن من تحليلها',
              body: 'افتح قرش والصق الرسالة يدوياً للإضافة.',
              preferences: notificationPreferences,
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

  static Future<void> _checkBudgetAlert(
    AppDatabase db,
    NotificationPreferences prefs,
  ) async {
    // اسحب ميزانية الشهر الكلية (أول ميزانية نشطة من نوع all-expenses/monthly).
    final budgetRows = await db
        .customSelect(
          "SELECT amount FROM budgets "
          "WHERE is_all_expenses = 1 AND period = 'monthly' AND is_active = 1 "
          "LIMIT 1;",
        )
        .get();
    if (budgetRows.isEmpty) return;
    final limit = budgetRows.first.read<double>('amount');
    if (limit <= 0) return;

    final now = DateTime.now().toUtc();
    final monthStart = DateTime.utc(now.year, now.month, 1).toIso8601String();
    final spendRows = await db.customSelect(
      "SELECT COALESCE(SUM(amount), 0.0) AS total FROM transactions "
      "WHERE type = 'expense' AND status = 'confirmed' "
      "AND occurred_at >= ? AND occurred_at <= ?;",
      variables: [
        Variable.withString(monthStart),
        Variable.withString(now.toIso8601String()),
      ],
    ).get();
    final spent = spendRows.first.read<double>('total');
    final ratio = spent / limit;

    // ثلاث عتبات: 75% / 90% / تجاوز 100%.
    final bucket = ratio >= 1.0
        ? 3
        : ratio >= 0.9
            ? 2
            : ratio >= 0.75
                ? 1
                : 0;
    if (bucket == 0) return;

    // معرّف فريد لكل شهر + عتبة حتى لا يتكرر الإشعار.
    final notifId = 94000 + (now.year * 12 + now.month) * 10 + bucket;

    final daysInMonth = DateTime(now.year, now.month + 1, 0).day;
    final daysPassed = now.day.clamp(1, daysInMonth);
    final daysRemaining = (daysInMonth - daysPassed).clamp(0, daysInMonth);
    final dailyRate = spent / daysPassed;
    final projected = spent + dailyRate * daysRemaining;
    final remaining = (limit - spent).clamp(0.0, limit);

    final currency = (await db
                .customSelect(
                    "SELECT currency FROM accounts WHERE is_default = 1 LIMIT 1;")
                .get())
            .firstOrNull
            ?.read<String>('currency') ??
        '';

    String fmt(double v) => v.toStringAsFixed(0);

    final currencyLabel = Currency.arabicLabel(currency);

    late final String title, body;
    if (bucket == 3) {
      title = 'تجاوزت ميزانية الشهر';
      body = 'صرفت ${fmt(spent - limit)} $currencyLabel زيادة عن ميزانيتك.';
    } else if (bucket == 2) {
      title = 'ميزانيتك على وشك الاكتمال';
      body = 'بقيلك ${fmt(remaining)} $currencyLabel فقط — '
          'معدلك الحالي سيستهلكها في $daysRemaining يوم.';
    } else {
      title = 'وصلت ٧٥٪ من ميزانيتك';
      if (projected > limit) {
        body = 'بقيلك ${fmt(remaining)} $currencyLabel. '
            'إذا استمر معدلك قد تتجاوز الميزانية بـ${fmt(projected - limit)} $currencyLabel.';
      } else {
        body = 'بقيلك ${fmt(remaining)} $currencyLabel حتى نهاية الشهر.';
      }
    }

    final type = bucket == 3
        ? NotificationType.budgetOver
        : NotificationType.budgetWarning;

    await LocalNotificationService.instance.showBudgetAlert(
      title: title,
      body: body,
      type: type,
      preferences: prefs,
      notifId: notifId,
    );
  }
}
