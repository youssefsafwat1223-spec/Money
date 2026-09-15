
import 'id_generator.dart';
import '../security/secure_storage_options.dart';

/// Stable, device-scoped install identifier stored in secure storage.
/// Generated once on first launch and never changed.
class InstallId {
  InstallId._();

  static const _key = 'mali_install_id';
  static const _storage = SecureStorageOptions.storage;

  static String? _cached;

  static Future<String> get() async {
    if (_cached != null) return _cached!;
    final stored = await _storage.read(key: _key);
    if (stored != null && stored.isNotEmpty) {
      _cached = stored;
      return _cached!;
    }
    final fresh = IdGenerator.next();
    await _storage.write(key: _key, value: fresh);
    _cached = fresh;
    return _cached!;
  }
}
