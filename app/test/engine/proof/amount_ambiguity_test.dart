/// Rev-4 multi-amount ambiguity — the fail-closed selection gate.
///
/// The rev-3 baseline's one remaining false commit was
/// `POS AED 45.00 / VAT AED 2.25 / Total charged AED 47.25`, where the model
/// selected 45.00. That token satisfied every guarantee the architecture makes:
/// real, complete, correctly spanned, no blocking role. Resolving amounts by
/// evidence ID stops fabrication, not mis-selection.
///
/// The contract these tests enforce: when more than one candidate survives
/// deterministic filtering, REVIEW. No largest-wins, last-wins or total-wins
/// rule is permitted, so the tests below assert the ABSENCE of a preference as
/// firmly as they assert filtering.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/engine/models/transaction_type.dart';
import 'package:money_companion/engine/proof/amount_candidates.dart';
import 'package:money_companion/engine/proof/evidence.dart';
import 'package:money_companion/engine/proof/proof_checker.dart';

Set<String> candidateTexts(String sms) =>
    amountCandidates(extractEvidence(sms)).map((e) => e.text).toSet();

/// Run the full checker with a corroborated direction, so the only thing that
/// can hold the message back is amount ambiguity.
ProofResult proveWith(String sms, String amountText) {
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

void main() {
  group('base + tax + total — the rev-3 open defect', () {
    const sms = 'POS AED 45.00\nVAT AED 2.25\nTotal charged AED 47.25\nAt SHOP';

    test('the VAT line is filtered out', () {
      expect(candidateTexts(sms), isNot(contains('2.25')));
    });

    test('base and total both survive, so the message is ambiguous', () {
      expect(candidateTexts(sms), containsAll(<String>['45.00', '47.25']));
    });

    test('45.00 must NEVER be proven', () {
      final r = proveWith(sms, '45.00');
      expect(r.isProven, isFalse);
      expect(r.reasons, contains(ProofReason.amountAmbiguous));
    });

    test('47.25 is not proven either — ambiguity is not resolved by being right',
        () {
      // The gate is about what the message establishes, not about whether the
      // model happened to guess well. Rewarding the lucky guess would make the
      // outcome depend on the model again.
      final r = proveWith(sms, '47.25');
      expect(r.isProven, isFalse);
      expect(r.reasons, contains(ProofReason.amountAmbiguous));
    });
  });

  group('single-candidate messages still commit', () {
    test('amount + fee', () {
      const sms = 'سحب 50.000 د.ك ورسوم 0.500 د.ك';
      expect(candidateTexts(sms), equals({'50.000'}));
    });

    test('amount + balance', () {
      const sms = 'شراء 40.00 ر.س. الرصيد المتاح 9,120.75 ر.س';
      expect(candidateTexts(sms), equals({'40.00'}));
    });

    test('amount + reference number', () {
      const sms = 'Purchase SAR 66.00 REF 4471902';
      expect(candidateTexts(sms), equals({'66.00'}));
    });

    test('amount + account number', () {
      const sms = 'شراء 45.00 ر.س من حساب A/C 887766';
      expect(candidateTexts(sms), equals({'45.00'}));
    });

    test('a total ALONE is the transaction amount', () {
      const sms = 'الإجمالي 512.40 ج.م تم خصمه من حسابك';
      expect(candidateTexts(sms), equals({'512.40'}));
      expect(proveWith(sms, '512.40').reasons,
          isNot(contains(ProofReason.amountAmbiguous)));
    });
  });

  group('dates and card digits must not manufacture ambiguity', () {
    test('a timestamp contributes no candidates', () {
      const sms = 'شراء PoS\nعبر:6826;مدى\nبـSAR 24\nلـSTARBUCKS\n13/6/26 16:03';
      expect(candidateTexts(sms), equals({'24'}),
          reason: 'the date and card digits are not monetary');
    });

    test('an integer amount with no decimals still counts', () {
      const sms = 'Online Purchase\nAmount 8 SAR\nAccount *1202\non 21/05/26';
      expect(candidateTexts(sms), contains('8'));
    });
  });

  group('two genuine transaction-like amounts', () {
    test('an FX pair is ambiguous', () {
      expect(candidateTexts('Purchase USD 100.00 (AED 367.25)').length,
          greaterThan(1));
    });

    test('two debits in one message are ambiguous', () {
      const sms = 'خصم 120.00 ر.س وخصم 80.00 ر.س';
      expect(candidateTexts(sms), containsAll(<String>['120.00', '80.00']));
      expect(proveWith(sms, '120.00').reasons,
          contains(ProofReason.amountAmbiguous));
    });
  });

  group('no ranking heuristic leaked in', () {
    // If any of largest-wins / last-wins / total-wins had been implemented,
    // one of these would prove. None may.
    const cases = <String, List<String>>{
      'خصم 120.00 ر.س وخصم 80.00 ر.س': ['120.00', '80.00'],
      'Payment SAR 500.00 of total SAR 1,200.00 due': ['500.00', '1,200.00'],
    };

    test('every candidate in an ambiguous message is refused equally', () {
      cases.forEach((sms, amounts) {
        for (final a in amounts) {
          final r = proveWith(sms, a);
          expect(r.isProven, isFalse, reason: '$sms -> $a');
          expect(r.reasons, contains(ProofReason.amountAmbiguous),
              reason: '$sms -> $a');
        }
      });
    });
  });
}
