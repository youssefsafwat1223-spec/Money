// PHASE 3 — deterministic proof checker.
//
// Two test classes, per the approved plan:
//   A. deterministic behaviour on real message shapes (drift detector)
//   B. SEMANTIC SAFETY INVARIANTS — authoritative
//
// No AI is called anywhere. Every "proposal" here is a literal struct standing
// in for what a model would later return, which is exactly how the checker will
// see it in production.

import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/engine/models/transaction_type.dart';
import 'package:money_companion/engine/proof/evidence.dart';
import 'package:money_companion/engine/proof/proof_checker.dart';

const checker = ProofChecker();

/// A well-formed proposal, so each test can vary exactly one thing.
ProofProposal proposal({
  String isTransaction = 'transaction',
  String state = 'completed',
  String direction = 'outgoing',
  TransactionType type = TransactionType.payment,
  String? amountId = 'NUMBER_1',
  String? currencyId = 'CURRENCY_1',
  String? feeId,
  String? balanceId,
}) =>
    ProofProposal(
      isTransaction: isTransaction,
      state: state,
      direction: direction,
      type: type,
      amountId: amountId,
      currencyId: currencyId,
      feeId: feeId,
      balanceId: balanceId,
    );

void main() {
  // A clean outgoing purchase: one amount, one currency, one outgoing cue.
  const cleanSms = 'تم خصم 125.75 ر.س لدى ستاربكس';

  group('A. deterministic behaviour', () {
    test('a clean purchase proves', () {
      final ev = extractEvidence(cleanSms);
      final r = checker.check(ev, proposal());
      expect(r.verdict, ProofVerdict.proven, reason: '${r.reasons}');
      expect(r.amountText, '125.75');
      expect(r.currency, 'SAR');
      expect(r.currencyScale, 2);
      expect(r.direction, 'outgoing');
    });

    test('the proven amount is the SOURCE token, never the proposal', () {
      final ev = extractEvidence('تم خصم 45.750 د.ك');
      final r = checker.check(ev, proposal());
      expect(r.isProven, isTrue, reason: '${r.reasons}');
      expect(r.amountText, '45.750',
          reason: 'every digit preserved — never 45.75');
      expect(r.amountCanonical, '45.750');
    });

    test('Arabic-Indic digits prove with their original text intact', () {
      final ev = extractEvidence('تم خصم ٦٣٢٫١٢٤ ر.ع');
      final r = checker.check(ev, proposal());
      expect(r.isProven, isTrue, reason: '${r.reasons}');
      expect(r.amountText, '٦٣٢٫١٢٤');
      expect(r.amountCanonical, '632.124');
      expect(r.currency, 'OMR');
    });

    test('an incoming salary proves when the cue agrees', () {
      final ev = extractEvidence('تم إيداع راتب 5000.00 ر.س');
      final r = checker.check(
        ev,
        proposal(direction: 'incoming', type: TransactionType.income),
      );
      expect(r.isProven, isTrue, reason: '${r.reasons}');
      expect(r.direction, 'incoming');
    });
  });

  group('B1. money invariants — fabrication is structurally impossible', () {
    test('a literal digit in a money field is a protocol violation', () {
      final ev = extractEvidence(cleanSms);
      final r = checker.check(ev, proposal(amountId: '125.75'));
      expect(r.isProven, isFalse);
      expect(r.reasons, contains(ProofReason.literalDigitsInMoneyField));
      expect(r.amountText, isNull, reason: 'nothing resolved from a literal');
    });

    test('a fabricated amount not present in the message cannot be proposed',
        () {
      final ev = extractEvidence(cleanSms);
      // There is no NUMBER_9 — an invented ID resolves to nothing.
      final r = checker.check(ev, proposal(amountId: 'NUMBER_9'));
      expect(r.isProven, isFalse);
      expect(r.reasons, contains(ProofReason.unknownEvidenceId));
      expect(r.amountText, isNull);
    });

    test('a PARTIAL amount cannot exist as an ID, so it cannot be selected',
        () {
      // `9,500.00` is one maximal token. There is no node for `9.5` or `500.00`.
      final ev = extractEvidence('Purchase SAR 9,500.00 at NOON');
      final numbers = ev.ofClass(EvidenceClass.number).toList();
      expect(numbers, hasLength(1));
      expect(numbers.single.text, '9,500.00');

      final r = checker.check(ev, proposal());
      expect(r.isProven, isTrue, reason: '${r.reasons}');
      expect(r.amountText, '9,500.00');
      expect(r.amountCanonical, '9500.00');
    });

    test('a wrong-KIND id (currency used as amount) is rejected', () {
      final ev = extractEvidence(cleanSms);
      final r = checker.check(ev, proposal(amountId: 'CURRENCY_1'));
      expect(r.isProven, isFalse);
      expect(r.reasons, contains(ProofReason.wrongKindEvidenceId));
    });

    test('an AMBIGUOUS token can never become an amount', () {
      final ev = extractEvidence('Amount 12,50 SAR');
      final r = checker.check(ev, proposal());
      expect(r.isProven, isFalse);
      expect(r.reasons, contains(ProofReason.amountAmbiguousToken));
    });

    test('no amount selected → never proven', () {
      final ev = extractEvidence(cleanSms);
      final r = checker.check(ev, proposal(amountId: null));
      expect(r.isProven, isFalse);
      expect(r.reasons, contains(ProofReason.noAmountSelected));
    });

    test('precision exceeding the currency scale is refused', () {
      // 3 decimals proposed against a 2-decimal currency.
      final ev = extractEvidence('Purchase SAR 12.345 at SHOP');
      final r = checker.check(ev, proposal());
      expect(r.isProven, isFalse);
      expect(r.reasons,
          contains(ProofReason.amountPrecisionExceedsCurrencyScale));
    });
  });

  group('B2. currency invariants', () {
    test('no currency selected → never proven', () {
      final ev = extractEvidence(cleanSms);
      final r = checker.check(ev, proposal(currencyId: null));
      expect(r.isProven, isFalse);
      expect(r.reasons, contains(ProofReason.noCurrencySelected));
    });

    test('an unknown currency id is rejected', () {
      final ev = extractEvidence(cleanSms);
      final r = checker.check(ev, proposal(currencyId: 'CURRENCY_7'));
      expect(r.isProven, isFalse);
      expect(r.reasons, contains(ProofReason.unknownEvidenceId));
    });

    test('a message with no currency cannot prove', () {
      final ev = extractEvidence('تم خصم 125.75 لدى ستاربكس');
      final r = checker.check(ev, proposal(currencyId: 'CURRENCY_1'));
      expect(r.isProven, isFalse);
    });
  });

  group('B3. direction — independent corroboration required', () {
    test('no direction cue → review(direction_ambiguous), never proven', () {
      final ev = extractEvidence('SAR 100.00 XYZ REF 12345678');
      final r = checker.check(ev, proposal());
      expect(r.isProven, isFalse);
      expect(r.reasons, contains(ProofReason.directionAmbiguous));
    });

    test('contradictory cues → review(direction_conflict)', () {
      final ev = extractEvidence('تم خصم 100.00 ر.س ثم تم إيداع مبلغ');
      final r = checker.check(ev, proposal());
      expect(r.isProven, isFalse);
      expect(r.reasons, contains(ProofReason.directionConflict));
    });

    test('a proposal that contradicts the only cue is refused', () {
      // The message says خصم (outgoing); the proposal claims incoming.
      final ev = extractEvidence(cleanSms);
      final r = checker.check(ev, proposal(direction: 'incoming'));
      expect(r.isProven, isFalse);
      expect(r.reasons, contains(ProofReason.directionConflict));
    });

    test('an indefinite direction is refused', () {
      final ev = extractEvidence(cleanSms);
      for (final d in ['ambiguous', 'neutral', '']) {
        final r = checker.check(ev, proposal(direction: d));
        expect(r.isProven, isFalse, reason: d);
        expect(r.reasons, contains(ProofReason.directionNotDefinite));
      }
    });

    test('AI TYPE cannot corroborate AI DIRECTION — the circularity ban', () {
      // No lexical direction cue in this message. A payment type implies
      // "debit", and if the checker used that as corroboration this would
      // prove. It must NOT.
      final ev = extractEvidence('SAR 100.00 at SHOP REF 99887766');
      expect(ev.ofClass(EvidenceClass.directionCue), isEmpty,
          reason: 'precondition: no independent direction evidence exists');
      final r = checker.check(
        ev,
        proposal(direction: 'outgoing', type: TransactionType.payment),
      );
      expect(r.isProven, isFalse,
          reason: 'type must never stand in for independent evidence');
      expect(r.reasons, contains(ProofReason.directionAmbiguous));
    });
  });

  group('B4. state and non-transactions', () {
    test('an OTP message is notTransaction, not a failed proof', () {
      final ev = extractEvidence('Your OTP is 482910, do not share');
      final r = checker.check(ev, proposal(state: 'otp'));
      expect(r.verdict, ProofVerdict.notTransaction);
    });

    test('a declined message is notTransaction', () {
      final ev = extractEvidence('Transaction DECLINED for SAR 450.00');
      final r = checker.check(ev, proposal(state: 'declined'));
      expect(r.verdict, ProofVerdict.notTransaction);
    });

    test('a deterministic cue OVERRIDES a completed claim', () {
      // The proposal lies: it says completed, the message says DECLINED.
      final ev = extractEvidence('Transaction DECLINED for SAR 450.00');
      final r = checker.check(ev, proposal(state: 'completed'));
      expect(r.verdict, ProofVerdict.notTransaction);
      expect(r.reasons, contains(ProofReason.contradictedByStateCue));
    });

    test('a pending state is never proven', () {
      final ev = extractEvidence('عملية معلقة بقيمة 33.750 د.ب');
      final r = checker.check(ev, proposal(state: 'pending'));
      expect(r.isProven, isFalse);
      expect(r.reasons, contains(ProofReason.stateNotCompleted));
    });

    test('an explicit non_transaction is honoured', () {
      final ev = extractEvidence('عرض خاص! خصومات حتى 50');
      final r = checker.check(ev, proposal(isTransaction: 'non_transaction'));
      expect(r.verdict, ProofVerdict.notTransaction);
    });
  });

  group('B5. evidence completeness', () {
    test('a TRUNCATED evidence set can never be proven from', () {
      final sb = StringBuffer('تم خصم 100.00 ر.س ');
      for (var i = 0; i < 60; i++) {
        sb.write('${1000 + i}.${(i % 90) + 10} ر.س ');
      }
      final ev = extractEvidence(sb.toString());
      expect(ev.exceedsNodeCap, isTrue, reason: 'precondition');
      final r = checker.check(ev, proposal());
      expect(r.isProven, isFalse);
      expect(r.reasons, contains(ProofReason.evidenceTruncated),
          reason: 'the omitted nodes could contain the falsifying amount');
    });
  });

  group('B6. family policy', () {
    test('credit-card repayment is REVIEW-ONLY regardless of a clean proof',
        () {
      // Everything else about this proposal is perfect.
      final ev = extractEvidence('تم خصم 438.426 ر.س سداد بطاقة');
      final r = checker.check(
        ev,
        proposal(type: TransactionType.creditCardPayment),
      );
      expect(r.isProven, isFalse);
      expect(r.reasons, contains(ProofReason.creditCardRepaymentReviewOnly),
          reason: 'Phase 0-A approved transfer semantics but production '
              '_mapType still collapses it to payment');
    });

    test('an ordinary payment in the same shape DOES prove', () {
      final ev = extractEvidence('تم خصم 438.42 ر.س لدى متجر');
      final r = checker.check(ev, proposal(type: TransactionType.payment));
      expect(r.isProven, isTrue, reason: '${r.reasons}');
    });
  });

  group('B7. adversarial — the negative-probe shapes', () {
    const hostile = <String, String>{
      'otp': 'رمز التحقق الخاص بك هو 4520 لعملية شراء بقيمة 350.00 ر.س',
      'declined': 'عملية مرفوضة: تم رفض شراء بقيمة 75.500 د.ك',
      'promo': 'عرض خاص! احصل على خصم 15.000 د.ك عند الشراء',
      'balance': 'رصيدكم الحالي 840.230 د.ك. شكرا لتعاملكم معنا',
    };

    test('hostile non-transactions never reach proven, even if the '
        'proposal claims completed', () {
      hostile.forEach((label, sms) {
        final ev = extractEvidence(sms);
        final r = checker.check(ev, proposal(state: 'completed'));
        expect(r.isProven, isFalse, reason: '$label: $sms');
      });
    });

    test('a balance distractor cannot be proven as the amount without a cue',
        () {
      final ev = extractEvidence('رصيدكم الحالي 840.230 د.ك');
      final r = checker.check(ev, proposal());
      expect(r.isProven, isFalse);
    });
  });

  group('B8. determinism', () {
    test('the same inputs always produce the same verdict', () {
      final ev = extractEvidence(cleanSms);
      final a = checker.check(ev, proposal());
      final b = checker.check(ev, proposal());
      expect(a.verdict, b.verdict);
      expect(a.reasons, b.reasons);
      expect(a.amountText, b.amountText);
    });

    test('an empty message proves nothing', () {
      final r = checker.check(extractEvidence(''), proposal());
      expect(r.isProven, isFalse);
    });
  });
}
