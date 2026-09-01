/// Rev-4 direction corroboration — D1/D2/D3, conflicts, and the exclusions.
///
/// The rev-2 baseline auto-committed nine credit-card repayments as INCOMING
/// against gold OUTGOING because the checker accepted a confident model with no
/// deterministic source agreeing. These tests fix each way that can happen.
///
/// The exclusion tests matter as much as the positive ones: a corroboration
/// layer that accepts `transfer` as evidence of direction, or lets the model's
/// own type vouch for the model's own direction, is not corroboration at all.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/engine/models/transaction_type.dart';
import 'package:money_companion/engine/parser/bank_profile.dart';
import 'package:money_companion/engine/parser/catalog_rule_matcher.dart';
import 'package:money_companion/engine/proof/direction_corroboration.dart';
import 'package:money_companion/engine/proof/evidence.dart';
import 'package:money_companion/engine/proof/proof_checker.dart';

BankProfile _bank({
  required String key,
  required Map<TransactionType, List<String>> typeRules,
}) =>
    BankProfile(
      bankKey: key,
      displayName: key,
      keywords: const [],
      senderIds: const [],
      currencyAliases: const {},
      ignoreRules: const [],
      typeRules: typeRules,
      amountRules: const [],
      balanceRules: const [],
      feeRules: const [],
      totalDueRules: const [],
      merchantRules: const [],
      dateRules: const [],
    );

CatalogParserRule _rule({
  required String id,
  required String transactionType,
  Map<String, Object?> extractedFields = const {},
}) =>
    CatalogParserRule(
      id: id,
      senderPattern: '.*',
      messagePattern: '.*',
      transactionType: transactionType,
      priority: 1,
      extractedFields: extractedFields,
    );

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

void main() {
  group('D1 — explicit lexical polarity', () {
    test('a debit word corroborates outgoing', () {
      final r = resolveDirection(corrobs('شراء بمبلغ 45.00 ر.س'));
      expect(r.outcome, DirectionOutcome.corroborated);
      expect(r.polarity, DirectionCuePolarity.outgoing);
    });

    test('a credit word corroborates incoming', () {
      final r = resolveDirection(corrobs('تم إيداع مبلغ 5,000.00 ر.س'));
      expect(r.outcome, DirectionOutcome.corroborated);
      expect(r.polarity, DirectionCuePolarity.incoming);
    });

    test('no cue at all is ambiguous, never a guess', () {
      final r = resolveDirection(corrobs('مبلغ: 197.07 AED\nبطاقة: XX1131'));
      expect(r.outcome, DirectionOutcome.ambiguous);
      expect(r.polarity, isNull);
    });
  });

  group('D2 — bank-profile corroboration', () {
    final withdrawalBank = _bank(
      key: 'testbank',
      typeRules: {
        TransactionType.withdrawal: ['atm'],
      },
    );

    test('a withdrawal rule corroborates outgoing with no lexical cue', () {
      // The message carries no D1 word; only the bank profile knows.
      final c = corrobs('ATM XX7781 SAR 400.00', bank: withdrawalBank);
      expect(c.any((x) => x.source == CorroborationSource.d2BankProfile), isTrue);
      expect(resolveDirection(c).polarity, DirectionCuePolarity.outgoing);
    });

    test('the corroborator names the bank and the rule that fired', () {
      final c = corrobs('ATM XX7781 SAR 400.00', bank: withdrawalBank);
      final d2 =
          c.firstWhere((x) => x.source == CorroborationSource.d2BankProfile);
      expect(d2.provenance, contains('testbank'));
      expect(d2.provenance, contains('withdrawal'));
      expect(d2.provenance, contains('atm'));
    });

    test('a rule that does not match the message contributes nothing', () {
      expect(corrobs('POS SAR 12.00', bank: withdrawalBank), isEmpty);
    });

    test('TRANSFER is direction-neutral and may never corroborate', () {
      final transferBank = _bank(
        key: 'tb',
        typeRules: {
          TransactionType.transfer: ['تحويل', 'transfer'],
        },
      );
      final c = corrobs('تحويل 750.00 ر.س المرجع 99213', bank: transferBank);
      expect(c.where((x) => x.source == CorroborationSource.d2BankProfile),
          isEmpty);
      expect(resolveDirection(c).outcome, DirectionOutcome.ambiguous);
    });

    test('creditCardPayment may not corroborate either', () {
      final ccBank = _bank(
        key: 'cc',
        typeRules: {
          TransactionType.creditCardPayment: ['سداد'],
        },
      );
      final c = corrobs('تأكيد السداد مبلغ: 197.07 AED', bank: ccBank);
      expect(c, isEmpty);
    });

    test('unknown carries no polarity to map', () {
      final u = _bank(key: 'u', typeRules: {
        TransactionType.unknown: ['xyz'],
      });
      expect(corrobs('xyz SAR 10.00', bank: u), isEmpty);
    });
  });

  group('D3 — catalog-rule corroboration', () {
    test('an explicit debit literal corroborates outgoing', () {
      final c = corrobs('PURCHASE;SAR 75.25',
          rule: _rule(
              id: 'r7',
              transactionType: 'unknown',
              extractedFields: {'type': 'debit'}));
      expect(resolveDirection(c).polarity, DirectionCuePolarity.outgoing);
      final d3 =
          c.firstWhere((x) => x.source == CorroborationSource.d3CatalogRule);
      expect(d3.provenance, contains('r7'));
      expect(d3.provenance, contains('debit'));
    });

    test('an explicit credit literal corroborates incoming', () {
      final c = corrobs('CREDIT;EGP 900.00',
          rule: _rule(
              id: 'r8',
              transactionType: 'unknown',
              extractedFields: {'type': 'credit'}));
      expect(resolveDirection(c).polarity, DirectionCuePolarity.incoming);
    });

    test('the literal type wins over the coarser column', () {
      final c = corrobs('X SAR 10.00',
          rule: _rule(
              id: 'r9',
              transactionType: 'transfer',
              extractedFields: {'type': 'debit'}));
      expect(resolveDirection(c).polarity, DirectionCuePolarity.outgoing);
    });

    test('a transfer catalog rule may not corroborate', () {
      final c = corrobs('X SAR 10.00',
          rule: _rule(id: 'r10', transactionType: 'transfer'));
      expect(c.where((x) => x.source == CorroborationSource.d3CatalogRule),
          isEmpty);
    });
  });

  group('agreement and conflict', () {
    final posBank = _bank(key: 'pb', typeRules: {
      TransactionType.payment: ['pos'],
    });

    test('D1 + D2 agreeing still corroborates once', () {
      final c = corrobs('POS شراء SAR 120.00', bank: posBank);
      expect(c.length, greaterThanOrEqualTo(2));
      expect(resolveDirection(c).outcome, DirectionOutcome.corroborated);
    });

    test('D1 + D3 agreeing corroborates', () {
      final c = corrobs('شراء SAR 30.00',
          rule: _rule(
              id: 'r1',
              transactionType: 'purchase',
              extractedFields: {'type': 'debit'}));
      expect(resolveDirection(c).outcome, DirectionOutcome.corroborated);
    });

    test('D1 against D2 is a CONFLICT, never a majority vote', () {
      // Lexical says money in; the bank profile says purchase.
      final c = corrobs('تم إيداع POS SAR 60.00', bank: posBank);
      expect(resolveDirection(c).outcome, DirectionOutcome.conflict);
    });

    test('D2 against D3 is a conflict', () {
      final c = corrobs('POS SAR 60.00',
          bank: posBank,
          rule: _rule(
              id: 'r2',
              transactionType: 'x',
              extractedFields: {'type': 'credit'}));
      expect(resolveDirection(c).outcome, DirectionOutcome.conflict);
    });

    test('two opposing lexical cues conflict', () {
      expect(resolveDirection(corrobs('تم إيداع مبلغ 300.00 ر.س ثم خصم')).outcome,
          DirectionOutcome.conflict);
    });
  });

  group('the circularity ban — the model may not vouch for itself', () {
    test('a confident proposal with nothing agreeing does not prove', () {
      const sms = 'بطاقة إئتمانية: تأكيد السداد\nمبلغ: 197.07 AED';
      final ev = extractEvidence(sms);
      final amountId =
          ev.ofClass(EvidenceClass.number).firstWhere((n) => n.text == '197.07').id;
      final currencyId = ev.ofClass(EvidenceClass.currency).first.id;
      final r = const ProofChecker().check(
        ev,
        ProofProposal(
          isTransaction: 'transaction',
          state: 'completed',
          direction: 'incoming', // the rev-2 failure, verbatim
          type: TransactionType.payment,
          amountId: amountId,
          currencyId: currencyId,
        ),
      );
      expect(r.isProven, isFalse);
      expect(r.reasons, contains(ProofReason.directionAmbiguous));
    });

    test('the AI type is not consulted as a corroborator', () {
      // Same message, same absent evidence; only the proposed TYPE changes.
      // If type were leaking into corroboration, these would differ.
      const sms = 'مبلغ: 88.50 ر.س\nبطاقة: XX2211';
      final ev = extractEvidence(sms);
      final amountId =
          ev.ofClass(EvidenceClass.number).firstWhere((n) => n.text == '88.50').id;
      final currencyId = ev.ofClass(EvidenceClass.currency).first.id;

      ProofResult run(TransactionType t) => const ProofChecker().check(
            ev,
            ProofProposal(
              isTransaction: 'transaction',
              state: 'completed',
              direction: 'outgoing',
              type: t,
              amountId: amountId,
              currencyId: currencyId,
            ),
          );

      expect(run(TransactionType.payment).reasons,
          contains(ProofReason.directionAmbiguous));
      expect(run(TransactionType.income).reasons,
          contains(ProofReason.directionAmbiguous));
    });
  });
}
