import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/repositories/drift_account_repository.dart';
import 'package:money_companion/domain/entities/account_entity.dart';
import 'package:money_companion/domain/finance/money.dart';

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'memory-key';
  @override
  Future<String?> readStoredKey() async => 'memory-key';
}

AccountEntity _account({
  String name = 'حساب',
  AccountType type = AccountType.bank,
  double? initialBalance,
  String? bankAccountNumber,
  double? creditLimit,
  double? availableCredit,
  int? paymentDueDay,
  String? walletProvider,
  bool excludeFromTotals = false,
  Map<String, dynamic>? metadata,
}) {
  final now = DateTime.utc(2026, 7, 21);
  return AccountEntity(
    id: '',
    name: name,
    currency: 'SAR',
    type: type,
    isDefault: false,
    sortOrder: 0,
    createdAt: now,
    updatedAt: now,
    initialBalanceMoney:
        initialBalance == null ? null : Money.fromLegacyReal(initialBalance, 'SAR'),
    bankAccountNumber: bankAccountNumber,
    creditLimitMoney:
        creditLimit == null ? null : Money.fromLegacyReal(creditLimit, 'SAR'),
    availableCreditMoney: availableCredit == null
        ? null
        : Money.fromLegacyReal(availableCredit, 'SAR'),
    paymentDueDay: paymentDueDay,
    walletProvider: walletProvider,
    excludeFromTotals: excludeFromTotals,
    metadata: metadata,
  );
}

void main() {
  late AppDatabase db;
  late DriftAccountRepository repo;

  setUp(() async {
    db = await AppDatabase.open(
      executor: NativeDatabase.memory(),
      keyStore: _MemoryKeyStore(),
    );
    repo = DriftAccountRepository(db);
  });

  tearDown(() async => db.close());

  test('extended fields round-trip through create + read', () async {
    final saved = await repo.create(_account(
      type: AccountType.card,
      creditLimit: 5000,
      availableCredit: 3200.5,
      paymentDueDay: 25,
      bankAccountNumber: '1234567890',
      excludeFromTotals: true,
      metadata: {'instapay_fee': 'sender', 'atm': 'ignore'},
    ));
    final read = await repo.getById(saved.id);
    expect(read, isNotNull);
    expect(read!.creditLimit, 5000);
    expect(read.availableCredit, 3200.5);
    expect(read.paymentDueDay, 25);
    expect(read.bankAccountNumber, '1234567890');
    expect(read.excludeFromTotals, isTrue);
    expect(read.metadata?['instapay_fee'], 'sender');
    expect(read.metadata?['atm'], 'ignore');
    expect(read.isCreditCard, isTrue);
  });

  test('wallet provider + starting balance persist (reuses initial_balance)',
      () async {
    final saved = await repo.create(_account(
      type: AccountType.wallet,
      initialBalance: 150,
      walletProvider: 'vodafone_cash',
    ));
    final read = await repo.getById(saved.id);
    expect(read!.initialBalance, 150);
    expect(read.walletProvider, 'vodafone_cash');
  });

  test('backward compatible: account with no extended fields reads defaults',
      () async {
    final saved =
        await repo.create(_account(name: 'كاش', type: AccountType.cash));
    final read = await repo.getById(saved.id);
    expect(read!.creditLimit, isNull);
    expect(read.bankAccountNumber, isNull);
    expect(read.walletProvider, isNull);
    expect(read.paymentDueDay, isNull);
    expect(read.metadata, isNull);
    expect(read.excludeFromTotals, isFalse);
  });

  test('update persists changes to extended fields', () async {
    final saved = await repo.create(_account(type: AccountType.card));
    final updated = await repo.update(saved.copyWith(
      creditLimitMoney: Money.fromLegacyReal(8000, 'SAR'),
      paymentDueDay: 5,
    ));
    final read = await repo.getById(updated.id);
    expect(read!.creditLimit, 8000);
    expect(read.paymentDueDay, 5);
  });
}
