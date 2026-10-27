import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'secure_storage_options.dart';

/// The language the OS unlock prompt must be drawn in.
///
/// ## Why a mirror exists at all
///
/// `AppLockGate` raises the prompt from a post-frame callback on the FIRST
/// frame — that is the point of the gate, and it must stay that way, because
/// anything later is a window in which the user's financial history is on
/// screen unauthenticated. At that instant the SQLCipher database has not been
/// opened, so `user_settings.language` is unreadable and `context.l10n` still
/// holds the app default. The prompt string is handed to iOS once, by value,
/// and the OS draws it; there is no second chance to correct it.
///
/// So the language is mirrored OUT of the database, into the same keychain that
/// already holds the lock flag itself. Reading it costs one local keychain
/// read — no database, no provider, no network, no bootstrap — and it happens
/// while the lock screen is already on top of the protected UI.
///
/// ## Why this design and not the previous one
///
/// An earlier attempt cached the language from a Riverpod provider. It passed
/// once and failed on the next run: a provider runs when something watches it,
/// which is not a point in time you can order against the process ending. The
/// mirror could be stale for exactly one launch — the launch that mattered.
///
/// This one is written by every path that writes `user_settings.language`, in
/// the same await chain as the database write, so the mirror is already correct
/// when that write returns. There are three such paths, and
/// `test/core/security/lock_prompt_language_writers_test.dart` fails if a
/// fourth appears:
///
///   1. `SaveLanguageUseCase` — Settings → Language, the only path a user can
///      take. It is the only writer that matters for the shipping flow.
///   2. `PlanningPullService` — a server row carrying a language, which is how
///      a second device inherits a choice made on the first.
///   3. `RestoreBackupUseCase` — a backup snapshot carrying a language.
///
/// Bootstrap also reads this mirror for fresh settings creation. Existing
/// database preferences are never replaced by it; explicit onboarding changes
/// update it through the same awaited save path as Settings.
abstract final class LockPromptLanguage {
  static const FlutterSecureStorage _storage = SecureStorageOptions.storage;
  static const String _key = 'app_lock_prompt_language';

  /// The app default, and the value `user_settings.language` is created with.
  static const String fallback = 'en';

  // Read once during bootstrap and updated only after a persisted choice.
  // Seeding a fresh settings row must not introduce Keychain I/O into an
  // account database open; lock prompts still read the durable mirror below.
  static String _initialSettingsLanguage = fallback;
  static String get initialSettingsLanguage => _initialSettingsLanguage;

  /// Mirrors [language] out of the settings row. Anything that is not a
  /// supported code is stored as [fallback] rather than rejected — a prompt in
  /// the wrong language is a defect; an exception thrown inside the lock is a
  /// lockout.
  static Future<void> set(String language) async {
    final supported = language == 'ar' ? 'ar' : fallback;
    await _storage.write(key: _key, value: supported);
    _initialSettingsLanguage = supported;
  }

  /// The mirrored language, or [fallback] when nothing has been mirrored yet —
  /// which is the English default for a new or unset preference.
  static Future<String> read() async {
    final stored = await _storage.read(key: _key);
    _initialSettingsLanguage = stored == 'ar' ? 'ar' : fallback;
    return _initialSettingsLanguage;
  }
}
