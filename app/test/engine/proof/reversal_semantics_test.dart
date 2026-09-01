/// Rev-7 scoped reversal semantics.
///
/// The Gemini Phase-5 run produced exactly one false auto-commit:
///
///     عكس عملية شراء بمبلغ 320.50 ريال لدى مطعم البيك     (gold: refund, incoming)
///
/// D1 voted OUTGOING on `شراء`, a catalog rule voted OUTGOING on `payment`, the
/// model agreed with both, and a refund was booked as a spend. The purchase verb
/// was still in the message — but it is the verb of the event being UNDONE, not
/// of the event being reported.
///
/// That was a DETERMINISTIC defect, not a model error: Sonnet proposed `incoming`
/// on the same row and was saved only by disagreeing with two wrong corroborators.
/// Being right by disagreement is not a safety property.
///
/// The fix must not be tuned to either model. These tests therefore exercise the
/// corroboration layer directly, with no proposal involved.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/engine/models/transaction_type.dart';
import 'package:money_companion/engine/parser/bank_profile.dart';
import 'package:money_companion/engine/parser/catalog_rule_matcher.dart';
import 'package:money_companion/engine/proof/direction_corroboration.dart';
import 'package:money_companion/engine/proof/evidence.dart';

List<DirectionCorroborator> corrobs(
  String sms, {
  BankProfile? bank,
  CatalogParserRule? rule,
}) =>
    deterministicCorroborators(
      sms: sms,
      evidence: extractEvidence(sms),
      bank: bank,
      catalogRule: rule,
    );

DirectionResolution resolve(String sms,
        {BankProfile? bank, CatalogParserRule? rule}) =>
    resolveDirection(corrobs(sms, bank: bank, rule: rule));

CatalogParserRule _debitRule() => const CatalogParserRule(
      id: 'r_debit',
      senderPattern: '.*',
      messagePattern: '.*',
      transactionType: 'debit',
      priority: 1,
      extractedFields: {'type': 'debit'},
    );

BankProfile _paymentBank() => const BankProfile(
      bankKey: 'testbank',
      displayName: 'Test',
      keywords: [],
      senderIds: [],
      currencyAliases: {},
      ignoreRules: [],
      typeRules: {
        TransactionType.payment: ['شراء'],
      },
      amountRules: [],
      balanceRules: [],
      feeRules: [],
      totalDueRules: [],
      merchantRules: [],
      dateRules: [],
    );

void main() {
  group('the Phase-5 false commit — required regressions', () {
    test('عكس عملية شراء → INCOMING, never outgoing', () {
      final r = resolve('عكس عملية شراء بمبلغ 320.50 ريال لدى مطعم البيك');
      expect(r.outcome, DirectionOutcome.corroborated);
      expect(r.polarity, DirectionCuePolarity.incoming);
    });

    test('عكس العملية ... شراء → INCOMING', () {
      expect(resolve('عكس العملية شراء بمبلغ 100.00 ر.س').polarity,
          DirectionCuePolarity.incoming);
    });

    test('عكس قيد → INCOMING', () {
      expect(resolve('عكس قيد خصم بمبلغ 848.760 د.ك').polarity,
          DirectionCuePolarity.incoming);
    });

    test('purchase reversed → INCOMING', () {
      expect(resolve('Purchase reversed AED 100.00').polarity,
          DirectionCuePolarity.incoming);
    });

    test('reversal of purchase → INCOMING', () {
      expect(resolve('Reversal of purchase AED 100.00').polarity,
          DirectionCuePolarity.incoming);
    });
  });

  group('exactly ONE effective authority, never two contradicting votes', () {
    test('the wrapped vote REPLACES the base vote', () {
      final c = corrobs('عكس عملية شراء بمبلغ 320.50 ريال');
      expect(c.every((x) => x.polarity == DirectionCuePolarity.incoming), isTrue,
          reason: 'no unwrapped OUTGOING vote may survive alongside the '
              'reversed one');
      expect(c.any((x) => x.provenance.contains('REVERSED')), isTrue);
    });

    test('D1 + D3 base-outgoing agreement becomes one INCOMING authority', () {
      // Reproduces the Phase-5 failure shape exactly: both sources would have
      // voted OUTGOING unwrapped.
      final r = resolve('عكس عملية شراء بمبلغ 320.50 ريال', rule: _debitRule());
      expect(r.outcome, DirectionOutcome.corroborated);
      expect(r.polarity, DirectionCuePolarity.incoming);
      final c = corrobs('عكس عملية شراء بمبلغ 320.50 ريال', rule: _debitRule());
      expect(c.where((x) => x.source == CorroborationSource.d3CatalogRule),
          isEmpty,
          reason: 'a whole-message catalog rule has no span, so its scope '
              'relative to the reversal cannot be proven — suppressed, not '
              'guessed');
    });

    test('D2 inside a reversal scope is inverted, with provenance', () {
      final c = corrobs('عكس عملية شراء بمبلغ 320.50 ريال',
          bank: _paymentBank());
      final d2 =
          c.where((x) => x.source == CorroborationSource.d2BankProfile).toList();
      expect(d2, isNotEmpty);
      expect(d2.first.polarity, DirectionCuePolarity.incoming);
      expect(d2.first.provenance, contains('REVERSED'));
    });
  });

  group('scope is conservative — a wrapper governs its own clause only', () {
    test('two clauses, only one reversed → conflict, not a silent choice', () {
      // Clause 1 reversed (incoming), clause 2 a plain purchase (outgoing).
      final r = resolve('عكس عملية شراء 100.00 ر.س\nشراء 50.00 ر.س');
      expect(r.outcome, DirectionOutcome.conflict,
          reason: 'the wrapper must not reach across the newline, and the two '
              'clauses genuinely disagree');
    });

    test('a reversal marker does not invert a distant unrelated cue', () {
      final c = corrobs('عكس عملية سابقة\nإيداع 500.00 ر.س');
      final deposit = c.where((x) => !x.provenance.contains('REVERSED'));
      expect(deposit.any((x) => x.polarity == DirectionCuePolarity.incoming),
          isTrue,
          reason: 'the deposit in the second clause keeps its own polarity');
    });

    test('a fee outside the reversed clause is unaffected', () {
      // Fees carry no direction polarity, so this must simply not crash or
      // manufacture a vote.
      final r = resolve('عكس عملية شراء 100.00 ر.س\nرسوم 5.00 ر.س');
      expect(r.polarity, DirectionCuePolarity.incoming);
    });
  });

  group('ambiguous tokens must NOT trigger reversal semantics', () {
    test('بالعكس has no reversal authority', () {
      final c = corrobs('تم تنفيذ العملية بالعكس. خصم 45.00 ر.س');
      expect(c.any((x) => x.provenance.contains('REVERSED')), isFalse);
    });

    test('عكسية has no reversal authority', () {
      final c = corrobs('حركة عكسية في السوق. شراء 45.00 ر.س');
      expect(c.any((x) => x.provenance.contains('REVERSED')), isFalse);
    });

    test('reversal must be a whole Latin word', () {
      final c = corrobs('irreversible charge USD 10.00');
      expect(c.any((x) => x.provenance.contains('REVERSED')), isFalse);
    });

    test('an ordinary purchase is untouched', () {
      expect(resolve('شراء بمبلغ 45.00 ر.س لدى مطعم').polarity,
          DirectionCuePolarity.outgoing);
    });
  });

  group('direction-neutral events are never blindly inverted', () {
    test('a reversed TRANSFER invents no polarity', () {
      // `تحويل` is direction-neutral, so there is nothing to invert. The
      // wrapper must not manufacture an incoming vote out of it.
      final r = resolve('عكس عملية تحويل 750.00 ر.س المرجع 99213');
      expect(r.outcome, DirectionOutcome.ambiguous,
          reason: 'no deterministic base polarity exists to reverse');
    });

    test('a bank rule for transfer stays silent under a wrapper', () {
      const transferBank = BankProfile(
        bankKey: 'tb',
        displayName: 'T',
        keywords: [],
        senderIds: [],
        currencyAliases: {},
        ignoreRules: [],
        typeRules: {
          TransactionType.transfer: ['تحويل'],
        },
        amountRules: [],
        balanceRules: [],
        feeRules: [],
        totalDueRules: [],
        merchantRules: [],
        dateRules: [],
      );
      final c = corrobs('عكس عملية تحويل 750.00 ر.س', bank: transferBank);
      expect(c.where((x) => x.source == CorroborationSource.d2BankProfile),
          isEmpty);
    });
  });
}
