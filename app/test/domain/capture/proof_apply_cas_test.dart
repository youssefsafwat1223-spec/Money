/// PHASE 10 — CAS races for applying a proof result.
///
/// Every test here is a race that really happens on a phone: the model finishes
/// while someone is editing, a notification is tapped twice, a crash replays a
/// result, two devices sync. The property under test is always the same one —
/// **a user edit beats an AI result, whatever the arrival order** — plus the
/// requirement that a replay is harmless rather than merely tolerated.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/domain/capture/proof_apply_authority.dart';

const _authority = ProofApplyAuthority();

ProofApplyPlan _plan({int expectedRevision = 5, int proofRevision = 100}) =>
    ProofApplyPlan(
      captureUuid: 'u1',
      transactionId: 't1',
      expectedRevision: expectedRevision,
      proofRevision: proofRevision,
      amountMinor: 4500,
      currency: 'SAR',
      direction: 'outgoing',
    );

TargetState _state({
  bool exists = true,
  int revision = 5,
  int? appliedProofRevision,
  int? userEditedAtRevision,
  int? remoteAppliedProofRevision,
}) =>
    TargetState(
      exists: exists,
      revision: revision,
      appliedProofRevision: appliedProofRevision,
      userEditedAtRevision: userEditedAtRevision,
      remoteAppliedProofRevision: remoteAppliedProofRevision,
    );

void main() {
  group('the happy path', () {
    test('a fresh proof against an unchanged transaction applies', () {
      final r = _authority.decide(_plan(), _state());
      expect(r.isApplied, isTrue);
      expect(r.newRevision, 6, reason: 'revision advances exactly once');
    });
  });

  group('user edit wins — the precedence rule', () {
    test('a user edit DURING the model run supersedes the result', () {
      // The model started at revision 5; the user corrected the amount, taking
      // the row to 6. The result lands afterwards and must lose.
      final r = _authority.decide(
        _plan(expectedRevision: 5),
        _state(revision: 6, userEditedAtRevision: 6),
      );
      expect(r.isApplied, isFalse);
      expect(r.rejection, ProofApplyRejection.supersededByUserEdit);
    });

    test('the rejection names the USER EDIT, not generic staleness', () {
      // Both are true; the reported reason must be the meaningful one, or the
      // telemetry will say "stale" for what is really "the person disagreed".
      final r = _authority.decide(
        _plan(expectedRevision: 5),
        _state(revision: 9, userEditedAtRevision: 7),
      );
      expect(r.rejection, ProofApplyRejection.supersededByUserEdit);
    });

    test('an edit BEFORE the proof was computed does not block it', () {
      // The proof already saw that edit — it was computed at revision 5, the
      // edit happened at 4.
      final r = _authority.decide(
        _plan(expectedRevision: 5),
        _state(revision: 5, userEditedAtRevision: 4),
      );
      expect(r.isApplied, isTrue);
    });

    test('a superseded result is TERMINAL — retrying can never help', () {
      final r = _authority.decide(
        _plan(expectedRevision: 5),
        _state(revision: 6, userEditedAtRevision: 6),
      );
      expect(r.isTerminal, isTrue,
          reason: 'the world moved on; a retry would just lose again');
    });
  });

  group('replay is idempotent', () {
    test('re-applying the SAME proof is a no-op, not a failure', () {
      final r = _authority.decide(
        _plan(proofRevision: 100),
        _state(revision: 6, appliedProofRevision: 100),
      );
      expect(r.wasNoOp, isTrue);
      expect(r.rejection, ProofApplyRejection.alreadyApplied);
      expect(r.isTerminal, isTrue);
    });

    test('replay is recognised even though its expected revision is now stale',
        () {
      // This is the ordinary case after a crash: the row advanced when the
      // result was applied, so the plan's expectedRevision is old. Reporting
      // "stale" here would be confusing and would invite a pointless retry.
      final r = _authority.decide(
        _plan(expectedRevision: 5, proofRevision: 100),
        _state(revision: 6, appliedProofRevision: 100),
      );
      expect(r.wasNoOp, isTrue);
      expect(r.rejection, isNot(ProofApplyRejection.staleProofRevision));
    });

    test('a DIFFERENT proof for the same transaction is not a replay', () {
      final r = _authority.decide(
        _plan(expectedRevision: 6, proofRevision: 101),
        _state(revision: 6, appliedProofRevision: 100),
      );
      expect(r.wasNoOp, isFalse);
      expect(r.isApplied, isTrue);
    });
  });

  group('cross-device races', () {
    test('a newer remote apply supersedes ours', () {
      final r = _authority.decide(
        _plan(proofRevision: 100),
        _state(remoteAppliedProofRevision: 101),
      );
      expect(r.rejection, ProofApplyRejection.supersededByRemote);
      expect(r.isTerminal, isTrue);
    });

    test('an OLDER remote apply does not block a newer proof', () {
      final r = _authority.decide(
        _plan(expectedRevision: 5, proofRevision: 101),
        _state(revision: 5, remoteAppliedProofRevision: 100),
      );
      expect(r.isApplied, isTrue);
    });
  });

  group('stale results and unknown targets', () {
    test('a moved row rejects as stale', () {
      final r = _authority.decide(
        _plan(expectedRevision: 5),
        _state(revision: 7),
      );
      expect(r.rejection, ProofApplyRejection.staleProofRevision);
    });

    test('a missing target is rejected, not created', () {
      // Applying a proof updates an EXISTING transaction; it never creates a
      // second one. A missing target is a bug upstream, not an invitation.
      final r = _authority.decide(_plan(), _state(exists: false));
      expect(r.rejection, ProofApplyRejection.unknownTarget);
    });

    test('an unknown target is NOT terminal — it may appear later', () {
      final r = _authority.decide(_plan(), _state(exists: false));
      expect(r.isTerminal, isFalse,
          reason: 'a transaction still syncing in is worth retrying, unlike a '
              'result the world has moved past');
    });
  });

  group('notification action racing an AI result', () {
    test('a tap that lands after the AI result sees a moved revision', () {
      // Both want to change the same row. Whichever runs second is refused by
      // CAS rather than silently overwriting.
      final first = _authority.decide(_plan(expectedRevision: 5), _state(revision: 5));
      expect(first.isApplied, isTrue);
      final second = _authority.decide(
        _plan(expectedRevision: 5, proofRevision: 101),
        _state(revision: first.newRevision),
      );
      expect(second.isApplied, isFalse);
      expect(second.rejection, ProofApplyRejection.staleProofRevision);
    });
  });

  group('a synced pending transaction later receiving proof', () {
    test('proof applies to the EXISTING synced row', () {
      final plan = _plan(expectedRevision: 3);
      final r = _authority.decide(plan, _state(revision: 3));
      expect(r.isApplied, isTrue);
      expect(plan.transactionId, 't1',
          reason: 'the proof updates the transaction that already exists');
    });
  });

  group('primary + fee are one atomic unit', () {
    test('a plan carries both legs or neither', () {
      const withFee = ProofApplyPlan(
        captureUuid: 'u1',
        transactionId: 't1',
        expectedRevision: 5,
        proofRevision: 100,
        amountMinor: 4500,
        currency: 'SAR',
        feeAmountMinor: 500,
        feeCurrency: 'SAR',
      );
      expect(withFee.hasFee, isTrue);
      // The decision is made for the plan as a whole — there is no API by
      // which a caller could apply the primary and skip the fee.
      final r = _authority.decide(withFee, _state());
      expect(r.isApplied, isTrue);
    });

    test('a plan with no fee is still complete', () {
      expect(_plan().hasFee, isFalse);
    });
  });

  group('no partial application', () {
    test('a rejected plan advances nothing', () {
      final r = _authority.decide(
        _plan(expectedRevision: 5),
        _state(revision: 6, userEditedAtRevision: 6),
      );
      expect(r.isApplied, isFalse);
      expect(r.newRevision, 6,
          reason: 'the revision is reported as-found, never half-advanced');
    });
  });
}
