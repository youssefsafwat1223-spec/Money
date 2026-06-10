import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/di/app_providers.dart';
import '../../domain/entities/engagement_entities.dart';

final notificationPreferencesProvider =
    FutureProvider<NotificationPreferences>((ref) async {
  return ref.watch(loadNotificationPreferencesUseCaseProvider).call();
});

void refreshNotificationPreferences(WidgetRef ref) {
  ref.invalidate(notificationPreferencesProvider);
}
