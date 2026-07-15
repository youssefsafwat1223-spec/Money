import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/di/app_providers.dart';
import '../../domain/entities/engagement_entities.dart';
import '../../domain/entities/supporting_entities.dart';
import '../../domain/entities/transaction_entity.dart';
import '../capture/services/native_capture_bridge.dart';

const captureHealthNudgeThreshold = Duration(days: 7);

class CaptureHealthStatus {
  const CaptureHealthStatus({
    required this.lastCaptureAt,
    required this.now,
    this.apnsRegistrationFailure,
  });

  final DateTime? lastCaptureAt;
  final DateTime now;
  final ApnsRegistrationFailure? apnsRegistrationFailure;

  bool get hasCaptureHistory => lastCaptureAt != null;

  Duration? get gap {
    final last = lastCaptureAt;
    if (last == null) return null;
    final difference = now.difference(last);
    return difference.isNegative ? Duration.zero : difference;
  }

  bool get shouldNudge {
    final currentGap = gap;
    return apnsRegistrationFailure != null ||
        (currentGap != null && currentGap >= captureHealthNudgeThreshold);
  }
}

final userSettingsProvider = FutureProvider<UserSettingsEntity>((ref) async {
  ref.watch(dbRevisionProvider);
  return ref.watch(loadUserSettingsUseCaseProvider).call();
});

final notificationPreferencesProvider =
    FutureProvider<NotificationPreferences>((ref) async {
  ref.watch(dbRevisionProvider);
  return ref.watch(loadNotificationPreferencesUseCaseProvider).call();
});

final captureHealthStatusProvider =
    FutureProvider<CaptureHealthStatus>((ref) async {
  ref.watch(dbRevisionProvider);
  final transactions = await ref.watch(transactionRepositoryProvider).getAll();
  DateTime? latestCaptureAt;
  for (final transaction in transactions) {
    if (transaction.source != TransactionSourceEntity.bank) continue;
    final capturedAt = transaction.smsReceivedAt ?? transaction.createdAt;
    if (latestCaptureAt == null || capturedAt.isAfter(latestCaptureAt)) {
      latestCaptureAt = capturedAt;
    }
  }
  return CaptureHealthStatus(
    lastCaptureAt: latestCaptureAt,
    now: DateTime.now().toUtc(),
    apnsRegistrationFailure:
        await NativeCaptureBridge.getApnsRegistrationFailure(),
  );
});

void refreshNotificationPreferences(WidgetRef ref) {
  ref.invalidate(notificationPreferencesProvider);
}

void refreshUserSettings(WidgetRef ref) {
  ref.invalidate(userSettingsProvider);
}
