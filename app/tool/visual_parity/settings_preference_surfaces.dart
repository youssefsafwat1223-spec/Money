// Offline QA only: real preference actions on a guarded memory database.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:money_companion/core/backend/supabase_config.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/security/lock_prompt_language.dart';
import 'package:money_companion/core/security/secure_storage_options.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/core/theme/theme_mode_controller.dart';
import 'package:money_companion/features/settings/settings_providers.dart';
import 'package:money_companion/features/settings/settings_screen.dart';
import 'package:money_companion/l10n/app_localizations.dart';

const visualParitySettingsPreferenceKeys = <String>['settingsLivePreferences'];
final _events = <String, int>{};
Map<String, int> visualParitySettingsPreferenceEvents() =>
    Map.unmodifiable(_events);

/// Captures only the two expressly authorized disposable-QA preference keys.
/// Never replaces a global storage/channel transport or reads any session key.
class _PreferenceMirrors {
  _PreferenceMirrors(this.language, this.theme, this.initialLanguage);
  final String? language;
  final String? theme;
  final String initialLanguage;
  Future<void>? _restoring;

  static Future<_PreferenceMirrors> capture() async => _PreferenceMirrors(
      await SecureStorageOptions.storage.read(key: 'app_lock_prompt_language'),
      await SecureStorageOptions.storage.read(key: 'app_theme_mode'),
      LockPromptLanguage.initialSettingsLanguage);

  Future<void> restore() => _restoring ??= _restore();
  Future<void> _restore() async {
    // Restore the process cache separately from the exact possibly-null raw key.
    await LockPromptLanguage.set(initialLanguage);
    for (final pair in [
      MapEntry('app_lock_prompt_language', language),
      MapEntry('app_theme_mode', theme),
    ]) {
      if (pair.value == null) {
        await SecureStorageOptions.storage.delete(key: pair.key);
      } else {
        await SecureStorageOptions.storage
            .write(key: pair.key, value: pair.value);
      }
    }
    _events.update('settingsPreferenceMirrorsRestored', (count) => count + 1,
        ifAbsent: () => 1);
  }
}

Future<bool> openVisualParitySettingsPreference(
    BuildContext context, WidgetRef ref, String key) async {
  if (!visualParitySettingsPreferenceKeys.contains(key)) return false;
  if (!kDebugMode || SupabaseConfig.isConfigured) {
    throw StateError('settings_preferences_requires_offline_debug');
  }
  final databases = await ref
      .read(appDatabaseProvider)
      .customSelect('PRAGMA database_list')
      .get();
  if (!databases.any((row) =>
      row.read<String>('name') == 'main' && row.read<String>('file').isEmpty)) {
    throw StateError('settings_preferences_requires_memory_database');
  }
  final mirrors = await _PreferenceMirrors.capture();
  if (!context.mounted) return false;
  _events.update('settingsPreferenceOpened', (count) => count + 1,
      ifAbsent: () => 1);
  unawaited(Navigator.of(context).push<void>(MaterialPageRoute<void>(
    builder: (_) => _PreferenceHost(mirrors: mirrors),
  )));
  return true;
}

class _PreferenceHost extends StatefulWidget {
  const _PreferenceHost({required this.mirrors});
  final _PreferenceMirrors mirrors;
  @override
  State<_PreferenceHost> createState() => _PreferenceHostState();
}

class _PreferenceHostState extends State<_PreferenceHost> {
  @override
  void dispose() {
    // Parent controller waits for the restoration event before the next case.
    unawaited(widget.mirrors.restore());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ProviderScope(overrides: [
        // Actual controller and actual two-key-only storage, scoped to this canvas.
        themeModeProvider.overrideWith((ref) => ThemeModeController()),
      ], child: const _LivePreferenceCanvas());
}

class _LivePreferenceCanvas extends ConsumerWidget {
  const _LivePreferenceCanvas();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final language = ref.watch(userSettingsProvider).valueOrNull?.language;
    return MaterialApp(
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: ref.watch(themeModeProvider),
      locale: Locale(language == 'ar' ? 'ar' : 'en'),
      supportedLocales: AppL10n.supportedLocales,
      localizationsDelegates: AppL10n.localizationsDelegates,
      // Its own Navigator also contains Settings' public picker overlays.
      home: const SettingsScreen(showBackButton: true),
    );
  }
}
