import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/privacy/data_wipe_service.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/repositories/drift_account_repository.dart';
import 'package:money_companion/data/repositories/drift_merchant_category_repository.dart';
import 'package:money_companion/data/repositories/drift_suspected_duplicate_repository.dart';
import 'package:money_companion/data/repositories/drift_transaction_repository.dart';
import 'package:money_companion/domain/entities/account_entity.dart';
import 'package:money_companion/domain/usecases/add_transaction_usecase.dart';
import 'package:money_companion/features/planning_sync/services/planning_outbox_queue.dart';

import '../../harness/seed_test_account.dart';

/// A-7: there is NO silent default account. Accounts exist only because the
/// user (or an existing install) created them.
class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'memory-key';
  @override
  Future<String?> readStoredKey() async => 'memory-key';
}

PlanningOutboxQueue _queue(AppDatabase db) => PlanningOutboxQueue(
      db: db,
      isSyncEnabled: (_) => true,
      getAuthUserId: () async => 'user-1',
    );

AccountEntity _acct(String name, {String currency = 'SAR', String id = ''}) {
  final now = DateTime.utc(2026);
  return AccountEntity(
    id: id,
    name: name,
    currency: currency,
    type: AccountType.bank,
    isDefault: false,
    sortOrder: 0,
    createdAt: now,
    updatedAt: now,
  );
}

void main() {
  late AppDatabase db;

  Future<int> count(String sql) async =>
      (await db.customSelect(sql).getSingle()).read<int>('c');
  Future<int> accounts() => count('SELECT COUNT(*) AS c FROM accounts;');

  Future<AppDatabase> open() => AppDatabase.open(
        executor: NativeDatabase.memory(),
        keyStore: _MemoryKeyStore(),
      );

  setUp(() async => db = await open());
  tearDown(() async => db.close());

  test('a fresh database open creates ZERO accounts', () async {
    expect(await accounts(), 0);
    expect(await count('SELECT COUNT(*) AS c FROM user_settings;'), 1);
  });

  test('post-wipe reseed creates zero accounts', () async {
    await DriftAccountRepository(db).create(_acct('mine'));
    await DataWipeService(db).wipeAll();
    expect(await accounts(), 0);
    await db.reseedDefaultsAfterWipe();
    expect(await accounts(), 0);
  });

  test('post-restore setup with zero accounts creates none and leaves orphans',
      () async {
    await db.customStatement(
      "INSERT INTO transactions(id, amount, amount_minor, currency, type, "
      "source, occurred_at, raw_message, parse_confidence, status, created_at, "
      "updated_at, account_id) VALUES('orphan', 10.0, 1000, 'SAR', 'payment', "
      "'imported', '2026-08-01T00:00:00Z', 'x', 1.0, 'confirmed', "
      "'2026-08-01T00:00:00Z', '2026-08-01T00:00:00Z', NULL);",
    );
    await db.runPostRestoreSetup();
    expect(await accounts(), 0);
    expect(
      await count("SELECT COUNT(*) AS c FROM transactions "
          "WHERE id = 'orphan' AND account_id IS NULL;"),
      1,
    );
  });

  test('post-restore setup leaves restored accounts unchanged and promotes a '
      'default only when none is flagged', () async {
    final repo = DriftAccountRepository(db);
    final a = await repo.create(_acct('first'));
    final b = await repo.create(_acct('second'));
    await db.runPostRestoreSetup();
    expect(await accounts(), 2);
    final defaults = await db
        .customSelect('SELECT id FROM accounts WHERE is_default = 1;')
        .get();
    expect(defaults.map((r) => r.read<String>('id')), [a.id]);

    await db.customStatement('UPDATE accounts SET is_default = 0;');
    await db.runPostRestoreSetup();
    final promoted = await db
        .customSelect('SELECT id FROM accounts WHERE is_default = 1;')
        .get();
    expect(promoted, hasLength(1));
    expect(b.id, isNotEmpty);
    expect(await accounts(), 2);
  });

  test('an existing install with the old seeded default is untouched on '
      'upgrade/reopen', () async {
    final dir = Directory.systemTemp.createTempSync('a7_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}/db.sqlite');
    final first = await AppDatabase.open(
        executor: NativeDatabase(file), keyStore: _MemoryKeyStore());
    await seedTestAccount(first, currency: 'EGP');
    await first.close();

    final reopened = await AppDatabase.open(
        executor: NativeDatabase(file), keyStore: _MemoryKeyStore());
    addTearDown(reopened.close);
    final rows = await reopened
        .customSelect('SELECT id, currency, name, is_default FROM accounts;')
        .get();
    expect(rows, hasLength(1));
    expect(rows.single.read<String>('id'), kDefaultAccountLocalId);
    expect(rows.single.read<String>('currency'), 'EGP');
    expect(rows.single.read<int>('is_default'), 1);
  });

  test('offline create goes through the repository: local row + outbox intent, '
      'first account is default', () async {
    final repo = DriftAccountRepository(db, outboxQueue: _queue(db));
    final created = await repo.create(_acct('Cash', id: 'acct-1'));
    expect(created.isDefault, isTrue);
    expect(await accounts(), 1);
    expect(
      await count("SELECT COUNT(*) AS c FROM planning_sync_outbox "
          "WHERE entity_id = 'acct-1';"),
      greaterThan(0),
      reason: 'create intent recorded without any network',
    );
  });

  test('re-sending the same creation id never duplicates the account',
      () async {
    final repo = DriftAccountRepository(db);
    await repo.create(_acct('Cash', id: 'same-id'));
    await expectLater(repo.create(_acct('Cash', id: 'same-id')), throwsA(anything));
    expect(await accounts(), 1);
  });

  test('the last remaining account cannot be deleted (repository guard)',
      () async {
    final repo = DriftAccountRepository(db);
    final only = await repo.create(_acct('Only'));
    await expectLater(repo.delete(only.id), throwsA(isA<StateError>()));
    expect(await accounts(), 1);

    final other = await repo.create(_acct('Other'));
    await repo.delete(other.id);
    expect(await count('SELECT COUNT(*) AS c FROM accounts WHERE deleted_at IS NULL;'), 1);
  });

  test('zero-account reads are safe: getDefault/getAll empty, manual add and '
      'capture with zero accounts create exactly one currency account via the '
      'repository with outbox intent', () async {
    final repo = DriftAccountRepository(db, outboxQueue: _queue(db));
    expect(await repo.getDefault(), isNull);
    expect(await repo.getAll(), isEmpty);

    final addTransaction = AddTransactionUseCase(
      transactionRepository: DriftTransactionRepository(db),
      merchantCategoryRepository: DriftMerchantCategoryRepository(db),
      suspectedDuplicateRepository: DriftSuspectedDuplicateRepository(db),
      accountRepository: repo,
    );
    final result = await addTransaction(
      rawMessage: 'خصم 20 ريال من حسابك xxxx4521 لدى متجر',
    );
    expect(result.transaction, isNotNull);
    expect(await accounts(), 1);
    final acct = (await repo.getAll()).single;
    expect(acct.currency, 'SAR');
    expect(acct.name, 'حساب SAR');
    expect(result.transaction!.accountId, acct.id);
    expect(
      await count("SELECT COUNT(*) AS c FROM planning_sync_outbox "
          "WHERE entity_id = '${acct.id}';"),
      greaterThan(0),
    );

    // A second capture in the same currency reuses it.
    await addTransaction(rawMessage: 'خصم 30 ريال من حسابك xxxx4521 لدى متجر2');
    expect(await accounts(), 1);
  });
}
