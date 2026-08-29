import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/repositories/drift_merchant_category_repository.dart';
import 'package:money_companion/data/repositories/drift_transaction_repository.dart';
import 'package:money_companion/domain/usecases/add_transaction_usecase.dart';
import 'package:money_companion/domain/usecases/correct_category_usecase.dart';
import 'package:money_companion/engine/intelligence/merchant_intelligence_store.dart';

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'memory-key';
  @override
  Future<String?> readStoredKey() async => 'memory-key';
}

/// BUG 5 — the on-device model must actually receive explicit user corrections.
///
/// Before this fix `CharNgramMerchantClassifier.learn()` existed, was tested in
/// isolation, and was called from nowhere in `lib/`: `CorrectCategoryUseCase`
/// built a `Categorizer` with no `intelligence` at all, so a correction could
/// never reach the model. These tests drive the real use case over a real
/// in-memory database, so the wiring itself is what is under test.
void main() {
  late AppDatabase db;
  late DriftTransactionRepository transactionRepository;
  late DriftMerchantCategoryRepository merchantCategoryRepository;
  late AddTransactionUseCase addTransaction;
  late MerchantIntelligenceStore store;
  late CorrectCategoryUseCase correctCategory;

  setUp(() async {
    db = await AppDatabase.open(
      executor: NativeDatabase.memory(),
      keyStore: _MemoryKeyStore(),
    );
    transactionRepository = DriftTransactionRepository(db);
    merchantCategoryRepository = DriftMerchantCategoryRepository(db);
    store = MerchantIntelligenceStore();
    addTransaction = AddTransactionUseCase(
      transactionRepository: transactionRepository,
      merchantCategoryRepository: merchantCategoryRepository,
      merchantIntelligence: store,
    );
    correctCategory = CorrectCategoryUseCase(
      transactionRepository: transactionRepository,
      merchantCategoryRepository: merchantCategoryRepository,
      merchantIntelligence: store,
    );
  });

  tearDown(() async => db.close());

  // A merchant the shipped catalog has never seen, so the model is the only
  // thing that could ever categorise it.
  const merchant = 'ZARYAB DIMASHQI TRDG';
  const sms = 'عملية شراء\nمبلغ:SAR 18.00\nلدى:$merchant\nفي:2026-04-08 18:30';

  test('the model refuses this merchant before any correction', () async {
    expect(store.predict(merchant), isNull);
  });

  test('an "all merchant transactions" correction teaches the model', () async {
    final added = await addTransaction(rawMessage: sms);
    expect(store.predict(merchant), isNull, reason: 'still unknown pre-fix');

    await correctCategory(
      transactionId: added.transaction!.id,
      categoryKey: 'restaurants',
      scope: CategoryCorrectionScope.allMerchantTransactions,
    );

    expect(store.predict(merchant)?.categoryKey, 'restaurants');
  });

  test('a "this transaction only" correction does NOT teach the model', () async {
    final added = await addTransaction(rawMessage: sms);

    await correctCategory(
      transactionId: added.transaction!.id,
      categoryKey: 'restaurants',
      scope: CategoryCorrectionScope.thisTransactionOnly,
    );

    // That scope is the user saying "just this one". Teaching the model from it
    // would generalise a decision they explicitly declined to generalise.
    expect(store.predict(merchant), isNull);
    expect(store.learnedCount, 0);
  });

  test('correcting one merchant does not disturb another', () async {
    const other = 'MAKANI ROASTERY BR 12';
    const otherSms =
        'عملية شراء\nمبلغ:SAR 21.00\nلدى:$other\nفي:2026-04-08 19:30';

    final a = await addTransaction(rawMessage: sms);
    await addTransaction(rawMessage: otherSms);
    final otherBefore = store.predict(other)?.categoryKey;

    await correctCategory(
      transactionId: a.transaction!.id,
      categoryKey: 'restaurants',
      scope: CategoryCorrectionScope.allMerchantTransactions,
    );

    expect(store.predict(merchant)?.categoryKey, 'restaurants');
    expect(store.predict(other)?.categoryKey, otherBefore,
        reason: 'cross-merchant corruption');
  });

  test('the correction is still durable when no model is attached', () async {
    // The model must never be load-bearing for a user action.
    final noModel = CorrectCategoryUseCase(
      transactionRepository: transactionRepository,
      merchantCategoryRepository: merchantCategoryRepository,
    );
    final added = await addTransaction(rawMessage: sms);
    await noModel(
      transactionId: added.transaction!.id,
      categoryKey: 'restaurants',
      scope: CategoryCorrectionScope.allMerchantTransactions,
    );
    final learned = await merchantCategoryRepository.getLearnedCategoryMap();
    expect(learned.keys.map((k) => k.toUpperCase()),
        contains(merchant.toUpperCase()));
  });

  test('a rehydrated store reproduces the taught prediction', () async {
    final added = await addTransaction(rawMessage: sms);
    await correctCategory(
      transactionId: added.transaction!.id,
      categoryKey: 'restaurants',
      scope: CategoryCorrectionScope.allMerchantTransactions,
    );

    // What the DI provider does on the next app start.
    final restarted = MerchantIntelligenceStore()
      ..seedFromLearnedMap(
          await merchantCategoryRepository.getLearnedCategoryMap());

    expect(restarted.predict(merchant)?.categoryKey, 'restaurants',
        reason: 'the correction must survive a process restart');
  });
}
