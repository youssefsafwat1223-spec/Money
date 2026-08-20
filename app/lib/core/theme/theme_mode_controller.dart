import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// App appearance preference (فاتح / داكن / تلقائي).
///
/// Persisted as an app-level flag in `flutter_secure_storage` — like the other
/// [AppSession] flags, it is not financial data and deliberately not a DB
/// column, so adopting it needs no Drift migration. Loads once on creation;
/// [set] writes through immediately.
class ThemeModeController extends StateNotifier<ThemeMode> {
  ThemeModeController() : super(ThemeMode.system) {
    _load();
  }

  static const String _key = 'app_theme_mode';
  static const FlutterSecureStorage _storage = FlutterSecureStorage();

  Future<void> _load() async {
    final raw = await _storage.read(key: _key);
    state = _decode(raw);
  }

  Future<void> set(ThemeMode mode) async {
    if (mode == state) return;
    state = mode;
    await _storage.write(key: _key, value: _encode(mode));
  }

  static ThemeMode _decode(String? raw) {
    switch (raw) {
      case 'light':
        return ThemeMode.light;
      case 'dark':
        return ThemeMode.dark;
      default:
        return ThemeMode.system;
    }
  }

  static String _encode(ThemeMode mode) {
    switch (mode) {
      case ThemeMode.light:
        return 'light';
      case ThemeMode.dark:
        return 'dark';
      case ThemeMode.system:
        return 'system';
    }
  }
}

/// The active [ThemeMode]; watched by `MoneyApp` and the Settings appearance
/// toggle.
final themeModeProvider = StateNotifierProvider<ThemeModeController, ThemeMode>(
  (ref) => ThemeModeController(),
);
