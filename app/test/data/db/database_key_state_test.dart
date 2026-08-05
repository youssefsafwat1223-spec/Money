import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/backup/backup_crypto.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';

// MALI-058n (closure) — a MISSING local database key must be a distinct, typed
// state, never a silently-minted new key or a data wipe.
class _SpyKeyStore implements DatabaseKeyStore {
  _SpyKeyStore(this._stored);
  String? _stored;
  int readOrCreateCalls = 0;
  int readStoredCalls = 0;

  @override
  Future<String> readOrCreateKey() async {
    readOrCreateCalls++;
    return _stored ??= 'newly-minted-key';
  }

  @override
  Future<String?> readStoredKey() async {
    readStoredCalls++;
    return _stored;
  }
}

const _keyCanary = 'RAW-KEY-CANARY-DO-NOT-LEAK-7b2f';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('classifyDatabaseKeyState', () {
    test('no DB + no key → freshInstall (a new key may be created)', () {
      expect(classifyDatabaseKeyState(databaseExists: false, storedKey: null),
          DatabaseKeyState.freshInstall);
      expect(classifyDatabaseKeyState(databaseExists: false, storedKey: ''),
          DatabaseKeyState.freshInstall);
    });

    test('DB exists + no key → keyUnavailable', () {
      expect(classifyDatabaseKeyState(databaseExists: true, storedKey: null),
          DatabaseKeyState.keyUnavailable);
      expect(classifyDatabaseKeyState(databaseExists: true, storedKey: ''),
          DatabaseKeyState.keyUnavailable);
    });

    test('a present key is ALWAYS keyPresent — a corrupt DB with a key can '
        'never be mistaken for key-absence', () {
      expect(classifyDatabaseKeyState(databaseExists: true, storedKey: 'k'),
          DatabaseKeyState.keyPresent);
      expect(classifyDatabaseKeyState(databaseExists: false, storedKey: 'k'),
          DatabaseKeyState.keyPresent);
    });
  });

  test('existing DB + missing key → typed key-unavailable; NO new key minted, '
      'NO delete, NO open attempt', () async {
    final ks = _SpyKeyStore(null); // key absent from secure storage
    await expectLater(
      AppDatabase.open(
        executor: NativeDatabase.memory(),
        keyStore: ks,
        databaseFileExists: () async => true, // but an encrypted DB exists
      ),
      throwsA(isA<LocalDatabaseKeyUnavailableException>()),
    );
    // Never generated a replacement key (which would have masked the loss).
    expect(ks.readOrCreateCalls, 0);
  });

  test('fresh install (no DB, no key) resolves without throwing', () async {
    final ks = _SpyKeyStore(null);
    final db = await AppDatabase.open(
      executor: NativeDatabase.memory(),
      keyStore: ks,
      databaseFileExists: () async => false,
    );
    addTearDown(db.close);
    expect(await db.count('user_settings'), 1); // opened + seeded
  });

  test('existing DB + valid key opens normally', () async {
    final ks = _SpyKeyStore('device-key');
    final db = await AppDatabase.open(
      executor: NativeDatabase.memory(),
      keyStore: ks,
      databaseFileExists: () async => true,
    );
    addTearDown(db.close);
    expect(await db.count('user_settings'), 1);
  });

  test('the typed key-unavailable state carries no key/path/passphrase/SQL',
      () {
    final text = const LocalDatabaseKeyUnavailableException().toString();
    for (final forbidden in [
      _keyCanary,
      'PRAGMA',
      'passphrase',
      'money_companion.sqlite',
      '/',
    ]) {
      expect(text.contains(forbidden), isFalse, reason: 'leaked "$forbidden"');
    }
  });

  test('a wrong backup passphrase is a DISTINCT error, not key-unavailable',
      () async {
    final crypto = BackupCrypto();
    final blob = await crypto.encryptJson(
      json: {'db_encryption_key_ref': _keyCanary},
      passphrase: 'the-correct-passphrase',
    );
    Object? thrown;
    try {
      await crypto.decryptJson(blob: blob, passphrase: 'the-WRONG-passphrase');
    } catch (e) {
      thrown = e;
    }
    expect(thrown, isNotNull);
    expect(thrown, isNot(isA<LocalDatabaseKeyUnavailableException>()));
  });

  test('the encrypted backup blob never contains the raw-key canary as plaintext',
      () async {
    final crypto = BackupCrypto();
    final blob = await crypto.encryptJson(
      json: {'db_encryption_key_ref': _keyCanary, 'country': 'SA'},
      passphrase: 'pass',
    );
    final wire = utf8.decode(blob.toBytes(), allowMalformed: true);
    expect(wire.contains(_keyCanary), isFalse);
  });
}
