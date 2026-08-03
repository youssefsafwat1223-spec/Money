import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart';
import 'package:http/testing.dart';
import 'package:money_companion/core/privacy/data_wipe_service.dart';
import 'package:money_companion/core/session/app_session.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/domain/errors/repo_exceptions.dart';
import 'package:money_companion/features/capture/services/transactions_backfill_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Builds a real (network-mocked) [SupabaseClient] so a valid session can be
/// recovered for it — used to exercise AppSession's actual session
/// reconciliation (and thus the real local-data-owner marker claim), not a
/// shortcut around it. Mirrors the helper in app_session_test.dart.
SupabaseClient _authClient() {
  final http = MockClient((request) async => Response('{}', 200));
  return SupabaseClient(
    'https://example.supabase.co',
    'public-anon-key',
    httpClient: http,
  );
}

Future<void> _recoverSession(SupabaseClient client, String userId) async {
  String segment(Map<String, dynamic> json) =>
      base64Url.encode(utf8.encode(jsonEncode(json))).replaceAll('=', '');
  final header = segment({'alg': 'none', 'typ': 'JWT'});
  final payload = segment({
    'exp':
        DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch ~/
            1000,
    'sub': userId,
  });
  await client.auth.recoverSession(jsonEncode({
    'access_token': '$header.$payload.',
    'token_type': 'bearer',
    'user': {'id': userId},
  }));
}

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'test-key';

  @override
  Future<String?> readStoredKey() async => 'test-key';
}

Future<AppDatabase> _openDb() {
  return AppDatabase.open(
    executor: NativeDatabase.memory(),
    keyStore: _MemoryKeyStore(),
  );
}

Future<void> _seedOneTransaction(AppDatabase db, {String id = 't1'}) async {
  final now = DateTime.now().toUtc().toIso8601String();
  await db.customStatement(
    "INSERT INTO transactions(id, amount, currency, type, source, occurred_at, "
    "raw_message, parse_confidence, status, created_at, updated_at) "
    "VALUES ('$id', 10, 'SAR', 'expense', 'manual', '$now', 'raw', 1.0, 'active', '$now', '$now');",
  );
}

SupabaseClient _refusingClient() {
  throw StateError(
    'must not contact Supabase — either the ownership guard should have '
    'refused first, or there were zero local rows to upload',
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    AppSession.instance.configureCaptureDeviceUnlink(null);
    AppSession.instance.configureLocalDataWipe(null);
    // MALI-054n: production always registers the residue purge hook; default it
    // to success so sign-out releases ownership exactly as it does in the app.
    AppSession.instance.configureLocalResiduePurge(() async => true);
    await AppSession.instance.wipeAndReset();
  });

  // B1 defense-in-depth: TransactionsBackfillService must never trust "every
  // local row belongs to whoever is currently authenticated" — it must
  // refuse when AppSession's local-data-owner marker names a different uid.

  test(
      'skips rows already synced (server_id set) — re-pushing them minted a '
      'duplicate server copy per reconcile run', () async {
    final db = await _openDb();
    addTearDown(db.close);
    // Accounts gate satisfied.
    await db.customStatement("UPDATE accounts SET server_id = 'srv-acct';");
    // A pull-imported transaction: already on the server, server_id attached.
    await _seedOneTransaction(db);
    await db.customStatement(
      "UPDATE transactions SET server_id = 'srv-tx-1', sync_status = 'synced' "
      "WHERE id = 't1';",
    );

    final service = TransactionsBackfillService(
      db: db,
      getAuthUserId: () async => 'user-a',
      getLocalDataOwnerUid: () async => 'user-a',
      // Throws on any use — proves the synced row triggers ZERO upload calls.
      getClient: _refusingClient,
    );

    final report = await service.run();
    expect(report.total, 0,
        reason: 'synced rows must be invisible to the backfill');
  });

  test(
      'refuses to backfill when the owner marker conflicts with the '
      'currently authenticated uid — and never touches Supabase', () async {
    final db = await _openDb();
    addTearDown(db.close);
    await _seedOneTransaction(db);

    final service = TransactionsBackfillService(
      db: db,
      getAuthUserId: () async => 'user-b',
      getLocalDataOwnerUid: () async => 'user-a',
      getClient: _refusingClient,
    );

    await expectLater(
      service.run(),
      throwsA(isA<ValidationRepoException>()),
    );
  });

  test(
      'proceeds when the owner marker is null (no known conflict — '
      'forward-compatible with installs from before this fix)', () async {
    final db = await _openDb();
    addTearDown(db.close);
    // A fresh DB always seeds one not-yet-backfilled default account; clear
    // it so only the ownership guard (not the separate accounts-backfill
    // gate) is under test here. Empty transactions table: the per-row loop
    // (the only place Supabase is ever contacted) never executes, so a
    // throwing getClient proves zero upload calls happen.
    await db.customStatement('DELETE FROM accounts;');
    final service = TransactionsBackfillService(
      db: db,
      getAuthUserId: () async => 'user-b',
      getLocalDataOwnerUid: () async => null,
      getClient: _refusingClient,
    );

    final report = await service.run();

    expect(report.total, 0);
  });

  test(
      'proceeds when the owner marker matches the currently authenticated '
      'uid', () async {
    final db = await _openDb();
    addTearDown(db.close);
    await db.customStatement('DELETE FROM accounts;');
    final service = TransactionsBackfillService(
      db: db,
      getAuthUserId: () async => 'user-b',
      getLocalDataOwnerUid: () async => 'user-b',
      getClient: _refusingClient,
    );

    final report = await service.run();

    expect(report.total, 0);
  });

  // The exact scenario from the release-blocker report: User A creates local
  // data, signs out (which must wipe it), User B signs in, and a backfill run
  // triggered by User B (e.g. restoring a backup) must upload zero of User
  // A's rows — proven here by both an empty table AND a getClient that fails
  // the test outright if anything ever tries to call Supabase.

  test('end-to-end: sign-out wipes A\'s data, B\'s backfill uploads zero rows',
      () async {
    final db = await _openDb();
    addTearDown(db.close);

    // User A creates local data and is the recorded owner (via a real
    // session reconciliation, exactly as production does on every launch).
    await AppSession.instance.completeOnboarding(
      method: 'google',
      email: 'a@example.com',
      userId: 'user-a',
    );
    final clientA = _authClient();
    await _recoverSession(clientA, 'user-a');
    await AppSession.instance.bindSupabaseAuth(clientA);
    expect(await AppSession.instance.readLocalDataOwnerUid(), 'user-a');
    await _seedOneTransaction(db);
    final countBeforeSignOut = await db
        .customSelect('SELECT COUNT(*) AS n FROM transactions;')
        .getSingle();
    expect(countBeforeSignOut.read<int>('n'), 1);

    // User A signs out — this must wipe the local data (B1 fix) and clear
    // the ownership marker.
    AppSession.instance.configureLocalDataWipe(DataWipeService(db).wipeAll);
    await AppSession.instance.signOut();

    final countAfterSignOut = await db
        .customSelect('SELECT COUNT(*) AS n FROM transactions;')
        .getSingle();
    expect(countAfterSignOut.read<int>('n'), 0,
        reason: 'User A\'s transaction must not survive sign-out');
    expect(await AppSession.instance.readLocalDataOwnerUid(), isNull);

    // User B signs in on the same device and their session reconciles,
    // claiming the now-unclaimed marker.
    await AppSession.instance.completeOnboarding(
      method: 'google',
      email: 'b@example.com',
      userId: 'user-b',
    );
    final clientB = _authClient();
    await _recoverSession(clientB, 'user-b');
    await AppSession.instance.bindSupabaseAuth(clientB);
    expect(await AppSession.instance.readLocalDataOwnerUid(), 'user-b');

    // The wipe reseeds one fresh default account for User B; mark it as
    // already backfilled so only the transactions ownership guard (this
    // test's actual subject) is exercised, not the separate, already
    // independently-testable accounts-backfill precondition.
    await db.customStatement("UPDATE accounts SET server_id = 'srv-acct-b';");

    // User B triggers a backfill (e.g. via restoring a backup). A throwing
    // getClient means this test fails loudly if any row were ever uploaded.
    final service = TransactionsBackfillService(
      db: db,
      getAuthUserId: () async => 'user-b',
      getClient: _refusingClient,
    );

    final report = await service.run();

    expect(report.total, 0,
        reason: 'zero of User A\'s rows may be uploaded to User B\'s account');
  });
}
