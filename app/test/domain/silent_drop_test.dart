import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/domain/usecases/add_transaction_usecase.dart';
import 'package:money_companion/engine/ai/ai_parser_client.dart';
import 'package:money_companion/engine/ai/ai_sender_failure_tracker.dart';
import 'package:money_companion/engine/parser/parse_result.dart';

import 'local_v2_support.dart';

AddTransactionUseCase _useCase({
  required bool v2,
  CountingAiClient? ai,
  ParseResult? parse,
}) =>
    AddTransactionUseCase(
      transactionRepository: StoringTransactionRepo(),
      merchantCategoryRepository: NewMerchantRepo(),
      parserIsolate: FakeParserIsolate(parse),
      aiClient: ai,
      loadAiConsent: () async => true,
      dedupStore: MemoryDedupStore(),
      isLocalAutoConfirmV2: () => v2,
    );

// Letterless numeric short code: BankSenderFilter.isLikelyBank is false.
const _shortCode = '19623';
// The parser reads an amount but the reading is below the confidence floor, so
// local produces no transaction.
const _shaped = 'Amount SAR 120.00';

void main() {
  setUp(() => AiSenderFailureTracker.instance.resetForTest());

  test('numeric short code with an amount, AI off => dropped (Smart Inbox)',
      () async {
    final r = await _useCase(v2: true, ai: null)(
        rawMessage: _shaped, senderId: _shortCode);
    expect(r.outcome, AddTransactionOutcome.notTransaction);
    expect(r.droppedByParser, isTrue);
  });

  test('V2-invalid local parse from a short code => dropped', () async {
    // No currency token: the parse is a transaction but currencyDefaulted.
    final r = await _useCase(v2: true)(
        rawMessage: 'Purchase 42.00 At STARBUCKS', senderId: _shortCode);
    expect(r.outcome, AddTransactionOutcome.notTransaction);
    expect(r.droppedByParser, isTrue);
  });

  test('AI candidate rejected by the validator => dropped', () async {
    final ai = CountingAiClient(const AiParseResponse(
        amount: 999, amountText: '999.00', currency: 'SAR', type: 'payment'));
    final r = await _useCase(v2: true, ai: ai)(
        rawMessage: 'hello nothing here', senderId: _shortCode);
    expect(ai.callCount, 1);
    expect(r.outcome, AddTransactionOutcome.notTransaction);
    expect(r.droppedByParser, isTrue);
  });

  test('OTP from a short code stays ignored', () async {
    final r = await _useCase(v2: true)(
        rawMessage: 'Your OTP is 123456. Do not share it. SAR 50.00',
        senderId: _shortCode);
    expect(r.outcome, AddTransactionOutcome.notTransaction);
    expect(r.droppedByParser, isFalse);
  });

  test('non-transaction chatter from a short code stays ignored', () async {
    final r = await _useCase(v2: true)(
        rawMessage: 'see you at 5', senderId: _shortCode);
    expect(r.droppedByParser, isFalse);
  });
}
