import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/domain/capture/proof_proposal_builder.dart';
import 'package:money_companion/engine/models/transaction_type.dart';
import 'package:money_companion/engine/proof/evidence.dart';
import 'package:money_companion/engine/proof/proof_checker.dart';

/// The mapper from a deterministic parse to a Proof proposal.
///
/// A wrong mapping is worse than not running Proof: it produces confident
/// agreement about the wrong token, and the shadow measurement that gates
/// activation would be measuring noise. So it refuses on any ambiguity.
void main() {
  const b = ProofProposalBuilder();

  group('matching is by VALUE, not spelling', () {
    // The original defect: canonicalAmount() emits fixed width while
    // Evidence.canonical preserves the token AS WRITTEN, so `1.2` in a message
    // never matched a builder-produced `1.20` and the capture silently refused
    // to propose. Value equality is the contract.
    test('the same money written differently all resolves to one value', () {
      for (final spelling in ['1.2', '1.20', '01.200', '1.200']) {
        expect(ProofProposalBuilder.minorFromCanonical(spelling, 2), 120,
            reason: 'spelling "$spelling" is 120 minor units at scale 2');
      }
    });

    test('excess precision is accepted ONLY when it is all zeros', () {
      expect(ProofProposalBuilder.minorFromCanonical('500.00', 0), 500);
      // 1.235 at scale 2 must match NOTHING rather than round into agreement
      // with 1.24 — rounding here would manufacture a false corroboration.
      expect(ProofProposalBuilder.minorFromCanonical('1.235', 2), isNull);
    });

    test('scale 3 keeps every digit', () {
      expect(ProofProposalBuilder.minorFromCanonical('45.750', 3), 45750);
      expect(ProofProposalBuilder.minorFromCanonical('45.75', 3), 45750);
    });

    test('signs and malformed tokens are refused', () {
      for (final bad in ['-19.99', '', '1.2.3', 'abc', '1,000']) {
        expect(ProofProposalBuilder.minorFromCanonical(bad, 2), isNull,
            reason: bad);
      }
    });

    test('a written amount resolves end to end', () {
      // The regression case: an amount written WITHOUT full scale.
      final ev = extractEvidence('تم خصم 1.2 ر.س لدى ستاربكس');
      final out = b.build(
          evidence: ev,
          type: TransactionType.payment,
          amountMinorUnits: 120,
          currencyIso: 'SAR');
      expect(out.proposal, isNotNull,
          reason: '1.2 SAR is 120 minor units and must propose');
    });
  });

  group('canonicalAmount is for REPORTING only', () {
    test('scale 2', () => expect(ProofProposalBuilder.canonicalAmount(12575, 2), '125.75'));
    test('scale 3', () => expect(ProofProposalBuilder.canonicalAmount(45750, 3), '45.750'));
    test('scale 0', () => expect(ProofProposalBuilder.canonicalAmount(500, 0), '500'));
    test('sub-unit pads', () => expect(ProofProposalBuilder.canonicalAmount(5, 2), '0.05'));
  });

  group('direction vocabulary is the CHECKER\'s, not the enum\'s', () {
    test('expense families are outgoing', () {
      for (final t in [
        TransactionType.payment,
        TransactionType.withdrawal,
        TransactionType.creditCardPayment,
        TransactionType.governmentPayment,
      ]) {
        expect(ProofProposalBuilder.directionFor(t), 'outgoing', reason: '$t');
      }
    });
    test('income and refund are incoming', () {
      expect(ProofProposalBuilder.directionFor(TransactionType.income), 'incoming');
      expect(ProofProposalBuilder.directionFor(TransactionType.refund), 'incoming');
    });
    test('transfer and unknown REFUSE rather than guess', () {
      // A transfer's direction depends on which side the message describes.
      expect(ProofProposalBuilder.directionFor(TransactionType.transfer), isNull);
      expect(ProofProposalBuilder.directionFor(TransactionType.unknown), isNull);
    });
  });

  group('build resolves node ids, never literals', () {
    test('a clean purchase maps to the right nodes and proves', () {
      final ev = extractEvidence('تم خصم 125.75 ر.س لدى ستاربكس');
      final out = b.build(
          evidence: ev,
          type: TransactionType.payment,
          amountMinorUnits: 12575,
          currencyIso: 'SAR');
      expect(out.refusal, isNull);
      final p = out.proposal;
      expect(p, isNotNull);
      // The contract the checker enforces: ids, not digits.
      expect(p!.amountId, startsWith('NUMBER_'));
      expect(p.currencyId, startsWith('CURRENCY_'));
      final r = const ProofChecker().check(ev, p);
      expect(r.verdict, ProofVerdict.proven, reason: '${r.reasons}');
      expect(r.amountText, '125.75');
      expect(r.currency, 'SAR');
    });

    test('REFUSES when the parsed amount is absent from the message', () {
      final ev = extractEvidence('تم خصم 125.75 ر.س لدى ستاربكس');
      expect(
          b.build(
              evidence: ev,
              type: TransactionType.payment,
              amountMinorUnits: 999, // 9.99 — no such token
              currencyIso: 'SAR').proposal,
          isNull);
    });

    test('REFUSES when two nodes carry the same VALUE (one currency token)', () {
      // The first version of this test used a message with TWO currency tokens,
      // so the builder refused at the currency check and never reached the
      // amount-ambiguity branch — it passed for the wrong reason. This message
      // has exactly one currency token, so the refusal it proves is the
      // amount-ambiguity one.
      final ev = extractEvidence('خصم 50.00 والرصيد 50.00 ر.س');
      final cur = ev.items
          .where((e) => e.evidenceClass == EvidenceClass.currency)
          .length;
      expect(cur, 1, reason: 'fixture must isolate AMOUNT ambiguity');
      expect(
          b.build(
              evidence: ev,
              type: TransactionType.payment,
              amountMinorUnits: 5000,
              currencyIso: 'SAR').proposal,
          isNull);
    });

    test('REFUSES when the message names TWO currencies', () {
      // An amount cannot be unambiguously paired with a currency here, and a
      // confident mispairing is what would corrupt the shadow measurement.
      final ev = extractEvidence('خصم 50.00 ر.س ورصيد 20.00 د.ك');
      expect(
          b.build(
              evidence: ev,
              type: TransactionType.payment,
              amountMinorUnits: 5000,
              currencyIso: 'SAR').proposal,
          isNull);
    });

    test('REFUSES a negative amount — evidence carries no signs', () {
      final ev = extractEvidence('تم خصم 125.75 ر.س لدى ستاربكس');
      expect(
          b.build(
              evidence: ev,
              type: TransactionType.payment,
              amountMinorUnits: -12575,
              currencyIso: 'SAR').proposal,
          isNull);
    });

    test('REFUSES when the currency is absent', () {
      final ev = extractEvidence('تم خصم 125.75 لدى ستاربكس');
      expect(
          b.build(
              evidence: ev,
              type: TransactionType.payment,
              amountMinorUnits: 12575,
              currencyIso: 'SAR').proposal,
          isNull);
    });

    test('REFUSES a transfer outright', () {
      final ev = extractEvidence('تم خصم 125.75 ر.س لدى ستاربكس');
      expect(
          b.build(
              evidence: ev,
              type: TransactionType.transfer,
              amountMinorUnits: 12575,
              currencyIso: 'SAR').proposal,
          isNull);
    });
  });

  group('every refusal names its reason — the Tier 2 diagnostic contract', () {
    // Without a reason per refusal, the ~53% refusal rate is an opaque
    // denominator loss during Tier 2, indistinguishable from "Proof is broken".
    ProofProposalRefusal? why(String sms, TransactionType t, int minor, String iso) =>
        b
            .build(
                evidence: extractEvidence(sms),
                type: t,
                amountMinorUnits: minor,
                currencyIso: iso)
            .refusal;

    test('directionNotDerivable', () {
      expect(why('تم خصم 125.75 ر.س', TransactionType.transfer, 12575, 'SAR'),
          ProofProposalRefusal.directionNotDerivable);
    });
    test('negativeAmount', () {
      expect(why('تم خصم 125.75 ر.س', TransactionType.payment, -12575, 'SAR'),
          ProofProposalRefusal.negativeAmount);
    });
    test('noCurrencyToken', () {
      expect(why('تم خصم 125.75 لدى ستاربكس', TransactionType.payment, 12575, 'SAR'),
          ProofProposalRefusal.noCurrencyToken);
    });
    test('multipleCurrencyTokens', () {
      expect(why('خصم 50.00 ر.س ورصيد 20.00 د.ك', TransactionType.payment, 5000, 'SAR'),
          ProofProposalRefusal.multipleCurrencyTokens);
    });
    test('amountNotFound', () {
      expect(why('تم خصم 125.75 ر.س', TransactionType.payment, 999, 'SAR'),
          ProofProposalRefusal.amountNotFound);
    });
    test('amountAmbiguous', () {
      expect(why('خصم 50.00 والرصيد 50.00 ر.س', TransactionType.payment, 5000, 'SAR'),
          ProofProposalRefusal.amountAmbiguous);
    });
    test('currencyMismatch', () {
      // The message's single currency is not the one the parser concluded.
      expect(why('تم خصم 125.75 ر.س', TransactionType.payment, 12575, 'KWD'),
          ProofProposalRefusal.currencyMismatch);
    });

    test('currencyScaleMissing is UNREACHABLE from real extraction', () {
      // Recorded honestly rather than left as a test that cannot be written:
      // extractEvidence only emits currency nodes from the supported-currency
      // registry, and every entry there carries a scale. The branch is
      // defence-in-depth against a hand-built EvidenceSet, so no realistic
      // message can reach it. If a scale-less currency is ever added, THIS test
      // is the note explaining why the branch exists.
      final ev = extractEvidence('تم خصم 125.75 ر.س');
      final currencyNodes =
          ev.items.where((e) => e.evidenceClass == EvidenceClass.currency);
      expect(currencyNodes, isNotEmpty);
      for (final n in currencyNodes) {
        expect(n.scale, isNotNull,
            reason: 'real extraction always carries a scale');
      }
    });

    test('a successful proposal carries NO refusal', () {
      expect(why('تم خصم 125.75 ر.س لدى ستاربكس', TransactionType.payment, 12575, 'SAR'),
          isNull);
    });
  });
}
