import 'dart:convert';
import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../../core/security/secure_storage_options.dart';

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

/// Why a key read ended the way it did. Deliberately NOT collapsed into a
/// nullable String: "absent" and "could not read" are different facts, and
/// treating the second as the first is how a transient Keychain failure turns
/// into a brand-new key over an existing encrypted database.
enum DatabaseKeyReadOutcome {
  /// A usable key came back.
  found,

  /// Secure storage answered, and there is genuinely no key stored.
  absent,

  /// Secure storage could not answer. NOT evidence of absence.
  readError,

  /// A key exists but is unusable (empty). Never silently replaced — doing so
  /// would destroy whatever the real key still protects.
  invalid,
}

/// The result of one key read.
class DatabaseKeyRead {
  const DatabaseKeyRead(this.outcome, {this.key, this.error});

  final DatabaseKeyReadOutcome outcome;

  /// Set only for [DatabaseKeyReadOutcome.found].
  final String? key;

  /// Set only for [DatabaseKeyReadOutcome.readError]. Carries the platform
  /// error so a caller can log a cause; never the key.
  final Object? error;
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

/// WP-3a — every secure-storage entry of the per-UID replica layer (device salt,
/// registry, per-uid database keys) lives under this prefix. A session wipe must
/// never delete one: removing a per-uid key while its database file survives
/// strands that replica exactly like deleting the legacy key does (H-8). Replica
/// secrets are removed only by `ReplicaStore.remove`.
const String kReplicaSecretPrefix = 'qirsh.';

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
      found.removeWhere((k) => k.startsWith(kReplicaSecretPrefix));
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
    found.removeWhere((k) => k.startsWith(kReplicaSecretPrefix));
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
    required this.databaseExists,
    FlutterSecureStorage? storage,
    this.storageKey = defaultStorageKey,
  }) : _storage = storage ?? SecureStorageOptions.storage;

  /// Proves whether a prior encrypted database is already on disk.
  ///
  /// REQUIRED, and required on purpose. A new key may only be minted when this
  /// says there is nothing to lose. `AppDatabase.open` already checks the same
  /// thing before calling in, but that left the invariant in the CALLER: a
  /// second call site, or a reordering, would silently reintroduce a key that
  /// orphans an existing database. Holding it here makes that unexpressible.
  final Future<bool> Function() databaseExists;

  /// Secure-storage key under which the SQLCipher DB key is kept. Exposed so
  /// account/data wipes can preserve it — deleting it while the encrypted DB
  /// file still exists leaves the database unopenable on next launch.
  static const String defaultStorageKey = 'money_companion.db_key';

  final FlutterSecureStorage _storage;
  final String storageKey;

  static final Random _random = Random.secure();

  /// Single-flight. Two concurrent callers that both found no key would each
  /// mint one and the second write would win — leaving one of them holding a
  /// key the database was not encrypted with.
  Future<String>? _inFlight;

  /// Classifies one read without collapsing the outcomes.
  Future<DatabaseKeyRead> readKeyOutcome() async {
    final String? raw;
    try {
      raw = await _storage.read(key: storageKey);
    } catch (e) {
      // Could not ask. This is NOT "there is no key".
      return DatabaseKeyRead(DatabaseKeyReadOutcome.readError, error: e);
    }
    if (raw == null) {
      return const DatabaseKeyRead(DatabaseKeyReadOutcome.absent);
    }
    if (raw.isEmpty) {
      return const DatabaseKeyRead(DatabaseKeyReadOutcome.invalid);
    }
    return DatabaseKeyRead(DatabaseKeyReadOutcome.found, key: raw);
  }

  @override
  Future<String> readOrCreateKey() =>
      _inFlight ??= _readOrCreate().whenComplete(() => _inFlight = null);

  Future<String> _readOrCreate() async {
    final read = await readKeyOutcome();
    switch (read.outcome) {
      case DatabaseKeyReadOutcome.found:
        return read.key!;
      case DatabaseKeyReadOutcome.readError:
      case DatabaseKeyReadOutcome.invalid:
        // Fail closed. Minting here would orphan whatever the real key still
        // protects, and would do it silently.
        throw const LocalDatabaseKeyUnavailableException();
      case DatabaseKeyReadOutcome.absent:
        break;
    }

    // Absent is necessary but NOT sufficient. A key may only be created when we
    // can positively prove there is no prior encrypted database — a restore
    // that brings back the DB file without the Keychain (accessibility is
    // `first_unlock_this_device`, so Keychain items do not transfer) lands
    // exactly here, and minting would strand the restored data forever.
    if (await databaseExists()) {
      throw const LocalDatabaseKeyUnavailableException();
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
