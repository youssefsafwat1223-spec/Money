import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../di/app_providers.dart';

ThemeMode themeModeFromKey(String key) {
  switch (key) {
    case 'light':
      return ThemeMode.light;
    case 'dark':
      return ThemeMode.dark;
    default:
      return ThemeMode.system;
  }
}

String themeModeToKey(ThemeMode mode) {
  switch (mode) {
    case ThemeMode.light:
      return 'light';
    case ThemeMode.dark:
      return 'dark';
    case ThemeMode.system:
      return 'system';
  }
}

final persistedThemeModeProvider = FutureProvider<ThemeMode>((ref) async {
  final settings = await ref.watch(loadUserSettingsUseCaseProvider).call();
  return themeModeFromKey(settings.theme);
});

/// Override فوري عند تغيير المستخدم، ثم يُحفظ في user_settings.
final themeModeOverrideProvider = StateProvider<ThemeMode?>((ref) => null);

final themeModeProvider = Provider<ThemeMode>((ref) {
  final override = ref.watch(themeModeOverrideProvider);
  if (override != null) return override;
  return ref.watch(persistedThemeModeProvider).maybeWhen(
        data: (mode) => mode,
        orElse: () => ThemeMode.system,
      );
});
