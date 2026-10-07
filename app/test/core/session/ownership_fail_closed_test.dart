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
import 'package:money_companion/core/session/app_session.dart';
import 'fake_account_scope.dart';
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
  late int purges;
  late bool purgeOk;
  late FakeAccountScope scope;
  List<String> activations() =>
      scope.calls.where((c) => c.startsWith('activate')).toList();

  Future<bool> countingPurge() async {
    purges++;
    return purgeOk;
  }
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
    purges = 0;
    scope.calls.clear();
  }

  String? marker() => fake.data[_ownerKey];

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    session.configureCaptureOwnerClear(() async => true);
    await session.wipeAndReset();
    fake = _KeychainFake({});
    FlutterSecureStoragePlatform.instance = fake;
    purgeOk = true;
    db = await AppDatabase.open(
      executor: NativeDatabase.memory(),
      keyStore: _MemoryKeyStore(),
    );
    purges = 0;
    scope = FakeAccountScope();
    session.configureAccountScope(scope);
    session.configureCaptureOwnerClear(countingPurge);
  });

  tearDown(() async {
    // Let the teardown reset actually delete the deliberately stuck marker.
    fake.legacy.clear();
    fake.dropWrites.clear();
    session.configureCaptureOwnerClear(null);
    session.configureAccountScope(null);
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

    expect(activations(), isEmpty);
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
    expect(activations(), isEmpty);
    await expectDataIntact('x');
    expect(marker(), 'X');
  });

  // B. Repairable legacy marker (the real-world case): one wipe, ever.
  test('B legacy mismatched marker: exactly one transition across 6 reconciles',
      () async {
    await signedInAs('Y');
    await seedUserData('x');
    fake.data[_ownerKey] = 'X';
    fake.legacy.add(_ownerKey);
    final client = _client();
    await _recoverSession(client, 'Y');

    await session.revalidateSupabaseSessionOnResume(client);

    expect(purges, 1);
    expect(marker(), 'Y');
    expect(await session.readLocalDataOwnerUid(), 'Y');

    for (var i = 0; i < 3; i++) {
      await session.revalidateSupabaseSessionOnResume(client);
    }
    for (var i = 0; i < 2; i++) {
      await session.setIdentity(method: 'google', userId: 'Y');
    }
    expect(purges, 1, reason: 'later reconciles must observe the claim');
    expect(marker(), 'Y');
  });

  // C. Same owner.
  test('C same owner: no purge, admitted, data intact', () async {
    await signedInAs('Y');
    await seedUserData('y');
    final client = _client();
    await _recoverSession(client, 'Y');

    await session.revalidateSupabaseSessionOnResume(client);
    await session.setIdentity(method: 'google', userId: 'Y');

    expect(purges, 0);
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
    expect(activations(), isEmpty);
    expect(session.status, SessionStatus.sessionExpired);
    await expectDataIntact('x');
  });

  // E. Overlapping reconciles converge on exactly one transition.
  test('E overlapping reconciles on a repairable conflict transition once',
      () async {
    await signedInAs('Y');
    await seedUserData('x');
    fake.data[_ownerKey] = 'X';
    fake.legacy.add(_ownerKey);
    final client = _client();
    await _recoverSession(client, 'Y');

    // Mirror bootstrap: first reconcile runs with the purge hook unset.
    session.configureCaptureOwnerClear(null);
    await session.revalidateSupabaseSessionOnResume(client);
    expect(purges, 0);
    session.configureCaptureOwnerClear(countingPurge);

    await Future.wait([
      session.resolvePendingLocalDataOwnerConflict(client),
      session.revalidateSupabaseSessionOnResume(client),
      session.setIdentity(method: 'google', userId: 'Y'),
    ]);

    expect(purges, 1);
    expect(marker(), 'Y');
  });

  test('E overlapping reconciles on an unrepairable conflict admit nothing',
      () async {
    await signedInAs('Y');
    await seedUserData('x');
    fake.data[_ownerKey] = 'X';
    fake.legacy.add(_ownerKey);
    fake.dropWrites.add(_ownerKey);
    final client = _client();
    await _recoverSession(client, 'Y');

    session.configureCaptureOwnerClear(null);
    await session.revalidateSupabaseSessionOnResume(client);
    session.configureCaptureOwnerClear(countingPurge);

    final results = await Future.wait([
      session.resolvePendingLocalDataOwnerConflict(client).then((_) => null),
      session.revalidateSupabaseSessionOnResume(client).then((_) => null),
      session
          .setIdentity(method: 'google', userId: 'Y')
          .then<Object?>((_) => null, onError: (Object e) => e),
    ]);

    expect(results[2], isA<LocalDataOwnershipException>());
    expect(activations(), isEmpty);
    expect(marker(), 'X');
    await expectDataIntact('x');
  });

  // F. Explicit logout LOCKS; it never wipes.
  test('F explicit signOut locks the replica and keeps the data', () async {
    await signedInAs('Y');
    await seedUserData('y');

    await session.signOut();

    expect(scope.calls, ['lock']);
    await expectDataIntact('y');
  });

  // G. Genuine different-user transition with a normal marker.
  test('G different user: one transition, marker becomes B, A is untouched',
      () async {
    await signedInAs('A');
    await seedUserData('a');
    final client = _client();
    await _recoverSession(client, 'B');

    await session.revalidateSupabaseSessionOnResume(client);

    expect(purges, 1);
    expect(activations(), ['activate:B']);
    expect(marker(), 'B');
    await expectDataIntact('a'); // A's replica is a different file: untouched

    await session.revalidateSupabaseSessionOnResume(client);
    await session.setIdentity(method: 'google', userId: 'B');
    expect(purges, 1);
    expect(marker(), 'B');
  });

  // H. Crash between the sentinel and the wipe converges.
  test('H leftover transition sentinel is resolved: one transition, marker Y',
      () async {
    await signedInAs('Y');
    await seedUserData('x');
    fake.data[_ownerKey] = 'owner-transition-pending:Y';
    final client = _client();
    await _recoverSession(client, 'Y');

    await session.revalidateSupabaseSessionOnResume(client);

    expect(purges, 1);
    expect(marker(), 'Y');
    expect(activations(), ['activate:Y']);
  });

  // I. Residue purge failure on a conflict preserves data.
  test('I failed residue purge on conflict: not admitted, unresolved', () async {
    await signedInAs('Y');
    await seedUserData('x');
    fake.data[_ownerKey] = 'X';
    purgeOk = false;

    await expectLater(
      session.setIdentity(method: 'google', userId: 'Y'),
      throwsA(isA<LocalDataOwnershipException>()),
    );

    expect(activations(), isEmpty);
    expect(marker(), 'X');
    await expectDataIntact('x');
  });

  // J. A replica that cannot be opened refuses the new uid; the previous owner
  // signing back in is unharmed.
  test('J failed activation refuses B; A signing back in keeps data', () async {
    await signedInAs('A');
    await seedUserData('a');
    scope.activateError = StateError('disk full');

    await expectLater(
      session.setIdentity(method: 'google', userId: 'B'),
      throwsA(isA<LocalDataOwnershipException>()),
    );
    await expectDataIntact('a');

    scope.activateError = null;
    scope.calls.clear();
    await session.setIdentity(method: 'google', userId: 'A');

    expect(marker(), 'A');
    expect(activations(), ['activate:A']);
    expect(session.status, SessionStatus.authenticated);
    await expectDataIntact('a');
  });
}
