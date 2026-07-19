import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/session/app_session.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
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
}
