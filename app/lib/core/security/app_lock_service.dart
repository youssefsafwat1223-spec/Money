import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:local_auth/local_auth.dart';
import '../security/secure_storage_options.dart';

class AppLockService {
  AppLockService._();

  static final AppLockService instance = AppLockService._();

  static const FlutterSecureStorage _storage = SecureStorageOptions.storage;
  static const String _kEnabled = 'app_lock_enabled';

  final LocalAuthentication _auth = LocalAuthentication();
  DateTime? _lastSuccessfulAuthenticationAt;

  Future<bool> isEnabled() async {
    return await _storage.read(key: _kEnabled) == '1';
  }

  Future<bool> canAuthenticate() async {
    try {
      return await _auth.isDeviceSupported();
    } catch (_) {
      return false;
    }
  }

  /// The reason shown INSIDE the OS biometric sheet. That sheet is drawn by
  /// iOS/Android, not by Flutter, so the string must be handed over already
  /// localized — there is no BuildContext at the point `local_auth` is called,
  /// and no ARB lookup possible inside the platform dialog.
  ///
  /// Callers pass it from `context.l10n.lockPrompt`; the Arabic default is what
  /// every caller got before this parameter existed.
  static const String defaultPromptAr = 'افتح قِرش لحماية بياناتك المالية.';

  Future<bool> setEnabled(bool enabled, {String? reason}) async {
    if (!enabled) {
      await _storage.write(key: _kEnabled, value: '0');
      return true;
    }
    final supported = await canAuthenticate();
    if (!supported) return false;
    final unlocked = await authenticate(reason: reason);
    if (!unlocked) return false;
    await _storage.write(key: _kEnabled, value: '1');
    return true;
  }

  Future<bool> authenticate({String? reason}) async {
    try {
      final authenticated = await _auth.authenticate(
        localizedReason: reason ?? defaultPromptAr,
        options: const AuthenticationOptions(
          biometricOnly: false,
          stickyAuth: true,
          useErrorDialogs: true,
        ),
      );
      if (authenticated) {
        _lastSuccessfulAuthenticationAt = DateTime.now();
      }
      return authenticated;
    } catch (_) {
      return false;
    }
  }

  bool wasRecentlyAuthenticated(Duration window) {
    final lastAuthenticatedAt = _lastSuccessfulAuthenticationAt;
    if (lastAuthenticatedAt == null) return false;
    return DateTime.now().difference(lastAuthenticatedAt) <= window;
  }
}
