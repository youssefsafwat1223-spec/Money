import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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
