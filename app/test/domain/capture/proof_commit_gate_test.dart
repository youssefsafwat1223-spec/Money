import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/domain/capture/proof_commit_gate.dart';
import 'package:money_companion/domain/capture/proof_proposal_builder.dart';
import 'package:money_companion/domain/usecases/capture_commit_decision.dart';
import 'package:money_companion/domain/entities/transaction_entity.dart';
import 'package:money_companion/engine/models/transaction_type.dart';
import 'package:money_companion/engine/proof/evidence.dart';
import 'package:money_companion/engine/proof/proof_checker.dart';

/// PHASE 11 safety contract.
///
/// The single property everything else rests on: **Proof can withhold a
/// confirmation, never grant one.** These tests are written to fail loudly if
/// that ever stops being true, because it is what makes activation safe.
void main() {
  const gate = ProofCommitGate();
  const builder = ProofProposalBuilder();

  ProofResult proofOf(String sms, TransactionType type, int minor, String iso) {
    final ev = extractEvidence(sms);
    final p = builder
        .build(
            evidence: ev,
            type: type,
            amountMinorUnits: minor,
            currencyIso: iso)
        .proposal!;
    return const ProofChecker().check(ev, p);
  }

  group('INVARIANT: the gate is subtractive', () {
    test('armed Proof can NEVER turn pending into confirmed', () {
      // The whole safety argument. Every non-confirming deterministic path,
      // crossed with an agreeing gate, must still be pending.
      for (final agreeing in [true, false]) {
        final g = ProofGateDecision(
          mode: ProofGateMode.armed,
          outcome: agreeing
              ? ProofGateOutcome.agree
              : ProofGateOutcome.disagreeVerdict,
          parseConfidencePermille: 1000,
          confidenceMinPermille: 990,
        );
        for (final combo in [
          [false, false, false], // low confidence
          [true, true, false], // foreign unpriced
          [true, false, true], // requires review
        ]) {
          final d = CaptureCommitDecision.primary(
            canAutoConfirm: combo[0],
            foreignUnpriced: combo[1],
            requiresReview: combo[2],
            proofGate: g,
          );
          expect(d.status, TransactionStatus.pending,
              reason: 'Proof must never create a confirmation that the '
                  'deterministic pipeline did not already reach');
        }
      }
    });

    test('shadow mode leaves EVERY decision byte-identical', () {
      // What makes shadow measurement honest: the recorded outcome describes
      // the decision that was actually made.
      for (final outcome in ProofGateOutcome.values) {
        final shadow = ProofGateDecision(
          mode: ProofGateMode.shadow,
          outcome: outcome,
          parseConfidencePermille: 500,
          confidenceMinPermille: 990,
        );
        for (final combo in [
          [true, false, false],
          [false, false, false],
          [true, true, false],
          [true, false, true],
        ]) {
          final withProof = CaptureCommitDecision.primary(
            canAutoConfirm: combo[0],
            foreignUnpriced: combo[1],
            requiresReview: combo[2],
            proofGate: shadow,
          );
          final without = CaptureCommitDecision.primary(
            canAutoConfirm: combo[0],
            foreignUnpriced: combo[1],
            requiresReview: combo[2],
          );
          expect(withProof.status, without.status);
          expect(withProof.reason, without.reason);
        }
      }
    });

    test('armed disagreement downgrades confirmed to pending, with its reason', () {
      for (final bad in [
        ProofGateOutcome.disagreeVerdict,
        ProofGateOutcome.disagreeFields,
        ProofGateOutcome.belowConfidence,
        ProofGateOutcome.notEvaluated,
      ]) {
        final d = CaptureCommitDecision.primary(
          canAutoConfirm: true,
          foreignUnpriced: false,
          requiresReview: false,
          proofGate: ProofGateDecision(
            mode: ProofGateMode.armed,
            outcome: bad,
            parseConfidencePermille: 1000,
            confidenceMinPermille: 990,
          ),
        );
        expect(d.status, TransactionStatus.pending, reason: '$bad must not commit');
        expect(d.reason, CaptureCommitReason.proofNotCorroborated);
      }
    });

    test('armed agreement leaves an otherwise-confirmed capture confirmed', () {
      final d = CaptureCommitDecision.primary(
        canAutoConfirm: true,
        foreignUnpriced: false,
        requiresReview: false,
        proofGate: const ProofGateDecision(
          mode: ProofGateMode.armed,
          outcome: ProofGateOutcome.agree,
          parseConfidencePermille: 1000,
          confidenceMinPermille: 990,
        ),
      );
      expect(d.status, TransactionStatus.confirmed);
    });
  });

  group('INVARIANT: no orphan confirmed fee', () {
    // The seam class exists because one captured message once decided its
    // primary and fee status in two unrelated places. A Proof gate that secured
    // only the primary would inherit exactly that failure: a committed fee row
    // belonging to a transaction no human has seen, shown on no screen as
    // related to anything pending.
    test('a Proof-withheld primary leaves NO confirmed fee', () {
      final withheld = CaptureCommitDecision.primary(
        canAutoConfirm: true,
        foreignUnpriced: false,
        requiresReview: false,
        proofGate: const ProofGateDecision(
          mode: ProofGateMode.armed,
          outcome: ProofGateOutcome.disagreeFields,
          parseConfidencePermille: 1000,
          confidenceMinPermille: 990,
        ),
      );
      expect(withheld.reason, CaptureCommitReason.proofNotCorroborated);

      // Even on the most permissive fee inputs — exact text, canonical mode —
      // the fee must follow the primary.
      for (final exact in [true, false]) {
        for (final canonical in [true, false]) {
          final fee = CaptureCommitDecision.fee(
            hasExactText: exact,
            canonicalMode: canonical,
            primaryWithheldByProof: true,
          );
          expect(fee.status, TransactionStatus.pending,
              reason: 'orphan confirmed fee with exact=$exact '
                  'canonical=$canonical');
          expect(fee.reason, CaptureCommitReason.proofNotCorroborated);
        }
      }
    });

    test('fee behaviour is UNCHANGED when Proof did not withhold', () {
      // The invariant must not alter the pre-existing fee policy in any other
      // case — this is a new constraint, not a new policy.
      for (final exact in [true, false]) {
        for (final canonical in [true, false]) {
          final withFlag = CaptureCommitDecision.fee(
            hasExactText: exact,
            canonicalMode: canonical,
            primaryWithheldByProof: false,
          );
          final legacy = CaptureCommitDecision.fee(
            hasExactText: exact,
            canonicalMode: canonical,
          );
          expect(withFlag.status, legacy.status);
          expect(withFlag.reason, legacy.reason);
        }
      }
    });
  });

  group('INVARIANT: absence is never agreement', () {
    test('a null proof is notEvaluated, not agreement', () {
      final d = gate.evaluate(
        mode: ProofGateMode.armed,
        proof: null,
        parseConfidence: 1.0,
        parsedDirection: 'outgoing',
        parsedAmountCanonical: '125.75',
        parsedCurrency: 'SAR',
      );
      expect(d.outcome, ProofGateOutcome.notEvaluated);
      expect(d.agrees, isFalse);
      expect(d.withholdsConfirmation, isTrue);
    });

    test('a null field on EITHER side is disagreement', () {
      final proven = proofOf(
          'تم خصم 125.75 ر.س لدى ستاربكس', TransactionType.payment, 12575, 'SAR');
      expect(proven.verdict, ProofVerdict.proven);
      final d = gate.evaluate(
        mode: ProofGateMode.armed,
        proof: proven,
        parseConfidence: 1.0,
        parsedDirection: null, // parser could not name a direction
        parsedAmountCanonical: '125.75',
        parsedCurrency: 'SAR',
      );
      expect(d.outcome, ProofGateOutcome.disagreeFields);
    });
  });

  group('regressions the first review caught', () {
    test('null on BOTH sides is disagreement, not agreement', () {
      // A regression of same() to plain `==` would make null == null pass. The
      // original test only covered null on ONE side, so this exact regression
      // would have survived the suite.
      final d = gate.evaluate(
        mode: ProofGateMode.armed,
        proof: null,
        parseConfidence: 1.0,
        parsedDirection: null,
        parsedAmountCanonical: null,
        parsedCurrency: null,
      );
      expect(d.agrees, isFalse);
    });

    test('blank strings on both sides are disagreement', () {
      // same('', '') previously returned true, so two ABSENT values agreed —
      // the opposite of the rule this gate exists to enforce.
      final proven = proofOf(
          'تم خصم 125.75 ر.س لدى ستاربكس', TransactionType.payment, 12575, 'SAR');
      final d = gate.evaluate(
        mode: ProofGateMode.armed,
        proof: proven,
        parseConfidence: 1.0,
        parsedDirection: '   ',
        parsedAmountCanonical: '125.75',
        parsedCurrency: 'SAR',
      );
      expect(d.outcome, ProofGateOutcome.disagreeFields);
    });

    test('a non-finite parse confidence does not throw', () {
      // (NaN * 1000).floor() throws UnsupportedError. On the commit path that
      // would abort the SAVE — in shadow mode — for a capture that would
      // otherwise have been stored fine.
      for (final bad in [double.nan, double.infinity, -double.infinity]) {
        expect(
          () => gate.evaluate(
            mode: ProofGateMode.shadow,
            proof: null,
            parseConfidence: bad,
            parsedDirection: 'outgoing',
            parsedAmountCanonical: '1.00',
            parsedCurrency: 'SAR',
          ),
          returnsNormally,
          reason: 'confidence $bad must degrade, never throw',
        );
      }
    });

    test('permille exactly AT the floor agrees', () {
      // Pins the boundary of the `<` comparison.
      final proven = proofOf(
          'تم خصم 125.75 ر.س لدى ستاربكس', TransactionType.payment, 12575, 'SAR');
      final d = gate.evaluate(
        mode: ProofGateMode.armed,
        proof: proven,
        parseConfidence: 0.99, // exactly 990‰
        parsedDirection: 'outgoing',
        parsedAmountCanonical: '125.75',
        parsedCurrency: 'SAR',
      );
      expect(d.parseConfidencePermille, 990);
      expect(d.outcome, ProofGateOutcome.agree);
    });
  });

  group('confidence floor', () {
    test('below the floor does not agree even when every field matches', () {
      final proven = proofOf(
          'تم خصم 125.75 ر.س لدى ستاربكس', TransactionType.payment, 12575, 'SAR');
      final d = gate.evaluate(
        mode: ProofGateMode.armed,
        proof: proven,
        parseConfidence: 0.95, // above the 0.92 deterministic bar, below 990‰
        parsedDirection: 'outgoing',
        parsedAmountCanonical: '125.75',
        parsedCurrency: 'SAR',
      );
      expect(d.outcome, ProofGateOutcome.belowConfidence);
    });

    test('the shipped floor is 990‰', () {
      expect(ProofCommitGate.defaultParserConfidenceMinPermille, 990);
    });
  });

  group('the remote floor may tighten, never loosen', () {
    // Mirrors the DI clamp in app_providers.dart. The clamp had zero tests, and
    // as a RANGE check it accepted 1..989 — so a remote `99` (percent written
    // where permille was meant) would have dropped the floor from 990 to ~10%.
    int clamp(int remote) =>
        (remote > ProofCommitGate.defaultParserConfidenceMinPermille && remote <= 1000)
            ? remote
            : ProofCommitGate.defaultParserConfidenceMinPermille;

    test('a lower remote value is REJECTED, keeping the shipped floor', () {
      for (final loosening in [1, 99, 500, 920, 989, 990]) {
        expect(clamp(loosening), 990,
            reason: 'remote $loosening must not loosen the gate');
      }
    });

    test('a higher remote value is accepted', () {
      expect(clamp(995), 995);
      expect(clamp(1000), 1000);
    });

    test('missing or nonsensical values fall back to the floor', () {
      for (final bad in [0, -1, 1001, 99999]) {
        expect(clamp(bad), 990);
      }
    });
  });

  group('the shadow record carries no financial content', () {
    test('only an outcome label and two integers', () {
      final r = gate
          .evaluate(
            mode: ProofGateMode.shadow,
            proof: null,
            parseConfidence: 0.97,
            parsedDirection: 'outgoing',
            parsedAmountCanonical: '125.75',
            parsedCurrency: 'SAR',
          )
          .toRecord();
      expect(r.keys.toSet(), {
        'mode', 'outcome', 'parse_confidence_permille', 'confidence_min_permille'
      });
      // No amount, currency, merchant or message text may appear.
      final serialised = r.toString();
      for (final leak in ['125.75', 'SAR', 'ستاربكس']) {
        expect(serialised.contains(leak), isFalse, reason: 'leaked $leak');
      }
    });
  });
}
