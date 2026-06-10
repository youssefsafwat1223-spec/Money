import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/di/app_providers.dart';
import '../../domain/entities/engagement_entities.dart';
import '../../domain/entities/supporting_entities.dart';

final userSettingsProvider = FutureProvider<UserSettingsEntity>((ref) async {
  return ref.watch(loadUserSettingsUseCaseProvider).call();
});

final notificationPreferencesProvider =
    FutureProvider<NotificationPreferences>((ref) async {
  return ref.watch(loadNotificationPreferencesUseCaseProvider).call();
});

void refreshNotificationPreferences(WidgetRef ref) {
  ref.invalidate(notificationPreferencesProvider);
}

void refreshUserSettings(WidgetRef ref) {
  ref.invalidate(userSettingsProvider);
}
