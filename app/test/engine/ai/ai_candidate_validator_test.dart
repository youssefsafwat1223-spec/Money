import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/engine/ai/ai_candidate_validator.dart';
import 'package:money_companion/engine/ai/ai_parser_client.dart';
import 'package:money_companion/engine/ai/grounding_check.dart';
import 'package:money_companion/engine/models/parsed_transaction.dart';
import 'package:money_companion/engine/models/transaction_source.dart';
import 'package:money_companion/engine/models/transaction_type.dart';

final _ref = DateTime.utc(2026, 6, 16, 12);
const _validator = AiCandidateValidator();

ParsedTransaction _local({
  double amount = 1250,
  String currency = 'EGP',
  String? merchant = 'LOCAL SHOP',
  DateTime? at,
}) =>
    ParsedTransaction(
      amountText: '$amount',
      amount: amount,
      currency: currency,
      type: TransactionType.payment,
      source: TransactionSource.bank,
      rawMerchant: merchant,
      occurredAt: at,
      parseConfidence: 0.6,
    );

// Fills the exact `amountText` the validator now requires, so each case below
// keeps testing the one rule it names.
AiParseResponse _withText(AiParseResponse r) => r.amountText != null
    ? r
    : AiParseResponse(
        amount: r.amount,
        amountText: r.amount == r.amount.roundToDouble()
            ? r.amount.toInt().toString()
            : r.amount.toString(),
        currency: r.currency,
        merchantName: r.merchantName,
        type: r.type,
        categoryKey: r.categoryKey,
        direction: r.direction,
        occurredAt: r.occurredAt,
        modelUsed: r.modelUsed,
      );

AiCandidateValidation _run(
  AiParseResponse r,
  String text, {
  ParsedTransaction? local,
  String? messageText,
  TransactionType? type,
}) =>
    _validator.validate(
      response: _withText(r),
      sanitizedText: text,
      localParsed: local,
      referenceTime: _ref,
      messageText: messageText,
      normalizedType: type,
    );

void main() {
  group('GroundingCheck thousands separators', () {
    test('accepts grouped western and Arabic-Indic forms', () {
      for (final text in [
        'Amount 1,250.00 EGP',
        'Amount 1,250 EGP',
        'المبلغ ١٬٢٥٠٫٠٠',
        'المبلغ ١,٢٥٠',
        'Amount 1250.00',
      ]) {
        expect(GroundingCheck.verify(amount: 1250, sanitizedText: text),
            isTrue,
            reason: text);
      }
    });

    test('rejects an amount that is not in the text', () {
      expect(
          GroundingCheck.verify(amount: 1250, sanitizedText: 'Amount 999 EGP'),
          isFalse);
    });
  });

  group('AiCandidateValidator', () {
    test('ungrounded amount is rejected', () {
      final v = _run(const AiParseResponse(amount: 77, currency: 'EGP'),
          'paid EGP 1,250.00');
      expect(v.accepted, isFalse);
    });

    test('grounded thousands amount with grounded currency is accepted', () {
      final v = _run(const AiParseResponse(amount: 1250, currency: 'EGP'),
          'paid EGP 1,250.00');
      expect(v.accepted, isTrue);
      expect(v.currency, 'EGP');
    });

    test('currency mismatch with local is rejected', () {
      final v = _run(const AiParseResponse(amount: 1250, currency: 'USD'),
          'paid EGP 1,250.00',
          local: _local());
      expect(v.accepted, isFalse);
    });

    test('amount mismatch with local is rejected', () {
      final v = _run(const AiParseResponse(amount: 1250, currency: 'EGP'),
          'paid EGP 1,250.00 and 900',
          local: _local(amount: 900));
      expect(v.accepted, isFalse);
    });

    test('ungrounded currency without local is rejected', () {
      final v = _run(const AiParseResponse(amount: 1250, currency: 'USD'),
          'paid EGP 1,250.00');
      expect(v.accepted, isFalse);
    });

    test('alias-grounded currency without local is accepted', () {
      final v = _run(const AiParseResponse(amount: 1250, currency: 'EGP'),
          'تم خصم 1,250 ج.م من حسابك');
      expect(v.accepted, isTrue);
      final sar = _run(const AiParseResponse(amount: 50, currency: 'SAR'),
          'خصم 50 ريال');
      expect(sar.accepted, isTrue);
      final jod = _run(const AiParseResponse(amount: 50, currency: 'JOD'),
          'خصم 50 دينار أردني');
      expect(jod.accepted, isTrue);
    });

    test('merchant absent from text falls back to local', () {
      final v = _run(
          const AiParseResponse(
              amount: 1250, currency: 'EGP', merchantName: 'INVENTED CAFE'),
          'paid EGP 1,250.00 at Local Shop',
          local: _local());
      expect(v.merchantName, 'LOCAL SHOP');
      final none = _run(
          const AiParseResponse(
              amount: 1250, currency: 'EGP', merchantName: 'INVENTED CAFE'),
          'paid EGP 1,250.00');
      expect(none.merchantName, isNull);
    });

    test('grounded merchant is kept (case/whitespace insensitive)', () {
      final v = _run(
          const AiParseResponse(
              amount: 1250, currency: 'EGP', merchantName: 'Local   Shop'),
          'paid EGP 1,250.00 at LOCAL SHOP');
      expect(v.merchantName, 'Local   Shop');
    });

    test('date outside the window is dropped, inside is kept', () {
      const text = 'paid EGP 1,250.00';
      final localAt = DateTime.utc(2026, 6, 15);
      final old = _run(
          AiParseResponse(
              amount: 1250,
              currency: 'EGP',
              occurredAt: _ref.subtract(const Duration(days: 40))),
          text,
          local: _local(at: localAt));
      expect(old.occurredAt, localAt);
      final future = _run(
          AiParseResponse(
              amount: 1250,
              currency: 'EGP',
              occurredAt: _ref.add(const Duration(days: 3))),
          text);
      expect(future.occurredAt, isNull);
      final ok = _ref.subtract(const Duration(days: 5));
      final good = _run(
          AiParseResponse(amount: 1250, currency: 'EGP', occurredAt: ok),
          text);
      expect(good.occurredAt, ok);
    });

    test('missing amountText is rejected', () {
      final v = _validator.validate(
        response: const AiParseResponse(amount: 1250, currency: 'EGP'),
        sanitizedText: 'paid EGP 1,250.00',
        localParsed: null,
        referenceTime: _ref,
      );
      expect(v.accepted, isFalse);
      expect(v.rejectionReason, 'amount_text_missing');
    });

    test('non-canonical amountText is rejected', () {
      for (final bad in ['12,50', '1250.005', 'abc', '']) {
        final v = _validator.validate(
          response: AiParseResponse(
              amount: 1250, amountText: bad, currency: 'EGP'),
          sanitizedText: 'paid EGP 1,250.00',
          localParsed: null,
          referenceTime: _ref,
        );
        expect(v.accepted, isFalse, reason: bad);
        expect(v.rejectionReason, 'amount_text_not_canonical', reason: bad);
      }
    });

    test('type contradicting the message direction is rejected', () {
      final v = _run(const AiParseResponse(amount: 1250, currency: 'EGP'),
          'received EGP 1,250.00 from Ali',
          messageText: 'received EGP 1,250.00 from Ali',
          type: TransactionType.payment);
      expect(v.accepted, isFalse);
      expect(v.rejectionReason, 'direction_contradiction');
      final ok = _run(const AiParseResponse(amount: 1250, currency: 'EGP'),
          'received EGP 1,250.00 from Ali',
          messageText: 'received EGP 1,250.00 from Ali',
          type: TransactionType.income);
      expect(ok.accepted, isTrue);
    });

    test('outcome never depends on provider-supplied metadata fields', () {
      const text = 'paid EGP 1,250.00 at Local Shop';
      AiCandidateValidation run(String? type, String? cat, String? dir,
              String? model) =>
          _run(
              AiParseResponse(
                amount: 1250,
                currency: 'EGP',
                merchantName: 'Local Shop',
                type: type,
                categoryKey: cat,
                direction: dir,
                modelUsed: model,
              ),
              text,
              local: _local());
      final base = run(null, null, null, null);
      for (final v in [
        run('payment', 'food', 'debit', 'gpt-x'),
        run('income', 'other', 'credit', 'confidence=0.99'),
        run('transfer', 'transfers', 'debit', 'confidence=0.01'),
      ]) {
        expect(v.accepted, base.accepted);
        expect(v.currency, base.currency);
        expect(v.merchantName, base.merchantName);
        expect(v.occurredAt, base.occurredAt);
      }
    });
  });
}
