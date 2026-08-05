import 'dart:convert';
import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

abstract class DatabaseKeyStore {
  Future<String> readOrCreateKey();
  Future<String?> readStoredKey();
}

/// MALI-058n — the outcome of resolving the local database key at open time.
enum DatabaseKeyState {
  /// The encrypted DB already exists and its key is present in secure storage —
  /// or no DB exists yet but a key is present. Open proceeds with that key.
  keyPresent,

  /// No database and no key — a genuine first install. A new key may be created.
  freshInstall,

  /// An encrypted database EXISTS but its authoritative key is ABSENT from
  /// platform secure storage. The data is unrecoverable without it; we must NOT
  /// mint a new key, open with a new key, read a key from Drift/backup, or delete
  /// anything. Surfaced as [LocalDatabaseKeyUnavailableException].
  keyUnavailable,
}

/// Pure decision for the open-time key state (MALI-058n). Depends only on whether
/// the encrypted DB file exists and whether secure storage holds a non-empty key,
/// so it is exhaustively unit-testable without touching the filesystem.
DatabaseKeyState classifyDatabaseKeyState({
  required bool databaseExists,
  required String? storedKey,
}) {
  final hasKey = storedKey != null && storedKey.isNotEmpty;
  if (hasKey) return DatabaseKeyState.keyPresent;
  if (databaseExists) return DatabaseKeyState.keyUnavailable;
  return DatabaseKeyState.freshInstall;
}

/// Thrown when an encrypted local database exists but its SQLCipher key is missing
/// from platform secure storage. Distinguishable programmatically from a wrong
/// backup passphrase (a backup-decryption error) and from a corrupt-DB open
/// failure (a key is present but the file is unreadable). Carries NO key, path,
/// SQL, passphrase, or financial information.
class LocalDatabaseKeyUnavailableException implements Exception {
  const LocalDatabaseKeyUnavailableException();

  @override
  String toString() => 'LocalDatabaseKeyUnavailableException: the local database '
      'encryption key is missing from secure storage.';
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
