import 'package:supabase_flutter/supabase_flutter.dart' as supabase;

import '../../../core/backend/supabase_config.dart';
import '../../../core/backend/rules_client.dart';
import '../../../data/db/app_database.dart';
import '../../../data/repositories/drift_account_repository.dart';
import '../../../data/repositories/drift_gamification_repository.dart';
import '../../../data/repositories/drift_merchant_category_repository.dart';
import '../../../data/repositories/drift_sender_bank_mapping_repository.dart';
import '../../../data/repositories/drift_transaction_repository.dart';
import '../../../data/repositories/drift_user_settings_repository.dart';
import '../../../domain/entities/captured_message.dart';
import '../../../domain/services/bank_discovery_service.dart';
import '../../../domain/usecases/add_transaction_usecase.dart';
import '../../../domain/usecases/engagement_usecase.dart';
import '../../../domain/usecases/ingest_captured_message_usecase.dart';
import '../../../domain/usecases/resolve_bank_for_sender_usecase.dart';
import '../../../domain/usecases/user_settings_usecases.dart';
import '../../../engine/ai/bank_discovery_client.dart';
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
      final senderBankMappingRepository = DriftSenderBankMappingRepository(db);
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
          accountRepository: DriftAccountRepository(db),
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
                ),
        ),
      );

      final result = await ingestUseCase.fromCapturedMessage(message);

      if (showNotifications) {
        switch (result.disposition) {
          case CapturedMessageDisposition.ignored:
            break;
          case CapturedMessageDisposition.notifyOnly:
            await LocalNotificationService.instance
                .showLightCaptureNotification(
              title: 'تم التقاط العملية',
              body: _buildConfirmedBody(result.addTransactionResult),
              preferences: notificationPreferences,
            );
          case CapturedMessageDisposition.requestConfirmation:
            final transaction = result.addTransactionResult.transaction;
            if (transaction != null) {
              await LocalNotificationService.instance.showReviewNotification(
                transactionId: transaction.id,
                body: _buildReviewBody(result.addTransactionResult),
                preferences: notificationPreferences,
              );
            }
        }
      }

      return result;
    } finally {
      if (shouldCloseDatabase) {
        await db.close();
      }
    }
  }

  static String _buildConfirmedBody(AddTransactionResult result) {
    final transaction = result.transaction;
    if (transaction == null) {
      return 'أضفنا العملية إلى سجلك.';
    }
    final merchant = transaction.rawMerchant;
    final amount = transaction.amount.toStringAsFixed(2);
    return merchant == null
        ? 'أضفنا عملية بقيمة $amount ${transaction.currency}.'
        : 'أضفنا $amount ${transaction.currency} لدى $merchant.';
  }

  static String _buildReviewBody(AddTransactionResult result) {
    final transaction = result.transaction;
    if (transaction == null) {
      return 'راجِع العملية الجديدة وأكّدها.';
    }
    final merchant = transaction.rawMerchant;
    final amount = transaction.amount.toStringAsFixed(2);
    return merchant == null
        ? 'راجِع عملية بقيمة $amount ${transaction.currency}.'
        : 'راجِع $amount ${transaction.currency} لدى $merchant.';
  }
}
