import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/capture/services/local_notification_service.dart';
import '../../features/settings/settings_providers.dart';

final localeProvider = Provider<Locale>((ref) {
  final settingsAsync = ref.watch(userSettingsProvider);
  return settingsAsync.maybeWhen(
    data: (settings) {
      final lang = settings.language;
      if (lang == 'en') {
        return const Locale('en');
      }
      return const Locale('ar');
    },
    orElse: () => const Locale('ar'),
  );
});

/// Pushes the active language into the notification service.
///
/// Notifications are raised from background isolates and plugin callbacks with
/// no element tree, so the service cannot read the locale the way a widget
/// does — it is told. Keeping the push next to the provider that owns the
/// answer means there is exactly one place where the two can disagree, and it
/// covers both first read and later changes, because `localeProvider` is
/// reactive.
final notificationLanguageSyncProvider = Provider<String>((ref) {
  final code = ref.watch(localeProvider).languageCode;
  LocalNotificationService.instance.notificationLanguage = code;
  return code;
});
