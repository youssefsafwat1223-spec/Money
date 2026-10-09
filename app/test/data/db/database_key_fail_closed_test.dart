import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/db/replica_location.dart';

/// A NEW DATABASE KEY MAY ONLY BE MINTED WHEN THERE IS PROVABLY NOTHING TO LOSE.
///
/// "Could not read the key" is not "there is no key". Collapsing the two is how
/// a transient Keychain failure becomes a fresh key over an existing encrypted
/// database — which does not fail loudly, it just opens onto nothing and makes
/// the real data unrecoverable, because the only thing that could have decrypted
/// it has been overwritten.
///
/// `AppDatabase.open` has always classified the key state before calling in, and
/// `database_key_state_test.dart` covers that. These tests are about the
/// primitive itself: the invariant now lives where the key is minted, so a
/// second call site or a reordering cannot lose it.
///
/// iOS accessibility is `first_unlock_this_device`, so Keychain items do NOT
/// transfer to a restored device while the database file does. "DB restored,
/// Keychain missing" is therefore a real user state, not a hypothetical.

/// A storage double that can fail a read the way a locked/unentitled Keychain
/// does, and counts every write so "zero new keys" is assertable.
class _Storage implements FlutterSecureStorage {
  _Storage({this.initial});

  String? initial;
  int readAttempts = 0;
  int writes = 0;
  int failReads = 0;
  Object? failWith;

  @override
  Future<String?> read({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    readAttempts++;
    if (failReads > 0) {
      failReads--;
      throw failWith ?? FakeKeychainFailure();
    }
    return initial;
  }

  @override
  Future<void> write({
    required String key,
    required String? value,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    writes++;
    initial = value;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

/// Stands in for the platform errors a Keychain read can raise — most
/// realistically errSecMissingEntitlement (-34018) or an item that cannot be
/// decrypted while the device is locked.
class FakeKeychainFailure implements Exception {
  @override
  String toString() => 'keychain unavailable (-34018)';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  SecureDatabaseKeyStore store(
    _Storage storage, {
    required bool dbExists,
  }) =>
      SecureDatabaseKeyStore(
        storage: storage,
        databaseExists: () async => dbExists,
      );

  group('fresh install', () {
    test('creates exactly one key', () async {
      final s = _Storage();
      final key = await store(s, dbExists: false).readOrCreateKey();

      expect(key, isNotEmpty);
      expect(s.writes, 1, reason: 'exactly one key minted');
    });
  });

  group('existing key', () {
    test('is reused, and nothing is written', () async {
      final s = _Storage(initial: 'existing-key');

      expect(await store(s, dbExists: true).readOrCreateKey(), 'existing-key');
      expect(s.writes, 0);
    });
  });

  group('THE fail-open cases — every one must mint ZERO keys', () {
    test('a Keychain read that THROWS never mints', () async {
      final s = _Storage()
        ..failReads = 99
        ..failWith = FakeKeychainFailure();

      await expectLater(
        store(s, dbExists: true).readOrCreateKey(),
        throwsA(isA<LocalDatabaseKeyUnavailableException>()),
      );
      expect(s.writes, 0, reason: 'a read error is NOT evidence of absence');
    });

    test('existing DB + absent key never mints', () async {
      final s = _Storage(); // reads null
      await expectLater(
        store(s, dbExists: true).readOrCreateKey(),
        throwsA(isA<LocalDatabaseKeyUnavailableException>()),
      );
      expect(s.writes, 0, reason: 'the DB would be orphaned by a new key');
    });

    test('a malformed (empty) key is never silently replaced', () async {
      final s = _Storage(initial: '');
      await expectLater(
        store(s, dbExists: true).readOrCreateKey(),
        throwsA(isA<LocalDatabaseKeyUnavailableException>()),
      );
      expect(s.writes, 0);
    });

    test('repeated launches after a read failure never mutate key state',
        () async {
      final s = _Storage(initial: 'real-key');
      for (var launch = 0; launch < 5; launch++) {
        s.failReads = 1;
        await expectLater(
          store(s, dbExists: true).readOrCreateKey(),
          throwsA(isA<LocalDatabaseKeyUnavailableException>()),
        );
      }
      expect(s.writes, 0);
      expect(s.initial, 'real-key', reason: 'the real key is untouched');
    });

    test('a transient failure followed by a good read uses the ORIGINAL key',
        () async {
      final s = _Storage(initial: 'real-key')..failReads = 1;

      await expectLater(
        store(s, dbExists: true).readOrCreateKey(),
        throwsA(isA<LocalDatabaseKeyUnavailableException>()),
      );
      // The transient condition clears; the next launch must recover the SAME
      // key rather than having replaced it during the outage.
      expect(await store(s, dbExists: true).readOrCreateKey(), 'real-key');
      expect(s.writes, 0);
    });
  });

  group('concurrency', () {
    test('two concurrent callers resolve to ONE key', () async {
      final s = _Storage();
      final st = store(s, dbExists: false);

      final results = await Future.wait([
        st.readOrCreateKey(),
        st.readOrCreateKey(),
        st.readOrCreateKey(),
      ]);

      expect(results.toSet(), hasLength(1), reason: 'one key, not three');
      expect(s.writes, 1, reason: 'single-flight: exactly one mint');
    });
  });

  group('reinstall / restore matrix', () {
    test('Keychain survives, DB gone -> reuse the key, mint nothing', () async {
      final s = _Storage(initial: 'surviving-key');
      expect(await store(s, dbExists: false).readOrCreateKey(), 'surviving-key');
      expect(s.writes, 0);
    });

    test('DB restored, Keychain missing -> fail closed, DB preserved', () async {
      // The device-transfer case: `first_unlock_this_device` keeps Keychain
      // items off the restore, the DB file comes back.
      final s = _Storage();
      await expectLater(
        store(s, dbExists: true).readOrCreateKey(),
        throwsA(isA<LocalDatabaseKeyUnavailableException>()),
      );
      expect(s.writes, 0);
    });

    test('both restored -> opens with the restored key', () async {
      final s = _Storage(initial: 'k');
      expect(await store(s, dbExists: true).readOrCreateKey(), 'k');
      expect(s.writes, 0);
    });

    test('neither present -> fresh install, one key', () async {
      final s = _Storage();
      expect(await store(s, dbExists: false).readOrCreateKey(), isNotEmpty);
      expect(s.writes, 1);
    });
  });

  group('read outcomes are explicit, not collapsed into null', () {
    test('found / absent / readError / invalid are distinguishable', () async {
      expect(
        (await store(_Storage(initial: 'k'), dbExists: false).readKeyOutcome())
            .outcome,
        DatabaseKeyReadOutcome.found,
      );
      expect(
        (await store(_Storage(), dbExists: false).readKeyOutcome()).outcome,
        DatabaseKeyReadOutcome.absent,
      );
      expect(
        (await store(_Storage(initial: ''), dbExists: false).readKeyOutcome())
            .outcome,
        DatabaseKeyReadOutcome.invalid,
      );

      final failing = _Storage()..failReads = 1;
      final read =
          await store(failing, dbExists: false).readKeyOutcome();
      expect(read.outcome, DatabaseKeyReadOutcome.readError);
      expect(read.error, isNotNull, reason: 'the cause is preserved');
      expect(read.key, isNull, reason: 'never a key on an error');
    });
  });

  group('the guard cannot be bypassed by construction', () {
    test('the existence probe is REQUIRED, so no call site can skip it', () {
      // A compile-time guarantee expressed as a test so the intent survives:
      // `SecureDatabaseKeyStore(storage: ...)` without `databaseExists` does not
      // compile. If someone makes it optional, this comment is the reason not
      // to — the invariant would move back into the callers.
      final s = SecureDatabaseKeyStore(
        storage: _Storage(),
        databaseExists: () async => false,
      );
      expect(s.databaseExists, isNotNull);
    });
  });

  // ---------------------------------------------------------------- F2 ------
  group('F2: creation permission reaches the key store', () {
    test('CreationPolicy.denied never mints, even on a provably fresh install',
        () async {
      final s = _Storage();
      await expectLater(
        SecureDatabaseKeyStore(
          storage: s,
          databaseExists: () async => false,
          creation: const CreationPolicy.denied(),
        ).readOrCreateKey(),
        throwsA(isA<DatabaseCreationNotAuthorizedException>()),
      );
      expect(s.writes, 0);
    });

    test('CreationPolicy.denied still reads an existing key', () async {
      final s = _Storage(initial: 'existing-key');
      expect(
        await SecureDatabaseKeyStore(
          storage: s,
          databaseExists: () async => true,
          creation: const CreationPolicy.denied(),
        ).readOrCreateKey(),
        'existing-key',
      );
      expect(s.writes, 0);
    });

    test('existing DB + missing key still fails without minting, with or '
        'without creation permission', () async {
      for (final allow in [true, false]) {
        final s = _Storage();
        await expectLater(
          SecureDatabaseKeyStore(
            storage: s,
            databaseExists: () async => true,
            creation: allow
                ? const CreationPolicy.unrestricted()
                : const CreationPolicy.denied(),
          ).readOrCreateKey(),
          throwsA(isA<LocalDatabaseKeyUnavailableException>()),
        );
        expect(s.writes, 0, reason: 'never rotate a key over an existing DB');
      }
    });

    test('AppDatabase.open(CreationPolicy.denied) on an absent file refuses before '
        'the key store is touched', () async {
      final dir = Directory.systemTemp.createTempSync('f2_open_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final s = _Storage();
      final loc = ReplicaLocation(
          directory: dir.path, dbFileName: 'qirsh.sqlite', keyName: 'k');
      await expectLater(
        AppDatabase.open(
          location: loc,
          creation: const CreationPolicy.denied(),
          keyStore: SecureDatabaseKeyStore(
              storage: s, databaseExists: () async => false),
        ),
        throwsA(isA<DatabaseCreationNotAuthorizedException>()),
      );
      expect(s.readAttempts, 0, reason: 'the key store was not even asked');
      expect(s.writes, 0);
      expect(File(loc.dbPath).existsSync(), isFalse);
    });

    test('a secondary open never creates a database or a key', () async {
      final dir = Directory.systemTemp.createTempSync('f2_secondary_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final s = _Storage();
      final loc = ReplicaLocation(
          directory: dir.path, dbFileName: 'qirsh.sqlite', keyName: 'k');
      await expectLater(
        AppDatabase.openSecondary(
          location: loc,
          keyStore: SecureDatabaseKeyStore(
              storage: s, databaseExists: () async => false),
        ),
        throwsA(isA<DatabaseCreationNotAuthorizedException>()),
      );
      expect(s.writes, 0);
      expect(File(loc.dbPath).existsSync(), isFalse);
    });
  });
}
