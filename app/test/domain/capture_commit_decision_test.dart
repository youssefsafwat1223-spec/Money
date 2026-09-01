// Direct unit tests for the PHASE 1 capture commit seam.
//
// The characterization suite proves the seam did not change end-to-end
// behaviour. These prove the seam's own truth table, including the property
// that actually motivated it: the FEE row obeys a DIFFERENT policy from the
// primary row, and that difference is now explicit and testable instead of
// being an accident of where the code happened to live.

import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/domain/entities/transaction_entity.dart';
import 'package:money_companion/domain/usecases/capture_commit_decision.dart';

void main() {
  group('CaptureCommitDecision.primary', () {
    test('confirms only when every gate passes', () {
      final d = CaptureCommitDecision.primary(
        canAutoConfirm: true,
        foreignUnpriced: false,
        requiresReview: false,
      );
      expect(d.status, TransactionStatus.confirmed);
      expect(d.reason, CaptureCommitReason.autoConfirmed);
      expect(d.isConfirmed, isTrue);
    });

    test('low confidence / new merchant / direction contradiction → pending',
        () {
      final d = CaptureCommitDecision.primary(
        canAutoConfirm: false,
        foreignUnpriced: false,
        requiresReview: false,
      );
      expect(d.status, TransactionStatus.pending);
      expect(d.reason, CaptureCommitReason.lowConfidenceOrNewMerchant);
    });

    test('foreign-unpriced → pending, and is reported as its own reason', () {
      final d = CaptureCommitDecision.primary(
        canAutoConfirm: true,
        foreignUnpriced: true,
        requiresReview: false,
      );
      expect(d.status, TransactionStatus.pending);
      expect(d.reason, CaptureCommitReason.foreignUnpriced);
    });

    test('non-exact amount ingress → pending', () {
      final d = CaptureCommitDecision.primary(
        canAutoConfirm: true,
        foreignUnpriced: false,
        requiresReview: true,
      );
      expect(d.status, TransactionStatus.pending);
      expect(d.reason, CaptureCommitReason.nonExactAmountIngress);
    });

    test('the full truth table matches the pre-seam boolean expression', () {
      for (final can in [true, false]) {
        for (final foreign in [true, false]) {
          for (final review in [true, false]) {
            final expected = (can && !foreign && !review)
                ? TransactionStatus.confirmed
                : TransactionStatus.pending;
            expect(
              CaptureCommitDecision.primary(
                canAutoConfirm: can,
                foreignUnpriced: foreign,
                requiresReview: review,
              ).status,
              expected,
              reason: 'can=$can foreign=$foreign review=$review',
            );
          }
        }
      }
    });
  });

  group('CaptureCommitDecision.fee', () {
    test('exact text confirms in canonical mode', () {
      final d = CaptureCommitDecision.fee(
        hasExactText: true,
        canonicalMode: true,
      );
      expect(d.status, TransactionStatus.confirmed);
    });

    test('non-exact text in canonical mode → pending review', () {
      final d = CaptureCommitDecision.fee(
        hasExactText: false,
        canonicalMode: true,
      );
      expect(d.status, TransactionStatus.pending);
      expect(d.reason, CaptureCommitReason.nonExactAmountIngress);
    });

    test('exactness alone decides the fee, in BOTH modes', () {
      // Verified against resolveAiCaptureIngress: it returns
      // legacyPendingReview whenever hasExactText is false, regardless of
      // canonicalMode. canonicalMode only forces the same outcome earlier. So
      // the fee truth table is a function of exactness alone.
      for (final canonical in [true, false]) {
        expect(
          CaptureCommitDecision.fee(
            hasExactText: true,
            canonicalMode: canonical,
          ).status,
          TransactionStatus.confirmed,
          reason: 'canonicalMode=$canonical',
        );
        expect(
          CaptureCommitDecision.fee(
            hasExactText: false,
            canonicalMode: canonical,
          ).status,
          TransactionStatus.pending,
          reason: 'canonicalMode=$canonical — a non-exact bank amount is never '
              'silently rounded into authority',
        );
      }
    });

    test(
        'DOCUMENTED ASYMMETRY: the fee policy does not consult canAutoConfirm, '
        'so a fee can confirm while its primary row is pending', () {
      // This is the pre-existing behaviour the seam makes visible rather than
      // fixes. Unifying the two policies would be a behaviour change and is
      // explicitly out of Phase-1 scope.
      final primary = CaptureCommitDecision.primary(
        canAutoConfirm: false, // primary would be PENDING
        foreignUnpriced: false,
        requiresReview: false,
      );
      final fee = CaptureCommitDecision.fee(
        hasExactText: true, // fee is CONFIRMED
        canonicalMode: true,
      );

      expect(primary.status, TransactionStatus.pending);
      expect(fee.status, TransactionStatus.confirmed);
      expect(primary.status == fee.status, isFalse,
          reason: 'documents the asymmetry a later phase must decide on');
    });
  });
}
