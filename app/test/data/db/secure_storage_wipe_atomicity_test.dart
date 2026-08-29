import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/session/app_session.dart';
import 'package:money_companion/data/db/database_key_store.dart';

/// Cross-model audit **H-8** — the SQLCipher key crash window.
///
/// `wipeAndReset()` was `read(dbKey) → deleteAll() → write(dbKey)`. Between the
/// delete and the write, the encrypted database existed on disk with NO usable
/// key. A process kill or a failing `write` in that window made the database
/// permanently unopenable.
///
/// The invariant pinned here:
///
///   There must never be a reachable state where the encrypted database
///   remains on disk but the only usable key has been irreversibly deleted.
///
/// The fix is structural: the key is never deleted, so no ordering can produce
/// that state. These tests model interruption at every boundary.
const _dbKey = SecureDatabaseKeyStore.defaultStorageKey;

/// Fake secure storage with fault injection per key.
class _FakeStorage {
  _FakeStorage(Map<String, String> initial) : store = {...initial};

  final Map<String, String> store;

  /// Keys whose `delete` throws. Use to model a storage failure or a kill.
  final Set<String> failDeletes = {};

  /// Keys that fail exactly once, then succeed (transient failure).
  final Set<String> failDeletesOnce = {};

  bool readAllThrows = false;
  final List<String> deleteCalls = [];

  Future<Map<String, String>> readAll() async {
    if (readAllThrows) throw const FileSystemException('keychain unavailable');
    return {...store};
  }

  Future<void> delete(String key) async {
    deleteCalls.add(key);
    if (failDeletes.contains(key)) {
      throw const FileSystemException('keychain write denied');
    }
    if (failDeletesOnce.remove(key)) {
      throw const FileSystemException('transient keychain failure');
    }
    store.remove(key);
  }
}

Future<SecureStorageWipeResult> _wipe(_FakeStorage s) =>
    wipeSecureStoragePreservingDatabaseKey(
      readAll: s.readAll,
      delete: s.delete,
      knownKeys: AppSession.sessionStorageKeys,
    );

void main() {
  group('H-8 — the SQLCipher key is never deleted', () {
    test('a full wipe removes everything EXCEPT the database key', () async {
      final s = _FakeStorage({
        _dbKey: 'SECRET-KEY',
        'auth_method': 'google',
        'auth_email': 'a@b.c',
        'local_data_owner_uid': 'user-a',
        'backup_salt': 'salt',
      });

      final result = await _wipe(s);

      expect(s.store.keys, [_dbKey]);
      expect(s.store[_dbKey], 'SECRET-KEY');
      expect(result.isComplete, isTrue);
      expect(s.deleteCalls, isNot(contains(_dbKey)),
          reason: 'the key must never even be PASSED to delete — that is the '
              'window the old deleteAll() opened');
    });

    test('the database stays openable after the wipe', () async {
      final s = _FakeStorage({_dbKey: 'SECRET-KEY', 'auth_email': 'a@b.c'});
      await _wipe(s);

      // The encrypted file still exists (the caller empties tables, not the
      // file), so this is the state the next cold start classifies.
      expect(
        classifyDatabaseKeyState(
          databaseExists: true,
          storedKey: s.store[_dbKey],
        ),
        DatabaseKeyState.keyPresent,
      );
    });

    test('PRE-FIX state is the unrecoverable one this prevents', () {
      // Documents exactly what the old window produced: DB on disk, key gone.
      expect(
        classifyDatabaseKeyState(databaseExists: true, storedKey: null),
        DatabaseKeyState.keyUnavailable,
      );
      // …and that it stays distinguishable from a genuine new install (req 7).
      expect(
        classifyDatabaseKeyState(databaseExists: false, storedKey: null),
        DatabaseKeyState.freshInstall,
      );
    });
  });

  group('H-8 — interruption at every boundary', () {
    test('a kill mid-sweep leaves the key intact and is recoverable', () async {
      final s = _FakeStorage({
        _dbKey: 'SECRET-KEY',
        'auth_method': 'google',
        'auth_email': 'a@b.c',
      });
      s.failDeletes.add('auth_email'); // simulate the interruption point

      final first = await _wipe(s);

      expect(s.store.containsKey(_dbKey), isTrue,
          reason: 'no interruption may cost the key');
      expect(first.isComplete, isFalse);
      expect(first.failed, contains('auth_email'));

      // Recovery: the operation is idempotent, so re-running completes it.
      s.failDeletes.clear();
      final second = await _wipe(s);
      expect(second.isComplete, isTrue);
      expect(s.store.keys, [_dbKey]);
    });

    test('a transient storage failure is retried, not reported as failure',
        () async {
      final s = _FakeStorage({_dbKey: 'K', 'auth_email': 'a@b.c'});
      s.failDeletesOnce.add('auth_email');

      final result = await _wipe(s);

      expect(result.isComplete, isTrue, reason: 'one retry must be attempted');
      expect(s.store.keys, [_dbKey]);
    });

    test('a permanently failing entry is REPORTED, never silently ignored',
        () async {
      final s = _FakeStorage({_dbKey: 'K', 'auth_email': 'a@b.c'});
      s.failDeletes.add('auth_email');

      final result = await _wipe(s);

      expect(result.isComplete, isFalse);
      expect(result.failed, contains('auth_email'));
      // Requirement 5: sensitive data must eventually be removed, so an
      // incomplete wipe must not look like success.
    });

    test('enumeration failure falls back to the known keys, key still safe',
        () async {
      final s = _FakeStorage({
        _dbKey: 'SECRET-KEY',
        'auth_method': 'google',
        'auth_email': 'a@b.c',
      });
      s.readAllThrows = true;

      final result = await _wipe(s);

      expect(s.store.containsKey(_dbKey), isTrue);
      expect(s.store.containsKey('auth_method'), isFalse);
      expect(s.store.containsKey('auth_email'), isFalse);
      expect(result.isComplete, isTrue);
      expect(s.deleteCalls, isNot(contains(_dbKey)));
    });

    test('an empty store is a no-op (repeat wipe after completion)', () async {
      final s = _FakeStorage({_dbKey: 'K'});
      final result = await _wipe(s);
      expect(result.isComplete, isTrue);
      expect(s.store.keys, [_dbKey]);
      expect(s.deleteCalls, isNot(contains(_dbKey)));
    });
  });

  group('H-8 — account isolation is preserved', () {
    test('the owner marker is destroyed even though the key survives',
        () async {
      // Requirement 6: user A's key must never make A's data readable as B.
      // The key is device-scoped and the DB tables are emptied by the caller;
      // what must NOT survive is the ownership/identity marker.
      final s = _FakeStorage({
        _dbKey: 'DEVICE-KEY',
        'local_data_owner_uid': 'user-a',
        'local_data_owner_generation': '7',
        'auth_email': 'a@b.c',
      });

      await _wipe(s);

      expect(s.store.containsKey('local_data_owner_uid'), isFalse);
      expect(s.store.containsKey('local_data_owner_generation'), isFalse);
      expect(s.store.containsKey('auth_email'), isFalse);
      expect(s.store.keys, [_dbKey]);
    });
  });

  group('H-8 — the dangerous primitive is gone from production code', () {
    test('no production code calls secure-storage deleteAll()', () {
      final offenders = <String>[];
      for (final file in Directory('lib')
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))) {
        final source = file.readAsStringSync();
        if (RegExp(r'_?storage\s*\.\s*deleteAll\s*\(').hasMatch(source)) {
          offenders.add(file.path);
        }
      }
      expect(offenders, isEmpty,
          reason: 'deleteAll() cannot exclude the SQLCipher key, so any use '
              'reintroduces the H-8 window:\n${offenders.join('\n')}');
    });

    test('the wipe helper is what wipeAndReset actually uses', () {
      final source =
          File('lib/core/session/app_session.dart').readAsStringSync();
      final body = source.substring(source.indexOf('Future<void> wipeAndReset'));
      final wipeBody = body.substring(0, body.indexOf('\n  }'));
      expect(wipeBody, contains('wipeSecureStoragePreservingDatabaseKey'));
      expect(wipeBody, contains('SecureStorageWipeIncompleteException'),
          reason: 'an incomplete wipe must surface, not pass silently');
    });
  });
}
