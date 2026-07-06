import 'dart:convert';
import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

abstract class DatabaseKeyStore {
  Future<String> readOrCreateKey();
  Future<String?> readStoredKey();
}

class SecureDatabaseKeyStore implements DatabaseKeyStore {
  SecureDatabaseKeyStore({
    FlutterSecureStorage? storage,
    this.storageKey = defaultStorageKey,
  }) : _storage = storage ?? const FlutterSecureStorage();

  /// Secure-storage key under which the SQLCipher DB key is kept. Exposed so
  /// account/data wipes can preserve it — deleting it while the encrypted DB
  /// file still exists leaves the database unopenable on next launch.
  static const String defaultStorageKey = 'money_companion.db_key';

  final FlutterSecureStorage _storage;
  final String storageKey;

  static final Random _random = Random.secure();

  @override
  Future<String> readOrCreateKey() async {
    final existing = await _storage.read(key: storageKey);
    if (existing != null && existing.isNotEmpty) {
      return existing;
    }

    final bytes = List<int>.generate(32, (_) => _random.nextInt(256));
    final key = base64UrlEncode(bytes).replaceAll('=', '');
    await _storage.write(key: storageKey, value: key);
    return key;
  }

  @override
  Future<String?> readStoredKey() {
    return _storage.read(key: storageKey);
  }
}
