import 'dart:convert';

import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_secure_storage/test/test_flutter_secure_storage_platform.dart';
// ignore: depend_on_referenced_packages
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart';
import 'package:http/testing.dart';
import 'package:money_companion/core/privacy/data_wipe_service.dart';
import 'package:money_companion/core/session/app_session.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// OWNERSHIP FAILS CLOSED: if ownership is unresolved, local data is preserved
/// and access is denied; a destructive transition happens only after the owner
/// marker is PROVEN writable, and admission only after it is READ BACK.
///
/// Real-device evidence: a marker written by an older build (different
/// kSecAttrAccessible) survived `delete` silently and kept reading back as the
/// previous uid, so every reconcile in a launch wiped the user's data again.

const _ownerKey = 'local_data_owner_uid';

/// Reproduces flutter_secure_storage 9.2.4 on a REAL iOS keychain:
/// an item written under a different kSecAttrAccessible is readable, but
/// `delete` silently leaves it (proof G1); `write` repairs it (proof G3).
class _KeychainFake extends TestFlutterSecureStoragePlatform {
  _KeychainFake(super.data);
  final Set<String> legacy = {}; // readable, undeletable until written
  final Set<String> dropWrites = {}; // writes silently lost (unrepairable)
  int ownerWriteAttempts = 0;

  @override
  Future<void> delete({
    required String key,
    required Map<String, String> options,
  }) async {
    if (legacy.contains(key)) return;
    return super.delete(key: key, options: options);
  }

  @override
  Future<void> write({
    required String key,
    required String value,
    required Map<String, String> options,
  }) async {
    if (key == _ownerKey) ownerWriteAttempts++;
    if (dropWrites.contains(key)) return;
    legacy.remove(key);
    return super.write(key: key, value: value, options: options);
  }
}

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'test-key';

  @override
  Future<String?> readStoredKey() async => 'test-key';
}

SupabaseClient _client() => SupabaseClient(
      'https://example.supabase.co',
      'public-anon-key',
      httpClient: MockClient((request) async => Response('{}', 200)),
    );

Future<void> _recoverSession(SupabaseClient client, String uid) async {
  String segment(Map<String, dynamic> json) =>
      base64Url.encode(utf8.encode(jsonEncode(json))).replaceAll('=', '');
  final header = segment({'alg': 'none', 'typ': 'JWT'});
  final payload = segment({
    'exp':
        DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch ~/
            1000,
    'sub': uid,
  });
  await client.auth.recoverSession(jsonEncode({
    'access_token': '$header.$payload.',
    'token_type': 'bearer',
    'user': {'id': uid, 'email': '$uid@example.com'},
  }));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  late _KeychainFake fake;
  late int wipeCalls;
  late bool purgeOk;
  final session = AppSession.instance;

  Future<int> count(String table, String id) async => (await db
          .customSelect('SELECT COUNT(*) AS c FROM $table WHERE id = ?;',
              variables: [Variable.withString(id)])
          .getSingle())
      .read<int>('c');

  Future<String> language() async => (await db
          .customSelect('SELECT language FROM user_settings LIMIT 1;')
          .getSingle())
      .read<String>('language');

  Future<void> seedUserData(String tag) async {
    final now = DateTime.now().toUtc().toIso8601String();
    await db.customStatement(
      "INSERT INTO accounts(id, name, currency, type, is_default, sort_order, "
      "created_at, updated_at) VALUES ('a-$tag', 'Acct', 'SAR', 'bank', 0, 5, "
      "'$now', '$now');",
    );
    await db.customStatement(
      "INSERT INTO transactions(id, amount, currency, type, source, "
      "occurred_at, raw_message, parse_confidence, status, created_at, "
      "updated_at) VALUES ('t-$tag', 10, 'SAR', 'expense', 'manual', '$now', "
      "'raw', 1.0, 'active', '$now', '$now');",
    );
    await db.customStatement("UPDATE user_settings SET language = 'en';");
  }

  Future<void> expectDataIntact(String tag) async {
    expect(await count('accounts', 'a-$tag'), 1);
    expect(await count('transactions', 't-$tag'), 1);
    expect(await language(), 'en');
  }

  /// Signs [uid] in on a clean marker (claims it), then resets counters.
  Future<void> signedInAs(String uid) async {
    await session.completeOnboarding(
      method: 'google',
      email: '$uid@example.com',
      userId: uid,
    );
    fake.ownerWriteAttempts = 0;
    wipeCalls = 0;
  }

  String? marker() => fake.data[_ownerKey];

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    session.configureLocalDataWipe(null);
    session.configureLocalResiduePurge(() async => true);
    await session.wipeAndReset();
    fake = _KeychainFake({});
    FlutterSecureStoragePlatform.instance = fake;
    purgeOk = true;
    db = await AppDatabase.open(
      executor: NativeDatabase.memory(),
      keyStore: _MemoryKeyStore(),
    );
    wipeCalls = 0;
    session.configureLocalResiduePurge(() async => purgeOk);
    session.configureLocalDataWipe(() async {
      wipeCalls++;
      await DataWipeService(db).wipeAll();
    });
  });

  tearDown(() async {
    // Let the teardown reset actually delete the deliberately stuck marker.
    fake.legacy.clear();
    fake.dropWrites.clear();
    session.configureLocalDataWipe(null);
    session.configureLocalResiduePurge(null);
    await session.wipeAndReset();
    await db.close();
  });

  // A(i). Unrepairable mismatched marker: interactive sign-in fails closed.
  test('A(i) unrepairable marker: setIdentity throws, nothing is wiped',
      () async {
    await signedInAs('Y');
    await seedUserData('x');
    fake.data[_ownerKey] = 'X';
    fake.legacy.add(_ownerKey);
    fake.dropWrites.add(_ownerKey);

    await expectLater(
      session.setIdentity(method: 'google', userId: 'Y'),
      throwsA(isA<LocalDataOwnershipException>()),
    );

    expect(wipeCalls, 0);
    await expectDataIntact('x');
    expect(marker(), 'X');
  });

  // A(ii). Same conflict on the reconcile path: session expires, data kept.
  test('A(ii) unrepairable marker: reconcile expires session, no wipe',
      () async {
    await signedInAs('Y');
    await seedUserData('x');
    expect(session.status, SessionStatus.authenticated);
    fake.data[_ownerKey] = 'X';
    fake.legacy.add(_ownerKey);
    fake.dropWrites.add(_ownerKey);
    final client = _client();
    await _recoverSession(client, 'Y');

    await session.revalidateSupabaseSessionOnResume(client);

    expect(session.status, SessionStatus.sessionExpired);
    expect(wipeCalls, 0);
    await expectDataIntact('x');
    expect(marker(), 'X');
  });

  // B. Repairable legacy marker (the real-world case): one wipe, ever.
  test('B legacy mismatched marker: exactly one wipe across 6 reconciles',
      () async {
    await signedInAs('Y');
    await seedUserData('x');
    fake.data[_ownerKey] = 'X';
    fake.legacy.add(_ownerKey);
    final client = _client();
    await _recoverSession(client, 'Y');

    await session.revalidateSupabaseSessionOnResume(client);

    expect(wipeCalls, 1);
    expect(marker(), 'Y');
    expect(await session.readLocalDataOwnerUid(), 'Y');

    for (var i = 0; i < 3; i++) {
      await session.revalidateSupabaseSessionOnResume(client);
    }
    for (var i = 0; i < 2; i++) {
      await session.setIdentity(method: 'google', userId: 'Y');
    }
    expect(wipeCalls, 1, reason: 'later reconciles must observe the claim');
    expect(marker(), 'Y');
  });

  // C. Same owner.
  test('C same owner: no wipe, admitted, data intact', () async {
    await signedInAs('Y');
    await seedUserData('y');
    final client = _client();
    await _recoverSession(client, 'Y');

    await session.revalidateSupabaseSessionOnResume(client);
    await session.setIdentity(method: 'google', userId: 'Y');

    expect(wipeCalls, 0);
    expect(session.status, SessionStatus.authenticated);
    expect(marker(), 'Y');
    await expectDataIntact('y');
  });

  // D. Latch: automatic reconciles do not retry an unresolved uid.
  test('D repeated automatic reconciles do not retry keychain writes',
      () async {
    await signedInAs('Y');
    await seedUserData('x');
    fake.data[_ownerKey] = 'X';
    fake.legacy.add(_ownerKey);
    fake.dropWrites.add(_ownerKey);
    final client = _client();
    await _recoverSession(client, 'Y');

    await session.revalidateSupabaseSessionOnResume(client);
    final afterFirst = fake.ownerWriteAttempts;
    expect(afterFirst, greaterThan(0));
    await session.revalidateSupabaseSessionOnResume(client);
    await session.revalidateSupabaseSessionOnResume(client);

    expect(fake.ownerWriteAttempts, afterFirst);
    expect(wipeCalls, 0);
    expect(session.status, SessionStatus.sessionExpired);
    await expectDataIntact('x');
  });

  // E. Overlapping reconciles converge on exactly one transition.
  test('E overlapping reconciles on a repairable conflict wipe once',
      () async {
    await signedInAs('Y');
    await seedUserData('x');
    fake.data[_ownerKey] = 'X';
    fake.legacy.add(_ownerKey);
    final client = _client();
    await _recoverSession(client, 'Y');

    // Mirror bootstrap: first reconcile runs with the wipe hook unset.
    session.configureLocalDataWipe(null);
    await session.revalidateSupabaseSessionOnResume(client);
    expect(wipeCalls, 0);
    session.configureLocalDataWipe(() async {
      wipeCalls++;
      await DataWipeService(db).wipeAll();
    });

    await Future.wait([
      session.resolvePendingLocalDataOwnerConflict(client),
      session.revalidateSupabaseSessionOnResume(client),
      session.setIdentity(method: 'google', userId: 'Y'),
    ]);

    expect(wipeCalls, 1);
    expect(marker(), 'Y');
  });

  test('E overlapping reconciles on an unrepairable conflict wipe nothing',
      () async {
    await signedInAs('Y');
    await seedUserData('x');
    fake.data[_ownerKey] = 'X';
    fake.legacy.add(_ownerKey);
    fake.dropWrites.add(_ownerKey);
    final client = _client();
    await _recoverSession(client, 'Y');

    session.configureLocalDataWipe(null);
    await session.revalidateSupabaseSessionOnResume(client);
    session.configureLocalDataWipe(() async {
      wipeCalls++;
      await DataWipeService(db).wipeAll();
    });

    final results = await Future.wait([
      session.resolvePendingLocalDataOwnerConflict(client).then((_) => null),
      session.revalidateSupabaseSessionOnResume(client).then((_) => null),
      session
          .setIdentity(method: 'google', userId: 'Y')
          .then<Object?>((_) => null, onError: (Object e) => e),
    ]);

    expect(results[2], isA<LocalDataOwnershipException>());
    expect(wipeCalls, 0);
    expect(marker(), 'X');
    await expectDataIntact('x');
  });

  // F. Explicit logout keeps its destructive semantics.
  test('F explicit signOut wipes exactly once', () async {
    await signedInAs('Y');
    await seedUserData('y');

    await session.signOut();

    expect(wipeCalls, 1);
    expect(await count('accounts', 'a-y'), 0);
  });

  // G. Genuine different-user transition with a normal marker.
  test('G different user: one wipe, marker becomes B, no repeat', () async {
    await signedInAs('A');
    await seedUserData('a');
    final client = _client();
    await _recoverSession(client, 'B');

    await session.revalidateSupabaseSessionOnResume(client);

    expect(wipeCalls, 1);
    expect(marker(), 'B');
    expect(await count('accounts', 'a-a'), 0);
    expect(await count('transactions', 't-a'), 0);

    await session.revalidateSupabaseSessionOnResume(client);
    await session.setIdentity(method: 'google', userId: 'B');
    expect(wipeCalls, 1);
    expect(marker(), 'B');
  });

  // H. Crash between the sentinel and the wipe converges.
  test('H leftover transition sentinel is redone: one wipe, marker Y',
      () async {
    await signedInAs('Y');
    await seedUserData('x');
    fake.data[_ownerKey] = 'owner-transition-pending:Y';
    final client = _client();
    await _recoverSession(client, 'Y');

    await session.revalidateSupabaseSessionOnResume(client);

    expect(wipeCalls, 1);
    expect(marker(), 'Y');
    expect(await count('accounts', 'a-x'), 0);
  });

  // I. Residue purge failure on a conflict preserves data.
  test('I failed residue purge on conflict: no wipe, unresolved', () async {
    await signedInAs('Y');
    await seedUserData('x');
    fake.data[_ownerKey] = 'X';
    purgeOk = false;

    await expectLater(
      session.setIdentity(method: 'google', userId: 'Y'),
      throwsA(isA<LocalDataOwnershipException>()),
    );

    expect(wipeCalls, 0);
    expect(marker(), 'X');
    await expectDataIntact('x');
  });

  // J. A failed wipe must not move ownership; the previous owner is unharmed.
  test('J failed wipe restores previous owner; A signing back in keeps data',
      () async {
    await signedInAs('A');
    await seedUserData('a');
    session.configureLocalDataWipe(() async {
      wipeCalls++;
      throw StateError('disk full');
    });

    await expectLater(
      session.setIdentity(method: 'google', userId: 'B'),
      throwsA(isA<StateError>()),
    );
    expect(marker(), 'A');
    await expectDataIntact('a');

    wipeCalls = 0;
    await session.setIdentity(method: 'google', userId: 'A');

    expect(wipeCalls, 0);
    expect(marker(), 'A');
    expect(session.status, SessionStatus.authenticated);
    await expectDataIntact('a');
  });
}
