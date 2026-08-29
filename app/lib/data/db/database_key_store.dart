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

/// Outcome of a secure-storage wipe that must preserve the SQLCipher key.
class SecureStorageWipeResult {
  const SecureStorageWipeResult({required this.deleted, required this.failed});

  final List<String> deleted;

  /// Entries that could not be removed even after a retry. Non-empty means the
  /// local wipe is INCOMPLETE — the caller must not report success.
  final List<String> failed;

  bool get isComplete => failed.isEmpty;
}

/// Thrown when a local wipe could not remove every non-preserved secure-storage
/// entry. Deliberately loud: silently claiming "all your data is deleted" while
/// credentials or backup material survive is worse than a visible failure.
/// Carries only a COUNT — never a key name or value.
class SecureStorageWipeIncompleteException implements Exception {
  const SecureStorageWipeIncompleteException(this.remaining);
  final int remaining;

  @override
  String toString() =>
      'SecureStorageWipeIncompleteException: $remaining secure-storage '
      'entrie(s) could not be removed.';
}

/// Audit **H-8**. Clears secure storage WITHOUT ever deleting the SQLCipher key.
///
/// The previous implementation was `read(dbKey) → deleteAll() → write(dbKey)`.
/// Between the delete and the write there was a window in which the encrypted
/// database still existed on disk while its only usable key did not. A process
/// kill, an OS jetsam, or a failing `write` in that window left the database
/// permanently unopenable — `classifyDatabaseKeyState` correctly reports
/// [DatabaseKeyState.keyUnavailable], but the data is gone.
///
/// The fix is structural rather than a narrower ordering: the key is **never
/// deleted at all**, so the dangerous state is unreachable by construction.
/// Every interruption now degrades to "some non-key entries survive", which is
/// recoverable — re-running the wipe completes it, and the database still opens.
///
/// Sensitive data is still removed: the caller empties the database tables in a
/// single transaction (`DataWipeService.wipeAll`), and every non-key entry here
/// is deleted, verified, and retried.
Future<SecureStorageWipeResult> wipeSecureStoragePreservingDatabaseKey({
  required Future<Map<String, String>> Function() readAll,
  required Future<void> Function(String key) delete,
  Set<String> knownKeys = const {},
  String preservedKey = SecureDatabaseKeyStore.defaultStorageKey,
}) async {
  /// What actually remains in storage right now, or null when the platform
  /// cannot enumerate. Used for VERIFICATION, so it must never invent entries.
  Future<Set<String>?> survivors() async {
    try {
      final found = (await readAll()).keys.toSet();
      found.remove(preservedKey);
      return found;
    } catch (_) {
      return null; // unverifiable — fall back to the delete results
    }
  }

  /// The initial delete set: whatever storage reports, PLUS the caller's
  /// deterministic list (so nothing is missed when enumeration is unavailable).
  Future<Set<String>> targets() async {
    final found = <String>{...?(await survivors())};
    found.addAll(knownKeys);
    found.remove(preservedKey);
    return found;
  }

  final deleted = <String>{};
  final failed = <String>{};

  Future<void> sweep(Set<String> keys) async {
    for (final key in keys) {
      try {
        await delete(key);
        deleted.add(key);
        failed.remove(key);
      } catch (_) {
        failed.add(key);
      }
    }
  }

  await sweep(await targets());
  // Verify against STORAGE rather than trusting the delete calls, then retry
  // whatever actually survived. Self-correcting, so no hardcoded key list can
  // go stale — and a key that never existed is never counted as a survivor.
  final afterFirst = await survivors();
  if (afterFirst != null && afterFirst.isNotEmpty) await sweep(afterFirst);

  final remaining = await survivors();
  return SecureStorageWipeResult(
    deleted: deleted.toList()..sort(),
    // When storage cannot be enumerated, the per-delete outcomes are the only
    // evidence available; never claim completeness we cannot verify.
    failed: {...failed, ...?remaining}.toList()..sort(),
  );
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
