import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/repositories/drift_merchant_category_repository.dart';
import 'package:money_companion/data/repositories/drift_transaction_repository.dart';
import 'package:money_companion/domain/usecases/add_transaction_usecase.dart';
import 'package:money_companion/domain/finance/money.dart';

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'memory-key';

  @override
  Future<String?> readStoredKey() async => 'memory-key';
}

String _purchase(String merchant, String date, double amount) => '''
عملية شراء
مبلغ:SAR ${amount.toStringAsFixed(2)}
لدى:$merchant
في:$date 12:00''';

void main() {
  late AppDatabase db;
  late DriftTransactionRepository txRepo;
  late AddTransactionUseCase addTransaction;

  setUp(() async {
    db = await AppDatabase.open(
      executor: NativeDatabase.memory(),
      keyStore: _MemoryKeyStore(),
    );
    txRepo = DriftTransactionRepository(db);
    addTransaction = AddTransactionUseCase(
      transactionRepository: txRepo,
      merchantCategoryRepository: DriftMerchantCategoryRepository(db),
    );
  });

  tearDown(() async => db.close());

  test('merchantBreakdown يجمع إنفاق المتجر خلال الفترة', () async {
    await addTransaction(
      rawMessage: _purchase('NETFLIX', '2026-01-10', 56),
      senderId: 'SNB',
    );
    await addTransaction(
      rawMessage: _purchase('NETFLIX', '2026-02-10', 56),
      senderId: 'SNB',
    );

    final breakdown = await txRepo.merchantBreakdown(
      from: DateTime.utc(2026, 1, 1),
      to: DateTime.utc(2026, 3, 1),
      currency: 'SAR',
    );

    expect(breakdown, isNotEmpty);
    expect(breakdown.first.name, 'NETFLIX');
    expect(breakdown.first.total, Money(11200, 'SAR'));
  });

  test('recurringCandidates يكتشف الاشتراك المتكرر عبر شهرين', () async {
    await addTransaction(
      rawMessage: _purchase('NETFLIX', '2026-01-10', 56),
      senderId: 'SNB',
    );
    await addTransaction(
      rawMessage: _purchase('NETFLIX', '2026-02-10', 56),
      senderId: 'SNB',
    );

    final recurring = await txRepo.recurringCandidates();

    expect(recurring, isNotEmpty);
    final netflix = recurring.firstWhere((r) => r.name == 'NETFLIX');
    expect(netflix.monthsSeen, 2);
    expect(netflix.averageAmount, 56);
  });

  test('عملية واحدة لا تُعدّ اشتراكاً متكرراً', () async {
    await addTransaction(
      rawMessage: _purchase('SPOTIFY', '2026-01-10', 21),
      senderId: 'SNB',
    );
    final recurring = await txRepo.recurringCandidates();
    expect(recurring.where((r) => r.name == 'SPOTIFY'), isEmpty);
  });
}
