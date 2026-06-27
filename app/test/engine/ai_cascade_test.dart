import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/domain/entities/account_entity.dart';
import 'package:money_companion/domain/entities/transaction_entity.dart';
import 'package:money_companion/domain/repositories/account_repository.dart';
import 'package:money_companion/domain/repositories/dedup_store.dart';
import 'package:money_companion/domain/repositories/merchant_category_repository.dart';
import 'package:money_companion/domain/repositories/sender_bank_mapping_repository.dart';
import 'package:money_companion/domain/repositories/transaction_repository.dart';
import 'package:money_companion/domain/usecases/add_transaction_usecase.dart';
import 'package:money_companion/domain/usecases/resolve_bank_for_sender_usecase.dart';
import 'package:money_companion/engine/ai/ai_parser_client.dart';
import 'package:money_companion/engine/ai/ai_sender_failure_tracker.dart';
import 'package:money_companion/engine/models/parsed_transaction.dart';
import 'package:money_companion/engine/models/transaction_source.dart';
import 'package:money_companion/engine/models/transaction_type.dart';
import 'package:money_companion/engine/parser/bank_profile.dart';
import 'package:money_companion/engine/parser/parse_result.dart';
import 'package:money_companion/engine/parser/parser_isolate.dart';
import 'package:money_companion/domain/entities/sender_bank_mapping_entity.dart';

class _FakeParserIsolate extends ParserIsolate {
  const _FakeParserIsolate(this._result);

  final ParseResult _result;

  @override
  Future<ParseResult?> parse(
    String rawText, {
    String? senderId,
    List<BankProfile> bankProfiles = const [],
    String defaultCurrency = 'SAR',
  }) async =>
      _result;
}

class _StubTransactionRepo implements TransactionRepository {
  @override
  Future<TransactionEntity?> findDuplicate({
    required double amount,
    required String rawMerchant,
    required DateTime occurredAt,
  }) async =>
      null;

  @override
  Future<TransactionEntity> saveTransaction({
    required TransactionEntity transaction,
    required String? categoryKey,
  }) async =>
      transaction;

  @override
  Future<TransactionEntity?> getById(String id) async => null;

  @override
  Future<TransactionEntity> confirm(String id) async =>
      throw UnimplementedError();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _CapturingTransactionRepo extends _StubTransactionRepo {
  _CapturingTransactionRepo({required this.onSave, this.onSaveCategory});

  final void Function(TransactionEntity transaction) onSave;
  final void Function(String? categoryKey)? onSaveCategory;

  @override
  Future<TransactionEntity> saveTransaction({
    required TransactionEntity transaction,
    required String? categoryKey,
  }) async {
    onSave(transaction);
    onSaveCategory?.call(categoryKey);
    return transaction;
  }
}

class _StubMerchantRepo implements MerchantCategoryRepository {
  @override
  Future<bool> hasCategoryForMerchant(String rawMerchant) async => false;

  @override
  Future<Map<String, String>> getLearnedCategoryMap() async => {};

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _StubMerchantRepoWithKnownMerchant implements MerchantCategoryRepository {
  @override
  Future<bool> hasCategoryForMerchant(String rawMerchant) async => true;

  @override
  Future<Map<String, String>> getLearnedCategoryMap() async =>
      {'STARBUCKS': 'restaurants'};

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _NoDedupStore implements DedupStore {
  @override
  Future<String?> transactionIdFor(String hash, DateTime occurredAt) async =>
      null;

  @override
  Future<void> mark(
    String hash, {
    required String transactionId,
    required DateTime occurredAt,
  }) async {}
}

/// Account repo with a single default account in [_default]'s currency. Used to
/// give the use case a "home currency" so foreign spends can be relocated.
class _SingleAccountRepo implements AccountRepository {
  _SingleAccountRepo(this._default);
  final AccountEntity _default;

  @override
  Future<AccountEntity?> getDefault() async => _default;

  @override
  Future<List<AccountEntity>> getAll() async => [_default];

  @override
  Future<AccountEntity?> getById(String id) async =>
      id == _default.id ? _default : null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Stores saved transactions by id so dedup (which re-reads via getById) works
/// realistically, and counts saves to catch double-counting.
class _StoringTransactionRepo implements TransactionRepository {
  final Map<String, TransactionEntity> byId = {};
  int saveCount = 0;

  @override
  Future<TransactionEntity> saveTransaction({
    required TransactionEntity transaction,
    String? categoryKey,
  }) async {
    saveCount++;
    byId[transaction.id] = transaction;
    return transaction;
  }

  @override
  Future<TransactionEntity?> getById(String id) async => byId[id];

  @override
  Future<TransactionEntity?> findDuplicate({
    required double amount,
    required String rawMerchant,
    required DateTime occurredAt,
  }) async =>
      null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

AccountEntity _homeAccount(String currency) => AccountEntity(
      id: 'home-acc',
      name: 'الحساب الرئيسي',
      currency: currency,
      type: AccountType.bank,
      isDefault: true,
      sortOrder: 0,
      createdAt: DateTime.utc(2026, 1, 1),
      updatedAt: DateTime.utc(2026, 1, 1),
    );

class _MemoryDedupStore implements DedupStore {
  final Map<String, String> hashes = {};

  @override
  Future<String?> transactionIdFor(String hash, DateTime occurredAt) async =>
      hashes[hash];

  @override
  Future<void> mark(
    String hash, {
    required String transactionId,
    required DateTime occurredAt,
  }) async {
    hashes[hash] = transactionId;
  }
}

class _CountingAiClient implements AiParserClient {
  int callCount = 0;

  @override
  Future<AiParseResponse?> parse({
    required String sanitizedSms,
    required String senderId,
    required String installId,
  }) async {
    callCount++;
    return null;
  }
}

class _CapturingAiClient implements AiParserClient {
  _CapturingAiClient({required this.onParse, this.response});

  final void Function(String sanitizedSms, String senderId, String installId)
      onParse;
  final AiParseResponse? response;

  @override
  Future<AiParseResponse?> parse({
    required String sanitizedSms,
    required String senderId,
    required String installId,
  }) async {
    onParse(sanitizedSms, senderId, installId);
    return response;
  }
}

class _FixedResponseAiClient implements AiParserClient {
  const _FixedResponseAiClient(this.response);

  final AiParseResponse response;

  @override
  Future<AiParseResponse?> parse({
    required String sanitizedSms,
    required String senderId,
    required String installId,
  }) async =>
      response;
}

class _ThrowingAiClient implements AiParserClient {
  const _ThrowingAiClient(this.reason);

  final String reason;

  @override
  Future<AiParseResponse?> parse({
    required String sanitizedSms,
    required String senderId,
    required String installId,
  }) async {
    throw AiParseException(reason);
  }
}

class _SingleSenderMappingRepository implements SenderBankMappingRepository {
  const _SingleSenderMappingRepository(this.mapping);

  final SenderBankMappingEntity? mapping;

  @override
  Future<SenderBankMappingEntity?> getBySender(String senderId) async {
    if (mapping == null) return null;
    return senderId.trim().toLowerCase() ==
            mapping!.senderId.trim().toLowerCase()
        ? mapping
        : null;
  }

  @override
  Future<SenderBankMappingEntity?> getConfirmedBySender(String senderId) async {
    final value = await getBySender(senderId);
    return value?.status == SenderBankMappingStatus.confirmed ? value : null;
  }

  @override
  Future<SenderBankMappingEntity?> getActiveSuggestionBySender(
    String senderId, {
    DateTime? now,
  }) async =>
      getBySender(senderId);

  @override
  Future<bool> suppressesDiscoveryPrompt(
    String senderId, {
    DateTime? now,
  }) async {
    final value = await getBySender(senderId);
    return value?.suppressesDiscovery(now ?? DateTime.now().toUtc()) ?? false;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  setUp(() {
    AiSenderFailureTracker.instance.resetForTest();
  });

  test('AI-first: clean parse still routes through AI (one call)', () async {
    // Under AI-first, even a high-confidence on-device parse is sent to the AI
    // parser (when consent is granted). The AI here returns null, so the trusted
    // on-device parse is what gets saved — but the call must still have happened.
    final countingClient = _CountingAiClient();
    final fakeParsed = ParsedTransaction(
      amount: 500.0,
      currency: 'SAR',
      type: TransactionType.payment,
      source: TransactionSource.bank,
      rawMerchant: 'STARBUCKS',
      occurredAt: DateTime.utc(2026, 6, 16, 12, 0, 0),
      parseConfidence: 0.95,
    );
    final fakeParseResult = ParseResult.success(fakeParsed, bankKey: 'alrajhi');

    final useCase = AddTransactionUseCase(
      transactionRepository: _StubTransactionRepo(),
      merchantCategoryRepository: _StubMerchantRepoWithKnownMerchant(),
      parserIsolate: _FakeParserIsolate(fakeParseResult),
      loadAiConsent: () async => true,
      aiClient: countingClient,
      dedupStore: _NoDedupStore(),
      resolveBankForSenderUseCase: const ResolveBankForSenderUseCase(
        mappingRepository: _SingleSenderMappingRepository(null),
      ),
    );
    await useCase(rawMessage: 'dummy');

    expect(countingClient.callCount, 1);
  });

  test('AI-first: unsupported-bank generic parse routes through AI (one call)',
      () async {
    // AI returns null → the on-device generic parse is saved (pending).
    final countingClient = _CountingAiClient();
    TransactionEntity? savedTransaction;
    final capturingRepo = _CapturingTransactionRepo(
      onSave: (t) => savedTransaction = t,
    );

    final useCase = AddTransactionUseCase(
      transactionRepository: capturingRepo,
      merchantCategoryRepository: _StubMerchantRepo(),
      loadAiConsent: () async => true,
      aiClient: countingClient,
      dedupStore: _NoDedupStore(),
    );

    await useCase(
      rawMessage: 'Trx. of AED 50.00 on your a/c ****0535 at ABU DHABI '
          'NATIONAL OIL ABU DHABI AE. Avl Bal is AED 12956.50',
      senderId: 'ADIB',
    );

    expect(countingClient.callCount, 1);
    expect(savedTransaction, isNotNull);
    expect(savedTransaction!.amount, 50.00);
    expect(savedTransaction!.currency, 'AED');
    expect(savedTransaction!.rawMerchant, 'ABU DHABI NATIONAL OIL');
    expect(savedTransaction!.balanceAfter, 12956.50);
    expect(savedTransaction!.status, TransactionStatus.pending);
  });

  test('confirmed sender-bank mapping still uses AI-first parsing', () async {
    // Use a sender NOT in BankProfiles.all so the mapping-based resolution fires.
    const unknownSender = 'GULFCORP-XYZ';
    final countingClient = _CountingAiClient();
    final now = DateTime.utc(2026, 6, 16, 12, 0, 0);
    final mapping = SenderBankMappingEntity(
      id: 'mapping-gulfcorp',
      senderId: unknownSender,
      normalizedSenderId: unknownSender.toUpperCase(),
      bankKey: 'dubai_bank',
      suggestedBankName: 'Unknown Gulf Bank',
      suggestedCountry: 'AE',
      confidence: 0.98,
      status: SenderBankMappingStatus.confirmed,
      source: SenderBankMappingSource.userManual,
      firstSeenAt: now,
      lastSeenAt: now,
      confirmedAt: now,
      rejectedAt: null,
      rejectionExpiresAt: null,
      createdAt: now,
      updatedAt: now,
      syncedAt: null,
      syncStatus: SenderBankMappingSyncStatus.pending,
    );
    final fakeParsed = ParsedTransaction(
      amount: 50.0,
      currency: 'AED',
      type: TransactionType.payment,
      source: TransactionSource.bank,
      rawMerchant: 'MERCHANT STORE',
      occurredAt: now,
      parseConfidence: 0.50,
    );
    final fakeParseResult =
        ParseResult.success(fakeParsed, bankKey: 'dubai_bank');

    final useCase = AddTransactionUseCase(
      transactionRepository: _StubTransactionRepo(),
      merchantCategoryRepository: _StubMerchantRepo(),
      parserIsolate: _FakeParserIsolate(fakeParseResult),
      loadAiConsent: () async => true,
      aiClient: countingClient,
      dedupStore: _NoDedupStore(),
      resolveBankForSenderUseCase: ResolveBankForSenderUseCase(
        mappingRepository: _SingleSenderMappingRepository(mapping),
      ),
    );

    final result = await useCase(
      rawMessage: 'Trx. of AED 50.00 on your a/c ****0535 at MERCHANT STORE.',
      senderId: unknownSender,
    );

    expect(countingClient.callCount, 1);
    expect(result.outcome, AddTransactionOutcome.added);
    expect(result.transaction?.status, TransactionStatus.pending);
  });

  test('transfer to AI: beneficiary name absent in outgoing payload', () async {
    String? capturedSanitized;
    const rawTransferSms = 'تم تحويل مبلغ 200.00 ريال إلى: سارة العمري';
    final fakeParsed = ParsedTransaction(
      amount: 200.0,
      currency: 'SAR',
      type: TransactionType.transfer,
      source: TransactionSource.bank,
      rawMerchant: 'سارة العمري',
      occurredAt: DateTime.utc(2026, 6, 16, 12, 0, 0),
      parseConfidence: 0.60,
    );
    final fakeParseResult = ParseResult.success(fakeParsed);
    final capturingClient = _CapturingAiClient(
      onParse: (s, _, __) => capturedSanitized = s,
    );

    final useCase = AddTransactionUseCase(
      transactionRepository: _StubTransactionRepo(),
      merchantCategoryRepository: _StubMerchantRepo(),
      parserIsolate: _FakeParserIsolate(fakeParseResult),
      loadAiConsent: () async => true,
      aiClient: capturingClient,
      dedupStore: _NoDedupStore(),
    );
    await useCase(rawMessage: rawTransferSms);

    expect(capturedSanitized, isNotNull);
    expect(capturedSanitized, isNot(contains('سارة')));
    expect(capturedSanitized, isNot(contains('العمري')));
  });

  test('AI fabricated amount is ignored while the local parse is saved',
      () async {
    const rawSms = 'خصم 200.00 ريال من حسابك';
    final fakeParsed = ParsedTransaction(
      amount: 200.0,
      currency: 'SAR',
      type: TransactionType.payment,
      source: TransactionSource.bank,
      rawMerchant: null,
      occurredAt: DateTime.utc(2026, 6, 16, 12, 0, 0),
      parseConfidence: 0.50,
    );
    final fakeParseResult = ParseResult.success(fakeParsed);
    const lyingClient = _FixedResponseAiClient(AiParseResponse(
      amount: 999.99,
      currency: 'SAR',
      type: 'payment',
    ));

    TransactionEntity? saved;
    final capturingRepo = _CapturingTransactionRepo(onSave: (t) => saved = t);

    final useCase = AddTransactionUseCase(
      transactionRepository: capturingRepo,
      merchantCategoryRepository: _StubMerchantRepo(),
      parserIsolate: _FakeParserIsolate(fakeParseResult),
      loadAiConsent: () async => true,
      aiClient: lyingClient,
      dedupStore: _NoDedupStore(),
    );
    final result = await useCase(rawMessage: rawSms);

    expect(result.outcome, AddTransactionOutcome.added);
    expect(saved, isNotNull);
    expect(saved!.amount, 200.0);
    expect(saved!.source, TransactionSourceEntity.bank);
  });

  test('AI grounded but mismatched amount is ignored for IPN transfer sent',
      () async {
    const rawSms =
        'IPN transfer sent with amount of EGP 31.43 from 1938 on 15/03 '
        'at 02:18 PM. Ref# 22762b03. For more details call 16607';
    const fakeParsed = ParsedTransaction(
      amount: 31.43,
      currency: 'EGP',
      type: TransactionType.transfer,
      source: TransactionSource.bank,
      rawMerchant: null,
      parseConfidence: 0.95,
    );
    final fakeParseResult =
        ParseResult.success(fakeParsed, bankKey: 'instapay_eg');
    const confusedAiClient = _FixedResponseAiClient(AiParseResponse(
      amount: 1938.0,
      currency: 'EGP',
      type: 'transfer',
      categoryKey: 'transfers',
    ));

    TransactionEntity? saved;
    String? savedCategory;
    final capturingRepo = _CapturingTransactionRepo(
      onSave: (t) => saved = t,
      onSaveCategory: (category) => savedCategory = category,
    );

    final useCase = AddTransactionUseCase(
      transactionRepository: capturingRepo,
      merchantCategoryRepository: _StubMerchantRepo(),
      parserIsolate: _FakeParserIsolate(fakeParseResult),
      loadAiConsent: () async => true,
      aiClient: confusedAiClient,
      dedupStore: _NoDedupStore(),
    );

    final result = await useCase(rawMessage: rawSms, senderId: 'IPN');

    expect(result.outcome, AddTransactionOutcome.added);
    expect(saved, isNotNull);
    expect(saved!.amount, 31.43);
    // Outgoing transfer → counts as an expense (payment), shown under transfers.
    expect(saved!.type, TransactionTypeEntity.payment);
    expect(savedCategory, 'transfers');
  });

  test('transfer person name from AI is not treated as merchant or place',
      () async {
    const rawSms =
        'Transfer sent with amount of EGP 250.00 to Ahmed Hassan on 08/06';
    const aiClient = _FixedResponseAiClient(AiParseResponse(
      amount: 250,
      currency: 'EGP',
      type: 'transfer',
      merchantName: 'Ahmed Hassan',
      categoryKey: 'other',
    ));
    TransactionEntity? saved;
    String? savedCategory;
    var mapsLookupCount = 0;
    final useCase = AddTransactionUseCase(
      transactionRepository: _CapturingTransactionRepo(
        onSave: (transaction) => saved = transaction,
        onSaveCategory: (category) => savedCategory = category,
      ),
      merchantCategoryRepository: _StubMerchantRepo(),
      parserIsolate: _FakeParserIsolate(ParseResult.notTransaction()),
      loadAiConsent: () async => true,
      aiClient: aiClient,
      dedupStore: _NoDedupStore(),
      resolveMerchantCategory: (_) async {
        mapsLookupCount++;
        return 'shopping';
      },
    );

    final result = await useCase(rawMessage: rawSms, senderId: 'CIB');

    expect(result.outcome, AddTransactionOutcome.added);
    // Sent to a person → expense (payment); the person's name is never stored
    // as a merchant nor sent to Maps.
    expect(saved!.type, TransactionTypeEntity.payment);
    expect(saved!.rawMerchant, isNull);
    expect(savedCategory, 'transfers');
    expect(mapsLookupCount, 0);
  });

  test('IPN credited from a person counts as income, name dropped', () async {
    const rawSms =
        'Your account was credited by EGP 2000 on 14-06 23:10 IPN REF# '
        '92420545267 from **نبيل نصير عبدالسيد ميخائ for details please call 19342.';
    final aiClient = _FixedResponseAiClient(AiParseResponse(
      amount: 2000,
      currency: 'EGP',
      type: 'income',
      merchantName: 'نبيل نصير عبدالسيد ميخائ',
      categoryKey: 'income',
      direction: 'credit',
      occurredAt: DateTime(2026, 6, 14, 23, 10),
    ));
    TransactionEntity? saved;
    String? savedCategory;
    final useCase = AddTransactionUseCase(
      transactionRepository: _CapturingTransactionRepo(
        onSave: (transaction) => saved = transaction,
        onSaveCategory: (category) => savedCategory = category,
      ),
      merchantCategoryRepository: _StubMerchantRepo(),
      parserIsolate: _FakeParserIsolate(ParseResult.notTransaction()),
      loadAiConsent: () async => true,
      aiClient: aiClient,
      dedupStore: _NoDedupStore(),
    );

    final result = await useCase(rawMessage: rawSms, senderId: 'IPN');

    expect(result.outcome, AddTransactionOutcome.added);
    expect(saved!.amount, 2000);
    expect(saved!.currency, 'EGP');
    expect(saved!.occurredAt, DateTime.utc(2026, 6, 14, 20, 10));
    // Money received from outside → income (counts), payer name dropped.
    expect(saved!.type, TransactionTypeEntity.income);
    expect(saved!.rawMerchant, isNull);
    expect(saved!.direction, TransactionDirectionEntity.credit);
    expect(savedCategory, 'income');
  });

  test('same-amount transfers with different references are not duplicates',
      () async {
    final dedup = _MemoryDedupStore();
    final repo = _CapturingTransactionRepo(onSave: (_) {});
    AddTransactionUseCase buildUseCase(String rawSms) {
      return AddTransactionUseCase(
        transactionRepository: repo,
        merchantCategoryRepository: _StubMerchantRepo(),
        parserIsolate: _FakeParserIsolate(ParseResult.success(
          const ParsedTransaction(
            amount: 9000,
            currency: 'EGP',
            type: TransactionType.transfer,
            source: TransactionSource.aiParsed,
            parseConfidence: 0.79,
          ),
        )),
        loadAiConsent: () async => false,
        dedupStore: dedup,
      );
    }

    const first = 'تم إضافة تحويل لحظي بمبلغ 9000.00 جم رقم مرجعي 111 يوم 06';
    const second = 'تم إضافة تحويل لحظي بمبلغ 9000.00 جم رقم مرجعي 222 يوم 06';

    final firstResult = await buildUseCase(first).call(rawMessage: first);
    final secondResult = await buildUseCase(second).call(rawMessage: second);

    expect(firstResult.outcome, AddTransactionOutcome.added);
    expect(secondResult.outcome, AddTransactionOutcome.added);
  });

  test('Arabic day and time fallback preserves occurred date', () async {
    TransactionEntity? saved;
    final useCase = AddTransactionUseCase(
      transactionRepository: _CapturingTransactionRepo(
          onSave: (transaction) => saved = transaction),
      merchantCategoryRepository: _StubMerchantRepo(),
      parserIsolate: _FakeParserIsolate(ParseResult.notTransaction()),
      loadAiConsent: () async => true,
      aiClient: _CountingAiClient(),
      dedupStore: _NoDedupStore(),
    );
    const rawSms = 'تم إضافة تحويل لحظي لبطاقتكم مسبقة الدفع بمبلغ 9000.00 جم '
        'رقم مرجعي 743706614607 يوم 06 الساعة 13:29';

    final result = await useCase(rawMessage: rawSms, senderId: 'CIB');

    expect(result.outcome, AddTransactionOutcome.added);
    expect(saved, isNotNull);
    expect(saved!.occurredAt.day, 6);
    expect(saved!.occurredAt.hour, 10);
    expect(saved!.occurredAt.minute, 29);
  });

  test('AI category wins over local merchant keyword category', () async {
    const rawSms = 'Purchase EGP 85.00 At STARBUCKS on 08/06 at 06:55 AM';
    const fakeParsed = ParsedTransaction(
      amount: 85.0,
      currency: 'EGP',
      type: TransactionType.payment,
      source: TransactionSource.bank,
      rawMerchant: 'STARBUCKS',
      parseConfidence: 0.95,
    );
    final fakeParseResult = ParseResult.success(fakeParsed);
    const aiClient = _FixedResponseAiClient(AiParseResponse(
      amount: 85.0,
      currency: 'EGP',
      type: 'payment',
      merchantName: 'STARBUCKS',
      categoryKey: 'shopping',
    ));

    String? savedCategory;
    final useCase = AddTransactionUseCase(
      transactionRepository: _CapturingTransactionRepo(
        onSave: (_) {},
        onSaveCategory: (category) => savedCategory = category,
      ),
      merchantCategoryRepository: _StubMerchantRepo(),
      parserIsolate: _FakeParserIsolate(fakeParseResult),
      loadAiConsent: () async => true,
      aiClient: aiClient,
      dedupStore: _NoDedupStore(),
    );

    final result = await useCase(rawMessage: rawSms, senderId: 'CIB');

    expect(result.outcome, AddTransactionOutcome.added);
    expect(savedCategory, 'shopping');
  });

  test('AI-parsed transaction is always pending, never auto-confirmed',
      () async {
    const rawSms = 'خصم 150.00 ريال من حسابك في مطعم البيك';
    final fakeParsed = ParsedTransaction(
      amount: 150.0,
      currency: 'SAR',
      type: TransactionType.payment,
      source: TransactionSource.bank,
      rawMerchant: null,
      occurredAt: DateTime.utc(2026, 6, 16, 12, 0, 0),
      parseConfidence: 0.50,
    );
    final fakeParseResult = ParseResult.success(fakeParsed);
    const aiClient = _FixedResponseAiClient(AiParseResponse(
      amount: 150.0,
      currency: 'SAR',
      type: 'payment',
      merchantName: 'البيك',
    ));

    TransactionEntity? savedTransaction;
    final capturingRepo = _CapturingTransactionRepo(
      onSave: (t) => savedTransaction = t,
    );

    final useCase = AddTransactionUseCase(
      transactionRepository: capturingRepo,
      merchantCategoryRepository: _StubMerchantRepo(),
      parserIsolate: _FakeParserIsolate(fakeParseResult),
      loadAiConsent: () async => true,
      aiClient: aiClient,
      dedupStore: _NoDedupStore(),
    );
    await useCase(rawMessage: rawSms);

    expect(savedTransaction, isNotNull);
    expect(
      savedTransaction!.status,
      TransactionStatus.pending,
      reason:
          'AI-parsed transactions must always be pending — confidence is capped at 0.79',
    );
    expect(savedTransaction!.source, TransactionSourceEntity.aiParsed);
  });

  test('consent off → zero AI calls regardless of trigger conditions',
      () async {
    final countingClient = _CountingAiClient();
    final fakeParsed = ParsedTransaction(
      amount: 300.0,
      currency: 'SAR',
      type: TransactionType.payment,
      source: TransactionSource.bank,
      rawMerchant: null,
      occurredAt: DateTime.utc(2026, 6, 16, 12, 0, 0),
      parseConfidence: 0.40,
    );
    final fakeParseResult = ParseResult.success(fakeParsed);

    final useCase = AddTransactionUseCase(
      transactionRepository: _StubTransactionRepo(),
      merchantCategoryRepository: _StubMerchantRepo(),
      parserIsolate: _FakeParserIsolate(fakeParseResult),
      loadAiConsent: () async => false,
      aiClient: countingClient,
      dedupStore: _NoDedupStore(),
    );
    await useCase(rawMessage: 'dummy 300.00 SAR');

    expect(
      countingClient.callCount,
      0,
      reason: 'AI must never be called when user has not granted consent',
    );
  });

  test('AI-first also sees locally ignored messages before they are ignored',
      () async {
    final countingClient = _CountingAiClient();
    final useCase = AddTransactionUseCase(
      transactionRepository: _StubTransactionRepo(),
      merchantCategoryRepository: _StubMerchantRepo(),
      parserIsolate: _FakeParserIsolate(ParseResult.notTransaction()),
      loadAiConsent: () async => true,
      aiClient: countingClient,
      dedupStore: _NoDedupStore(),
    );

    final result = await useCase(
      rawMessage: 'رمز التحقق الخاص بك هو 123456 ولا تشاركه مع أحد',
      senderId: 'BANKOTP',
    );

    expect(countingClient.callCount, 1);
    expect(result.outcome, AddTransactionOutcome.notTransaction);
    expect(result.droppedByParser, isFalse);
  });

  test('manual paste empty sender is never suppressed after AI failures',
      () async {
    const rawSms =
        'IPN transfer sent with amount of EGP 31.43 from 1938 on 15/03 '
        'at 02:18 PM. Ref# 22762b03. For more details call 16607';
    AiSenderFailureTracker.instance.recordFailure('');
    AiSenderFailureTracker.instance.recordFailure('');
    AiSenderFailureTracker.instance.recordFailure('');

    const aiClient = _FixedResponseAiClient(AiParseResponse(
      amount: 31.43,
      currency: 'EGP',
      type: 'transfer',
      categoryKey: 'transfers',
    ));
    TransactionEntity? saved;
    final useCase = AddTransactionUseCase(
      transactionRepository:
          _CapturingTransactionRepo(onSave: (t) => saved = t),
      merchantCategoryRepository: _StubMerchantRepo(),
      parserIsolate: _FakeParserIsolate(ParseResult.notTransaction()),
      loadAiConsent: () async => true,
      aiClient: aiClient,
      dedupStore: _NoDedupStore(),
    );

    final result = await useCase(rawMessage: rawSms);

    expect(result.outcome, AddTransactionOutcome.added);
    expect(saved, isNotNull);
    expect(saved!.amount, 31.43);
    // Outgoing transfer → expense (payment).
    expect(saved!.type, TransactionTypeEntity.payment);
  });

  test('AI failure reason is surfaced when parser also fails', () async {
    final useCase = AddTransactionUseCase(
      transactionRepository: _StubTransactionRepo(),
      merchantCategoryRepository: _StubMerchantRepo(),
      parserIsolate: _FakeParserIsolate(ParseResult.notTransaction()),
      loadAiConsent: () async => true,
      aiClient: const _ThrowingAiClient('http_429:rate_limit_exceeded'),
      dedupStore: _NoDedupStore(),
    );

    final result = await useCase(rawMessage: 'رسالة بنك غامضة بدون مبلغ');

    expect(result.outcome, AddTransactionOutcome.notTransaction);
    expect(result.aiFailureReason, 'http_429:rate_limit_exceeded');
  });

  test('AI null response is treated as a soft miss, not a visible failure',
      () async {
    final useCase = AddTransactionUseCase(
      transactionRepository: _StubTransactionRepo(),
      merchantCategoryRepository: _StubMerchantRepo(),
      parserIsolate: _FakeParserIsolate(ParseResult.notTransaction()),
      loadAiConsent: () async => true,
      aiClient: _CountingAiClient(),
      dedupStore: _NoDedupStore(),
    );

    final result = await useCase(rawMessage: 'رسالة بنك غامضة بدون مبلغ');

    expect(result.outcome, AddTransactionOutcome.notTransaction);
    expect(result.aiFailureReason, isNull);
  });

  test('amount and currency fallback saves pending transaction after AI null',
      () async {
    TransactionEntity? saved;
    String? savedCategory;
    final useCase = AddTransactionUseCase(
      transactionRepository: _CapturingTransactionRepo(
        onSave: (transaction) => saved = transaction,
        onSaveCategory: (category) => savedCategory = category,
      ),
      merchantCategoryRepository: _StubMerchantRepo(),
      parserIsolate: _FakeParserIsolate(ParseResult.notTransaction()),
      loadAiConsent: () async => true,
      aiClient: _CountingAiClient(),
      dedupStore: _NoDedupStore(),
    );

    final result = await useCase(
      rawMessage: 'Purchase EGP 40.00 At RANDOM SHOP on 08/06 at 06:55 AM',
      senderId: 'CIB',
    );

    expect(result.outcome, AddTransactionOutcome.added);
    expect(result.requiresConfirmation, isTrue);
    expect(saved, isNotNull);
    expect(saved!.amount, 40);
    expect(saved!.currency, 'EGP');
    expect(saved!.rawMerchant, 'RANDOM SHOP');
    expect(savedCategory, 'shopping');
  });

  test(
      'trusted AI result (category + grounded direction) auto-confirms '
      'for a known merchant', () async {
    const rawSms = 'خصم 150.00 ريال من حسابك في ستاربكس';
    final fakeParsed = ParsedTransaction(
      amount: 150.0,
      currency: 'SAR',
      type: TransactionType.payment,
      source: TransactionSource.bank,
      rawMerchant: 'STARBUCKS',
      occurredAt: DateTime.utc(2026, 6, 16, 12, 0, 0),
      parseConfidence: 0.50,
    );
    final fakeParseResult = ParseResult.success(fakeParsed);
    const aiClient = _FixedResponseAiClient(AiParseResponse(
      amount: 150.0,
      currency: 'SAR',
      type: 'payment',
      merchantName: 'STARBUCKS',
      categoryKey: 'restaurants',
    ));

    TransactionEntity? saved;
    final capturingRepo = _CapturingTransactionRepo(onSave: (t) => saved = t);

    final useCase = AddTransactionUseCase(
      transactionRepository: capturingRepo,
      merchantCategoryRepository: _StubMerchantRepoWithKnownMerchant(),
      parserIsolate: _FakeParserIsolate(fakeParseResult),
      loadAiConsent: () async => true,
      aiClient: aiClient,
      dedupStore: _NoDedupStore(),
    );
    await useCase(rawMessage: rawSms);

    expect(saved, isNotNull);
    expect(saved!.status, TransactionStatus.confirmed);
    expect(saved!.source, TransactionSourceEntity.aiParsed);
  });

  test('AI other does not block Maps enrichment for a bank ATM location',
      () async {
    const rawSms =
        'Your Debit Card **5398 had a Successful transaction of EGP 200.00 '
        '@BDC OROBA,your available bal.EGP1204.74 for lost/stolen card call '
        '16607.';
    const fakeParsed = ParsedTransaction(
      amount: 200.0,
      currency: 'EGP',
      type: TransactionType.payment,
      source: TransactionSource.bank,
      rawMerchant: 'BDC OROBA',
      parseConfidence: 0.79,
    );
    final fakeParseResult = ParseResult.success(fakeParsed);
    const aiClient = _FixedResponseAiClient(AiParseResponse(
      amount: 200.0,
      currency: 'EGP',
      type: 'payment',
      merchantName: 'BDC OROBA',
      categoryKey: 'other',
    ));

    TransactionEntity? saved;
    String? savedCategory;
    final capturingRepo = _CapturingTransactionRepo(
      onSave: (t) => saved = t,
      onSaveCategory: (category) => savedCategory = category,
    );

    var mapsLookupCount = 0;
    final useCase = AddTransactionUseCase(
      transactionRepository: capturingRepo,
      merchantCategoryRepository: _StubMerchantRepo(),
      parserIsolate: _FakeParserIsolate(fakeParseResult),
      loadAiConsent: () async => true,
      aiClient: aiClient,
      dedupStore: _NoDedupStore(),
      resolveMerchantCategory: (merchant) async {
        mapsLookupCount++;
        expect(merchant, 'BDC OROBA');
        return 'cash';
      },
    );
    await useCase(rawMessage: rawSms, senderId: 'BDC');

    expect(mapsLookupCount, 1);
    expect(savedCategory, 'cash');
    expect(saved, isNotNull);
    expect(saved!.type, TransactionTypeEntity.withdrawal);
    expect(saved!.status, TransactionStatus.pending);
  });

  test('AI other sends merchant to Maps and saves the resolved category',
      () async {
    const rawSms = 'Purchase EGP 85.00 At STARBUCKS on 08/06 at 06:55 AM';
    const fakeParsed = ParsedTransaction(
      amount: 85.0,
      currency: 'EGP',
      type: TransactionType.payment,
      source: TransactionSource.bank,
      rawMerchant: 'STARBUCKS',
      parseConfidence: 0.79,
    );
    final fakeParseResult = ParseResult.success(fakeParsed);
    const aiClient = _FixedResponseAiClient(AiParseResponse(
      amount: 85.0,
      currency: 'EGP',
      type: 'payment',
      merchantName: 'STARBUCKS',
      categoryKey: 'other',
    ));

    String? savedCategory;
    var mapsLookupCount = 0;
    final useCase = AddTransactionUseCase(
      transactionRepository: _CapturingTransactionRepo(
        onSave: (_) {},
        onSaveCategory: (category) => savedCategory = category,
      ),
      merchantCategoryRepository: _StubMerchantRepo(),
      parserIsolate: _FakeParserIsolate(fakeParseResult),
      loadAiConsent: () async => true,
      aiClient: aiClient,
      dedupStore: _NoDedupStore(),
      resolveMerchantCategory: (merchant) async {
        mapsLookupCount++;
        expect(merchant, 'STARBUCKS');
        return 'cafes';
      },
    );

    final result = await useCase(rawMessage: rawSms, senderId: 'CIB');

    expect(result.outcome, AddTransactionOutcome.added);
    expect(mapsLookupCount, 1);
    expect(savedCategory, 'cafes');
  });

  test(
      'merchant payment falls back to a pending best-effort category when AI '
      'and Maps cannot classify it', () async {
    const rawSms = 'Purchase EGP 40.00 At RANDOM SHOP on 08/06 at 06:55 AM';
    const fakeParsed = ParsedTransaction(
      amount: 40.0,
      currency: 'EGP',
      type: TransactionType.payment,
      source: TransactionSource.bank,
      rawMerchant: 'RANDOM SHOP',
      parseConfidence: 0.79,
    );
    final fakeParseResult = ParseResult.success(fakeParsed);
    const aiClient = _FixedResponseAiClient(AiParseResponse(
      amount: 40.0,
      currency: 'EGP',
      type: 'payment',
      merchantName: 'RANDOM SHOP',
      categoryKey: 'other',
    ));

    String? savedCategory;
    final useCase = AddTransactionUseCase(
      transactionRepository: _CapturingTransactionRepo(
        onSave: (_) {},
        onSaveCategory: (category) => savedCategory = category,
      ),
      merchantCategoryRepository: _StubMerchantRepo(),
      parserIsolate: _FakeParserIsolate(fakeParseResult),
      loadAiConsent: () async => true,
      aiClient: aiClient,
      dedupStore: _NoDedupStore(),
      resolveMerchantCategory: (_) async => 'other',
    );

    final result = await useCase(rawMessage: rawSms, senderId: 'CIB');

    expect(result.outcome, AddTransactionOutcome.added);
    expect(savedCategory, 'shopping');
    expect(result.requiresConfirmation, isTrue);
  });

  test(
      'AI rescue: a bank-like message the parser dropped is recovered as '
      'a pending transaction', () async {
    const aiClient = _FixedResponseAiClient(AiParseResponse(
      amount: 75.0,
      currency: 'SAR',
      type: 'payment',
      merchantName: 'NOON',
      categoryKey: 'shopping',
    ));
    TransactionEntity? saved;
    final capturingRepo = _CapturingTransactionRepo(onSave: (t) => saved = t);

    final useCase = AddTransactionUseCase(
      transactionRepository: capturingRepo,
      merchantCategoryRepository: _StubMerchantRepo(),
      parserIsolate: _FakeParserIsolate(ParseResult.notTransaction()),
      loadAiConsent: () async => true,
      aiClient: aiClient,
      dedupStore: _NoDedupStore(),
    );

    final result = await useCase(
      rawMessage: 'مشترياتك بقيمة 75 ريال من نون تمت بنجاح',
      senderId: 'SABB',
    );

    expect(result.outcome, AddTransactionOutcome.added);
    expect(saved, isNotNull);
    expect(saved!.amount, 75.0);
    expect(saved!.status, TransactionStatus.pending);
    expect(saved!.source, TransactionSourceEntity.aiParsed);
  });

  test(
      'AI rescue: manual IPN transfer paste uses lazy install id and saves '
      'an incoming transfer as income', () async {
    const rawSms =
        'IPN transfer received with amount of EGP 10.00 on 1938 on 08/06 '
        'at 06:55 AM. Ref# db8a9b1e. For more details call 16607';
    String? seenInstallId;
    final aiClient = _CapturingAiClient(
      onParse: (sms, sender, installId) => seenInstallId = installId,
      response: const AiParseResponse(
        amount: 10.0,
        currency: 'EGP',
        type: 'income',
        categoryKey: 'transfers',
      ),
    );
    TransactionEntity? saved;
    final capturingRepo = _CapturingTransactionRepo(onSave: (t) => saved = t);

    final useCase = AddTransactionUseCase(
      transactionRepository: capturingRepo,
      merchantCategoryRepository: _StubMerchantRepo(),
      parserIsolate: _FakeParserIsolate(ParseResult.notTransaction()),
      loadAiConsent: () async => true,
      loadInstallId: () async => 'lazy-install-id',
      aiClient: aiClient,
      dedupStore: _NoDedupStore(),
    );

    final result = await useCase(rawMessage: rawSms);

    expect(result.outcome, AddTransactionOutcome.added);
    expect(seenInstallId, 'lazy-install-id');
    expect(saved, isNotNull);
    expect(saved!.amount, 10.0);
    expect(saved!.currency, 'EGP');
    // "transfer received" → money in → income.
    expect(saved!.type, TransactionTypeEntity.income);
    expect(saved!.status, TransactionStatus.pending);
    expect(saved!.source, TransactionSourceEntity.aiParsed);
  });

  test('AI rescue: without consent a dropped message stays notTransaction',
      () async {
    final countingClient = _CountingAiClient();
    final useCase = AddTransactionUseCase(
      transactionRepository: _StubTransactionRepo(),
      merchantCategoryRepository: _StubMerchantRepo(),
      parserIsolate: _FakeParserIsolate(ParseResult.notTransaction()),
      loadAiConsent: () async => false,
      aiClient: countingClient,
      dedupStore: _NoDedupStore(),
    );

    final result = await useCase(
      rawMessage: 'مشترياتك بقيمة 75 ريال من نون تمت بنجاح',
      senderId: 'SABB',
    );

    expect(result.outcome, AddTransactionOutcome.notTransaction);
    expect(countingClient.callCount, 0);
  });

  test('incoming external transfer counts as income (money received)',
      () async {
    final fakeParsed = ParsedTransaction(
      amount: 500.0,
      currency: 'SAR',
      type: TransactionType.transfer,
      source: TransactionSource.bank,
      occurredAt: DateTime.utc(2026, 6, 16, 12, 0, 0),
      parseConfidence: 0.95,
    );
    TransactionEntity? saved;
    final capturingRepo = _CapturingTransactionRepo(onSave: (t) => saved = t);
    final useCase = AddTransactionUseCase(
      transactionRepository: capturingRepo,
      merchantCategoryRepository: _StubMerchantRepo(),
      parserIsolate: _FakeParserIsolate(ParseResult.success(fakeParsed)),
      loadAiConsent: () async => false,
      dedupStore: _NoDedupStore(),
    );
    await useCase(rawMessage: 'حوالة واردة بمبلغ 500 ريال إلى حسابك');

    // Money received from outside is income (counts toward income totals).
    expect(saved, isNotNull);
    expect(saved!.type, TransactionTypeEntity.income);
  });

  test('foreign purchase + fee/tax line is saved as two transactions',
      () async {
    const rawSms = 'شراء إنترنت\n'
        'بطاقة:7640; urpay بطاقة;\n'
        'مبلغ:99 USD\n'
        'الرسوم/الضريبة:SAR 7.44\n'
        'من:APPLE.CO..\n'
        '24-6-2026 11:42';
    const fakeParsed = ParsedTransaction(
      amount: 99.0,
      currency: 'USD',
      type: TransactionType.payment,
      source: TransactionSource.card,
      rawMerchant: 'APPLE.CO',
      cardLast4: '7640',
      parseConfidence: 0.95,
    );
    final saves = <TransactionEntity>[];
    final useCase = AddTransactionUseCase(
      transactionRepository: _CapturingTransactionRepo(onSave: saves.add),
      merchantCategoryRepository: _StubMerchantRepo(),
      parserIsolate: _FakeParserIsolate(ParseResult.success(fakeParsed)),
      loadAiConsent: () async => false,
      dedupStore: _NoDedupStore(),
    );

    final result = await useCase(rawMessage: rawSms);

    // Main purchase (foreign currency).
    expect(result.outcome, AddTransactionOutcome.added);
    expect(result.transaction!.amount, 99.0);
    expect(result.transaction!.currency, 'USD');
    // Fee/tax surfaced as a separate transaction in the local currency.
    expect(result.secondary, isNotNull);
    expect(result.secondary!.outcome, AddTransactionOutcome.added);
    expect(result.secondary!.transaction!.amount, 7.44);
    expect(result.secondary!.transaction!.currency, 'SAR');
    expect(result.secondary!.transaction!.type, TransactionTypeEntity.payment);
    expect(saves.length, 2);
  });

  test(
      'foreign spend on a home-currency card is parked in the home account '
      'awaiting pricing (no USD account spawned)', () async {
    const fakeParsed = ParsedTransaction(
      amount: 99.0,
      currency: 'USD',
      type: TransactionType.payment,
      source: TransactionSource.card,
      rawMerchant: 'APPLE.CO',
      cardLast4: '7640',
      parseConfidence: 0.95,
    );
    TransactionEntity? saved;
    final useCase = AddTransactionUseCase(
      transactionRepository: _CapturingTransactionRepo(onSave: (t) => saved = t),
      merchantCategoryRepository: _StubMerchantRepo(),
      parserIsolate: _FakeParserIsolate(ParseResult.success(fakeParsed)),
      loadAiConsent: () async => false,
      dedupStore: _NoDedupStore(),
      accountRepository: _SingleAccountRepo(_homeAccount('SAR')),
    );

    await useCase(rawMessage: 'شراء إنترنت مبلغ:99 USD من:APPLE.CO');

    expect(saved, isNotNull);
    // Stored in the home (SAR) account, value awaiting the user's local amount.
    expect(saved!.currency, 'SAR');
    expect(saved!.accountId, 'home-acc');
    expect(saved!.amount, 0);
    expect(saved!.foreignAmount, 99.0);
    expect(saved!.foreignCurrency, 'USD');
    // Needs the user to price it → pending.
    expect(saved!.status, TransactionStatus.pending);
  });

  test('foreign purchase + fee processed twice does NOT double-count',
      () async {
    const fakeParsed = ParsedTransaction(
      amount: 99.0,
      currency: 'USD',
      type: TransactionType.payment,
      source: TransactionSource.card,
      rawMerchant: 'APPLE.CO',
      cardLast4: '7640',
      parseConfidence: 0.95,
    );
    const sms = 'شراء إنترنت\n'
        'بطاقة:7640; urpay بطاقة;\n'
        'مبلغ:99 USD\n'
        'الرسوم/الضريبة:SAR 7.44\n'
        'من:APPLE.CO..\n'
        '24-6-2026 11:42';
    final repo = _StoringTransactionRepo();
    final dedup = _MemoryDedupStore();
    AddTransactionUseCase build() => AddTransactionUseCase(
          transactionRepository: repo,
          merchantCategoryRepository: _StubMerchantRepo(),
          parserIsolate: _FakeParserIsolate(ParseResult.success(fakeParsed)),
          loadAiConsent: () async => false,
          dedupStore: dedup,
          accountRepository: _SingleAccountRepo(_homeAccount('SAR')),
        );

    await build()(rawMessage: sms);
    // One purchase (SAR 0, awaiting pricing) + one fee (SAR 7.44).
    expect(repo.saveCount, 2);

    final second = await build()(rawMessage: sms);
    // Re-processing the same SMS adds nothing.
    expect(repo.saveCount, 2);
    expect(second.outcome, AddTransactionOutcome.duplicate);

    final sarAmounts = repo.byId.values
        .where((t) => t.currency == 'SAR')
        .map((t) => t.amount)
        .toList()
      ..sort();
    expect(sarAmounts, [0.0, 7.44]);
  });

  test('internal own-account transfer stays neutral (excluded from totals)',
      () async {
    final fakeParsed = ParsedTransaction(
      amount: 500.0,
      currency: 'SAR',
      type: TransactionType.transfer,
      source: TransactionSource.bank,
      occurredAt: DateTime.utc(2026, 6, 16, 12, 0, 0),
      parseConfidence: 0.95,
    );
    TransactionEntity? saved;
    final capturingRepo = _CapturingTransactionRepo(onSave: (t) => saved = t);
    final useCase = AddTransactionUseCase(
      transactionRepository: capturingRepo,
      merchantCategoryRepository: _StubMerchantRepo(),
      parserIsolate: _FakeParserIsolate(ParseResult.success(fakeParsed)),
      loadAiConsent: () async => false,
      dedupStore: _NoDedupStore(),
    );
    await useCase(rawMessage: 'تحويل داخلي بمبلغ 500 ريال بين حساباتك');

    expect(saved, isNotNull);
    expect(saved!.type, TransactionTypeEntity.transfer);
  });

  test('ATM cash deposit (withdrawal-typed + إيداع wording) becomes a transfer',
      () async {
    final fakeParsed = ParsedTransaction(
      amount: 300.0,
      currency: 'SAR',
      type: TransactionType.withdrawal,
      source: TransactionSource.bank,
      occurredAt: DateTime.utc(2026, 6, 16, 12, 0, 0),
      parseConfidence: 0.95,
    );
    TransactionEntity? saved;
    final capturingRepo = _CapturingTransactionRepo(onSave: (t) => saved = t);
    final useCase = AddTransactionUseCase(
      transactionRepository: capturingRepo,
      merchantCategoryRepository: _StubMerchantRepo(),
      parserIsolate: _FakeParserIsolate(ParseResult.success(fakeParsed)),
      loadAiConsent: () async => false,
      dedupStore: _NoDedupStore(),
    );
    await useCase(rawMessage: 'إيداع نقدي بمبلغ 300 ريال في حسابك عبر الصراف');

    expect(saved, isNotNull);
    expect(saved!.type, TransactionTypeEntity.transfer);
  });

  test('outgoing external transfer counts as expense (money sent)', () async {
    final fakeParsed = ParsedTransaction(
      amount: 500.0,
      currency: 'SAR',
      type: TransactionType.transfer,
      source: TransactionSource.bank,
      occurredAt: DateTime.utc(2026, 6, 16, 12, 0, 0),
      parseConfidence: 0.95,
    );
    TransactionEntity? saved;
    final capturingRepo = _CapturingTransactionRepo(onSave: (t) => saved = t);
    final useCase = AddTransactionUseCase(
      transactionRepository: capturingRepo,
      merchantCategoryRepository: _StubMerchantRepo(),
      parserIsolate: _FakeParserIsolate(ParseResult.success(fakeParsed)),
      loadAiConsent: () async => false,
      dedupStore: _NoDedupStore(),
    );
    await useCase(rawMessage: 'تم تحويل 500 ريال إلى أحمد');

    // Money sent outside is an expense (payment type → counts in spend totals),
    // beneficiary name dropped for privacy.
    expect(saved, isNotNull);
    expect(saved!.type, TransactionTypeEntity.payment);
    expect(saved!.rawMerchant, isNull);
  });

  test('AI credit direction wins: incoming transfer is income, not expense',
      () async {
    // The wording alone is ambiguous (DirectionSignal can't tell), but the AI
    // says credit. The classified TYPE must agree with the stored direction so
    // the amount lands in income — never in the expense total with a green "+".
    const aiClient = _FixedResponseAiClient(AiParseResponse(
      amount: 750.0,
      currency: 'EGP',
      type: 'transfer',
      categoryKey: 'transfers',
      direction: 'credit',
    ));
    TransactionEntity? saved;
    final useCase = AddTransactionUseCase(
      transactionRepository: _CapturingTransactionRepo(onSave: (t) => saved = t),
      merchantCategoryRepository: _StubMerchantRepo(),
      parserIsolate: _FakeParserIsolate(ParseResult.notTransaction()),
      loadAiConsent: () async => true,
      aiClient: aiClient,
      dedupStore: _NoDedupStore(),
    );
    await useCase(rawMessage: 'تحويل 750 جنيه');

    expect(saved, isNotNull);
    expect(saved!.type, TransactionTypeEntity.income);
    expect(saved!.direction, TransactionDirectionEntity.credit);
  });

  test('direction contradiction forces pending even at high confidence',
      () async {
    // Text clearly says money came IN (إيداع/راتب) but the type was classified
    // as a payment (money out). Even with a 0.95 on-device confidence and a
    // known merchant, this must route to pending.
    const rawSms = 'تم إيداع راتب 5000.00 ريال في حسابك';
    final fakeParsed = ParsedTransaction(
      amount: 5000.0,
      currency: 'SAR',
      type: TransactionType.payment,
      source: TransactionSource.bank,
      rawMerchant: 'STARBUCKS',
      occurredAt: DateTime.utc(2026, 6, 16, 12, 0, 0),
      parseConfidence: 0.95,
    );
    final fakeParseResult = ParseResult.success(fakeParsed, bankKey: 'alrajhi');

    TransactionEntity? saved;
    final capturingRepo = _CapturingTransactionRepo(onSave: (t) => saved = t);

    final useCase = AddTransactionUseCase(
      transactionRepository: capturingRepo,
      merchantCategoryRepository: _StubMerchantRepoWithKnownMerchant(),
      parserIsolate: _FakeParserIsolate(fakeParseResult),
      // Consent off so the on-device parse (not AI) is what we are grounding.
      loadAiConsent: () async => false,
      dedupStore: _NoDedupStore(),
    );
    await useCase(rawMessage: rawSms);

    expect(saved, isNotNull);
    expect(saved!.status, TransactionStatus.pending);
  });
}
