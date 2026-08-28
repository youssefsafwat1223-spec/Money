import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart';
import 'package:http/testing.dart';
import 'package:money_companion/core/session/app_session.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/db/planning_cutover.dart';
import 'package:money_companion/domain/errors/repo_exceptions.dart';
import 'package:money_companion/features/planning_sync/services/accounts_backfill_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

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

SupabaseClient _refusingClient() {
  throw StateError('must not contact Supabase when the ownership guard '
      'should have refused first');
}

SupabaseClient _existingAccountClient(
  Map<String, dynamic> row,
  List<String> selected,
) {
  return SupabaseClient(
    'https://example.supabase.co',
    'public-anon-key',
    accessToken: () async => 'token',
    httpClient: MockClient((request) async {
      expect(request.method, 'GET');
      expect(request.url.path, contains('user_accounts'));
      selected.add(request.url.queryParameters['select'] ?? '');
      return Response(
        jsonEncode(row),
        200,
        headers: const {'content-type': 'application/json'},
        request: request,
      );
    }),
  );
}

Future<void> _seedMoneyAccount(
  AppDatabase db, {
  int currentMinor = 20000,
}) async {
  const now = '2026-08-25T10:00:00.000Z';
  await db.customStatement('DELETE FROM accounts;');
  await db.customStatement('''
    INSERT INTO accounts(id,name,currency,type,initial_balance,initial_balance_minor,
      current_balance,current_balance_minor,credit_limit,credit_limit_minor,
      available_credit,available_credit_minor,is_default,sort_order,created_at,updated_at,
      sync_status,synced_at)
    VALUES('account-h2','Exact account','KWD','card',12.345,12345,
      20.0,$currentMinor,500.0,500000,400.0,400000,0,0,'$now','$now',
      'pending','2026-08-24T00:00:00.000Z');
  ''');
}

Map<String, dynamic> _matchingRemoteAccount({
  String currentText = '20.000',
  Object? currentRaw = '20.000',
}) =>
    {
      'id': 'server-account-h2',
      'name': 'Exact account',
      'currency': 'KWD',
      'type': 'card',
      'initial_balance': '12.345',
      'initial_balance_text': '12.345',
      'current_balance': currentRaw,
      'current_balance_text': currentText,
      'credit_limit': '500.000',
      'credit_limit_text': '500.000',
      'available_credit': '400.000',
      'available_credit_text': '400.000',
      'deleted_at': null,
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    AppSession.instance.configureCaptureDeviceUnlink(null);
    AppSession.instance.configureLocalDataWipe(null);
    await AppSession.instance.wipeAndReset();
  });

  // B1 defense-in-depth: same guard as TransactionsBackfillService, applied
  // to accounts — see that test file for the full end-to-end sign-out/
  // sign-in/backfill scenario.

  test(
      'refuses to backfill accounts when the owner marker conflicts with '
      'the currently authenticated uid — and never touches Supabase', () async {
    final db = await _openDb();
    addTearDown(db.close);

    final service = AccountsBackfillService(
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

  test('proceeds when the owner marker is null (no known conflict)', () async {
    final db = await _openDb();
    addTearDown(db.close);
    // Clear the freshly-seeded default account so the per-row loop (the
    // only place Supabase is ever contacted) never executes.
    await db.customStatement('DELETE FROM accounts;');

    final service = AccountsBackfillService(
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

    final service = AccountsBackfillService(
      db: db,
      getAuthUserId: () async => 'user-b',
      getLocalDataOwnerUid: () async => 'user-b',
      getClient: _refusingClient,
    );

    final report = await service.run();

    expect(report.total, 0);
  });

  Future<
      ({
        AccountBackfillReport report,
        Map<String, Object?> local,
        String select
      })> runReconciliation(
    Map<String, dynamic> remote, {
    int currentMinor = 20000,
  }) async {
    final db = await _openDb();
    addTearDown(db.close);
    await _seedMoneyAccount(db, currentMinor: currentMinor);
    final selected = <String>[];

    final report = await AccountsBackfillService(
      db: db,
      getAuthUserId: () async => 'user-b',
      getLocalDataOwnerUid: () async => 'user-b',
      getClient: () => _existingAccountClient(remote, selected),
      coordinator: const FixedPlanningCutoverCoordinator(
        PlanningCutoverState.canonical,
      ),
    ).run();
    final local = (await db.customSelect('''
              SELECT server_id,synced_at,sync_status
              FROM accounts WHERE id='account-h2';
            ''').getSingle()).data;
    return (report: report, local: local, select: selected.single);
  }

  test('credit-limit or available-credit mismatch is a conflict, never synced',
      () async {
    for (final field in const [
      'credit_limit_text',
      'available_credit_text',
    ]) {
      final remote = _matchingRemoteAccount()..[field] = '1.000';
      final result = await runReconciliation(remote);

      expect(result.report.mismatchedLocalIds, ['account-h2'], reason: field);
      expect(result.local['server_id'], 'server-account-h2', reason: field);
      expect(result.local['sync_status'], 'conflict', reason: field);
      expect(result.local['synced_at'], isNull,
          reason: '$field mismatch must clear stale proof-of-sync time');
    }
  });

  test('a missing exact money projection is unproven and becomes a conflict',
      () async {
    final remote = _matchingRemoteAccount()..remove('credit_limit_text');
    final result = await runReconciliation(remote);

    expect(result.report.mismatchedLocalIds, ['account-h2']);
    expect(result.local['sync_status'], 'conflict');
    expect(result.local['synced_at'], isNull);
  });

  test('all four exact money fields and currency matching stamps synced',
      () async {
    const largeMinor = 9007199254740993; // > 2^53
    const exactKwd = '9007199254740.993';
    final roundedJsonNumber = double.parse(exactKwd);
    expect(roundedJsonNumber.toString(), isNot(exactKwd),
        reason: 'non-vacuity: a plain JSON double cannot carry this NUMERIC');

    final result = await runReconciliation(
      _matchingRemoteAccount(
        currentText: exactKwd,
        currentRaw: roundedJsonNumber,
      ),
      currentMinor: largeMinor,
    );

    expect(result.report.mismatchedLocalIds, isEmpty);
    expect(result.local['sync_status'], 'synced');
    expect(result.local['synced_at'], isNotNull);
    expect(
        result.select, contains('initial_balance_text:initial_balance::text'));
    expect(
        result.select, contains('current_balance_text:current_balance::text'));
    expect(result.select, contains('credit_limit_text:credit_limit::text'));
    expect(result.select,
        contains('available_credit_text:available_credit::text'));
  });
}
