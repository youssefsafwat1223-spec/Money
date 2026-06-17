import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/domain/entities/transaction_entity.dart';
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
  _CapturingTransactionRepo({required this.onSave});

  final void Function(TransactionEntity transaction) onSave;

  @override
  Future<TransactionEntity> saveTransaction({
    required TransactionEntity transaction,
    required String? categoryKey,
  }) async {
    onSave(transaction);
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
  _CapturingAiClient({required this.onParse});

  final void Function(String sanitizedSms, String senderId, String installId)
      onParse;

  @override
  Future<AiParseResponse?> parse({
    required String sanitizedSms,
    required String senderId,
    required String installId,
  }) async {
    onParse(sanitizedSms, senderId, installId);
    return null;
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

  test('clean Al Rajhi parse makes ZERO AI calls', () async {
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

    expect(countingClient.callCount, 0);
  });

  test('unsupported-bank generic pending parse makes ZERO AI calls', () async {
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

    expect(countingClient.callCount, 0);
    expect(savedTransaction, isNotNull);
    expect(savedTransaction!.amount, 50.00);
    expect(savedTransaction!.currency, 'AED');
    expect(savedTransaction!.rawMerchant, 'ABU DHABI NATIONAL OIL');
    expect(savedTransaction!.balanceAfter, 12956.50);
    expect(savedTransaction!.status, TransactionStatus.pending);
  });

  test('confirmed sender-bank mapping suppresses AI cascade', () async {
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

    expect(countingClient.callCount, 0);
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

  test(
      'AI fabricated amount not in source → transaction ignored (grounding fail)',
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

    final useCase = AddTransactionUseCase(
      transactionRepository: _StubTransactionRepo(),
      merchantCategoryRepository: _StubMerchantRepo(),
      parserIsolate: _FakeParserIsolate(fakeParseResult),
      loadAiConsent: () async => true,
      aiClient: lyingClient,
      dedupStore: _NoDedupStore(),
    );
    final result = await useCase(rawMessage: rawSms);

    expect(
      result.outcome,
      AddTransactionOutcome.notTransaction,
      reason: 'Grounding failure must discard the result entirely',
    );
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
}
