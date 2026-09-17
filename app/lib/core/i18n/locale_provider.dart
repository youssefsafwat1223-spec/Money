import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/capture/services/local_notification_service.dart';
import '../../features/settings/settings_providers.dart';

/// The app's language, held across a settings reload.
///
/// This used to be `maybeWhen(data: ..., orElse: () => const Locale('ar'))`.
/// `orElse` fires on every `AsyncLoading` frame as well as on error — and
/// `userSettingsProvider` watches `dbRevisionProvider`, so it reloads after
/// **every database write**. An English reader's app therefore dropped to
/// Arabic for a frame each time anything was saved, and stayed there for as
/// long as the reload took.
///
/// That is not a theoretical flicker. The restore overlay covers the whole
/// screen immediately after sign-in, over exactly that window: captured on an
/// English device, `AppBootLoader` read «جارٍ تجهيز التطبيق...». The ARB was
/// correct and so was the widget; the locale underneath them was not.
///
/// `valueOrNull` keeps the previous answer while the future is in flight, so a
/// reload no longer changes the language. Arabic remains the fallback for the
/// genuine first read, when there is no saved preference yet — this is an
/// Arabic-first app, and that default is deliberate.
final localeProvider = Provider<Locale>((ref) {
  final settings = ref.watch(userSettingsProvider).valueOrNull;
  return settings?.language == 'en' ? const Locale('en') : const Locale('ar');
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
