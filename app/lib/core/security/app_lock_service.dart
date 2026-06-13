import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:local_auth/local_auth.dart';

class AppLockService {
  AppLockService._();

  static final AppLockService instance = AppLockService._();

  static const FlutterSecureStorage _storage = FlutterSecureStorage();
  static const String _kEnabled = 'app_lock_enabled';

  final LocalAuthentication _auth = LocalAuthentication();

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

  Future<bool> setEnabled(bool enabled) async {
    if (!enabled) {
      await _storage.write(key: _kEnabled, value: '0');
      return true;
    }
    final supported = await canAuthenticate();
    if (!supported) return false;
    final unlocked = await authenticate();
    if (!unlocked) return false;
    await _storage.write(key: _kEnabled, value: '1');
    return true;
  }

  Future<bool> authenticate() async {
    try {
      return await _auth.authenticate(
        localizedReason: 'افتح مالي لحماية بياناتك المالية.',
        options: const AuthenticationOptions(
          biometricOnly: false,
          stickyAuth: true,
          useErrorDialogs: true,
        ),
      );
    } catch (_) {
      return false;
    }
  }
}
