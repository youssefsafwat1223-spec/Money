/// Rev-6 future-obligation state guard.
///
/// The rev-5 supplement surfaced this: `Payment due SAR 90.00 on 12/07` reached
/// commitability. `Payment` read as an outgoing direction cue, one clean amount
/// candidate survived, and nothing deterministic stood between a bill reminder
/// and a booked transaction — only the model's own `state` field. Money that
/// has not moved must not depend on the model to stay uncommitted.
///
/// The obvious over-correction is worse than the bug. Blocking every message
/// containing `due` would refuse ordinary payment confirmations, statements
/// that merely name an outstanding balance, and anything using `due to`. So
/// most of this file asserts what must STILL commit.
///
/// Two axes are kept deliberately separate:
///   totalDueRules   — WHICH NUMBER is not the transaction (an amount role)
///   obligationDue   — WHETHER MONEY MOVED (a state)
/// A completed purchase notification may legitimately name a total due; that is
/// the amount axis and must not block the state.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/engine/models/transaction_type.dart';
import 'package:money_companion/engine/proof/evidence.dart';
import 'package:money_companion/engine/proof/proof_checker.dart';

bool hasObligationCue(String sms) => extractEvidence(sms)
    .ofClass(EvidenceClass.stateCue)
    .any((e) => e.stateCue == StateCueKind.obligationDue);

/// Runs the checker with a corroborated direction and a `completed` claim, so
/// the obligation guard is the only thing that can hold the message back.
ProofResult claimCompleted(String sms, String amountText) {
  final ev = extractEvidence(sms);
  final amount =
      ev.ofClass(EvidenceClass.number).firstWhere((n) => n.text == amountText);
  final currency = ev.ofClass(EvidenceClass.currency).first;
  return const ProofChecker().check(
    ev,
    ProofProposal(
      isTransaction: 'transaction',
      state: 'completed',
      direction: 'outgoing',
      type: TransactionType.payment,
      amountId: amount.id,
      currencyId: currency.id,
    ),
  );
}

bool blocked(String sms, String amount) => claimCompleted(sms, amount)
    .reasons
    .contains(ProofReason.futureObligationNotCompleted);

void main() {
  group('an unpaid obligation is not a completed transaction', () {
    test('the rev-5 counterexample, verbatim', () {
      expect(blocked('Payment due SAR 90.00 on 12/07', '90.00'), isTrue);
    });

    test('minimum payment due', () {
      expect(blocked('Minimum payment due SAR 250.00 by 03/08', '250.00'),
          isTrue);
    });

    test('amount due', () {
      expect(blocked('Amount due AED 410.50', '410.50'), isTrue);
    });

    test('due by / due on a date', () {
      expect(blocked('Statement SAR 1,200.00 due by 15/09', '1,200.00'), isTrue);
      expect(blocked('SAR 300.00 due on 01/10', '300.00'), isTrue);
    });

    test('Arabic obligation phrasing', () {
      expect(blocked('مستحق السداد 500.00 ر.س', '500.00'), isTrue);
      expect(blocked('تاريخ الاستحقاق 12/07 والمبلغ 90.00 ر.س', '90.00'),
          isTrue);
    });
  });

  group('a settlement statement overrides the obligation', () {
    // These are the cases an over-broad guard would wrongly refuse.
    test('Payment due was paid successfully', () {
      expect(blocked('Payment due SAR 90.00 was paid successfully', '90.00'),
          isFalse);
    });

    test('Amount due has been settled', () {
      expect(blocked('Amount due SAR 410.50 has been settled', '410.50'),
          isFalse);
    });

    test('Arabic settlement', () {
      expect(blocked('تم السداد لمبلغ 500.00 ر.س المستحق السداد', '500.00'),
          isFalse);
    });
  });

  group('what must NOT be treated as an obligation state', () {
    test('a completed payment with no obligation wording', () {
      expect(blocked('Payment of SAR 90.00 completed', '90.00'), isFalse);
    });

    test('a bare purchase', () {
      expect(blocked('شراء بمبلغ 45.00 ر.س لدى مطعم البيك', '45.00'), isFalse);
    });

    test('non-financial "due to" is not an obligation cue', () {
      expect(hasObligationCue('Transaction SAR 20.00 reversed due to an error'),
          isFalse);
      expect(hasObligationCue('Service delayed due to maintenance'), isFalse);
    });

    test('a date alone never implies a future obligation', () {
      expect(hasObligationCue('شراء 45.00 ر.س بتاريخ 12/07/2026'), isFalse);
      expect(hasObligationCue('Purchase SAR 45.00 on 12/07 at 14:32'), isFalse);
    });

    test('the bare word due is not enough', () {
      expect(hasObligationCue('Amount SAR 45.00, dues cleared'), isFalse);
    });

    test('total due as an AMOUNT label does not block a completed purchase',
        () {
      // The amount axis (totalDueRules) and the state axis are separate. This
      // is a real completed purchase that happens to name an outstanding
      // balance; blocking it would confuse the two.
      const sms = 'شراء عبر نقاط البيع بـ SAR 150.00\n'
          'المبلغ الإجمالي المستحق SAR 5620.87';
      expect(hasObligationCue(sms), isFalse);
      expect(blocked(sms, '150.00'), isFalse);
    });
  });

  group('the guard only applies to a completed claim', () {
    test('a pending claim is already handled by the state gate', () {
      final ev = extractEvidence('Payment due SAR 90.00 on 12/07');
      final amount =
          ev.ofClass(EvidenceClass.number).firstWhere((n) => n.text == '90.00');
      final r = const ProofChecker().check(
        ev,
        ProofProposal(
          isTransaction: 'transaction',
          state: 'pending',
          direction: 'outgoing',
          type: TransactionType.payment,
          amountId: amount.id,
          currencyId: ev.ofClass(EvidenceClass.currency).first.id,
        ),
      );
      expect(r.isProven, isFalse);
    });
  });
}
