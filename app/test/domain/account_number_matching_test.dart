import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/repositories/drift_account_repository.dart';
import 'package:money_companion/data/repositories/drift_merchant_category_repository.dart';
import 'package:money_companion/data/repositories/drift_suspected_duplicate_repository.dart';
import 'package:money_companion/data/repositories/drift_transaction_repository.dart';
import 'package:money_companion/domain/entities/account_entity.dart';
import 'package:money_companion/domain/usecases/add_transaction_usecase.dart';

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'memory-key';
  @override
  Future<String?> readStoredKey() async => 'memory-key';
}

void main() {
  late AppDatabase db;
  late DriftAccountRepository accounts;
  late AddTransactionUseCase addTransaction;

  setUp(() async {
    db = await AppDatabase.open(
      executor: NativeDatabase.memory(),
      keyStore: _MemoryKeyStore(),
    );
    accounts = DriftAccountRepository(db);
    addTransaction = AddTransactionUseCase(
      transactionRepository: DriftTransactionRepository(db),
      merchantCategoryRepository: DriftMerchantCategoryRepository(db),
      suspectedDuplicateRepository: DriftSuspectedDuplicateRepository(db),
      accountRepository: accounts,
    );
  });
  tearDown(() async => db.close());

  AccountEntity acct(String name, {bool isDefault = false, String? number}) {
    final now = DateTime.utc(2026);
    return AccountEntity(
      id: '',
      name: name,
      currency: 'SAR',
      type: AccountType.bank,
      isDefault: isDefault,
      sortOrder: 0,
      createdAt: now,
      updatedAt: now,
      bankAccountNumber: number,
    );
  }

  test('account-number match wins over currency default', () async {
    // Both accounts are SAR; without number matching a capture would land on
    // the default (first SAR). The number in the SMS must route it to target.
    await accounts.create(acct('افتراضي', isDefault: true));
    final target = await accounts.create(acct('راتب', number: '9876004521'));

    final result = await addTransaction(
      rawMessage: 'خصم 20 ريال من حسابك xxxx4521 لدى متجر',
    );
    expect(result.transaction, isNotNull);
    expect(result.transaction!.accountId, target.id);
  });

  test('no matching number falls back to currency/default resolution',
      () async {
    final def = await accounts.create(acct('افتراضي', isDefault: true));
    await accounts.create(acct('راتب', number: '9876004521'));

    // SMS mentions an account number no account has → falls back to default.
    final result = await addTransaction(
      rawMessage: 'خصم 20 ريال من حسابك xxxx0000 لدى متجر',
    );
    expect(result.transaction!.accountId, def.id);
  });
}
