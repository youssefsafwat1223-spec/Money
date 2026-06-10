import '../../../data/db/app_database.dart';
import '../../../data/repositories/drift_gamification_repository.dart';
import '../../../data/repositories/drift_merchant_category_repository.dart';
import '../../../data/repositories/drift_transaction_repository.dart';
import '../../../data/repositories/drift_user_settings_repository.dart';
import '../../../domain/usecases/add_transaction_usecase.dart';
import '../../../domain/usecases/engagement_usecase.dart';
import '../../../domain/usecases/ingest_captured_message_usecase.dart';
import '../../../domain/usecases/user_settings_usecases.dart';
import 'local_notification_service.dart';

class CapturedMessageProcessor {
  const CapturedMessageProcessor._();

  static Future<CapturedMessageResult> process({
    required String rawMessage,
    String? senderId,
    bool showNotifications = true,
  }) async {
    final database = await AppDatabase.open();
    try {
      final settingsRepository = DriftUserSettingsRepository(database);
      final engagementUseCase = RecordEngagementUseCase(
        gamificationRepository: DriftGamificationRepository(database),
        transactionRepository: DriftTransactionRepository(database),
        userSettingsRepository: settingsRepository,
      );
      final notificationPreferences =
          await LoadNotificationPreferencesUseCase(settingsRepository).call();
      final ingestUseCase = IngestCapturedMessageUseCase(
        AddTransactionUseCase(
          transactionRepository: DriftTransactionRepository(database),
          merchantCategoryRepository:
              DriftMerchantCategoryRepository(database),
          recordEngagementUseCase: engagementUseCase,
        ),
      );

      final result = await ingestUseCase(
        rawMessage: rawMessage,
        senderId: senderId,
      );

      if (showNotifications) {
        switch (result.disposition) {
          case CapturedMessageDisposition.ignored:
            break;
          case CapturedMessageDisposition.notifyOnly:
            await LocalNotificationService.instance.showLightCaptureNotification(
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
      await database.close();
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
