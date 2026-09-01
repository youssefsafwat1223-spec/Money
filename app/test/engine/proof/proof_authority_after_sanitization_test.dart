/// PHASE 6 — proof authority must not weaken after sanitization.
///
/// Sanitization removes text, and removing text is a way to accidentally remove
/// a guard. If a balance cue is redacted, does the balance number stop looking
/// like a balance? If a redaction shortens the message, does a distant cue drift
/// into range and start governing a number it never governed?
///
/// The gate must be exactly as strict on the sanitized text as on the original.
/// These tests assert that in the direction that matters: things that must NOT
/// prove still do not prove, and the sanitized path never proves something the
/// original path would have refused.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/engine/models/transaction_type.dart';
import 'package:money_companion/engine/privacy/sanitization_edit_map.dart';
import 'package:money_companion/engine/proof/evidence.dart';
import 'package:money_companion/engine/proof/proof_checker.dart';

/// Run the checker over the sanitized+projected evidence for [sms].
ProofResult proveSanitized(String sms, String amountText,
    {String direction = 'outgoing'}) {
  final san = sanitizeWithMap(sms);
  final evidence = projectOntoSanitized(extractEvidence(sms), san);
  final numbers = evidence.ofClass(EvidenceClass.number);
  final amount = numbers.where((n) => n.text == amountText);
  final currency = evidence.ofClass(EvidenceClass.currency);
  return const ProofChecker().check(
    evidence,
    ProofProposal(
      isTransaction: 'transaction',
      state: 'completed',
      direction: direction,
      type: TransactionType.payment,
      amountId: amount.isEmpty ? null : amount.first.id,
      currencyId: currency.isEmpty ? null : currency.first.id,
    ),
  );
}

void main() {
  group('gates that fired before sanitization still fire after', () {
    test('a balance is still refused as the amount', () {
      const sms = 'شراء 40.00 ر.س. الرصيد المتاح 9,120.75 ر.س';
      final r = proveSanitized(sms, '9,120.75');
      expect(r.isProven, isFalse);
      expect(r.reasons, contains(ProofReason.amountCarriesBalanceCue));
    });

    test('a fee is still refused as the amount', () {
      const sms = 'سحب 50.000 د.ك ورسوم 0.500 د.ك';
      final r = proveSanitized(sms, '0.500');
      expect(r.isProven, isFalse);
      expect(r.reasons, contains(ProofReason.amountCarriesFeeCue));
    });

    test('multi-amount ambiguity still fails closed', () {
      const sms = 'POS AED 45.00\nVAT AED 2.25\nTotal charged AED 47.25';
      final r = proveSanitized(sms, '45.00');
      expect(r.isProven, isFalse);
      expect(r.reasons, contains(ProofReason.amountAmbiguous));
    });

    test('uncorroborated direction still fails closed', () {
      const sms = 'بطاقة إئتمانية: تأكيد السداد\nمبلغ: 197.07 AED';
      final r = proveSanitized(sms, '197.07', direction: 'incoming');
      expect(r.isProven, isFalse);
      expect(r.reasons, contains(ProofReason.directionAmbiguous));
    });

    test('a declined message is still not committable', () {
      const sms = 'تم رفض العملية بمبلغ 250.00 ر.س لدى متجر';
      expect(proveSanitized(sms, '250.00').isProven, isFalse);
    });

    test('a future obligation is still not completed', () {
      const sms = 'Payment due SAR 90.00 on 12/07';
      final r = proveSanitized(sms, '90.00');
      expect(r.isProven, isFalse);
      expect(r.reasons, contains(ProofReason.futureObligationNotCompleted));
    });
  });

  group('redaction removes authority rather than granting it', () {
    test('a redacted amount cannot be proven — it is gone, not guessed', () {
      // The account pattern eats a 14-digit run. Whatever it was, no proof may
      // be built on it afterwards.
      const sms = 'Transfer 12345678901234 SAR 500.00';
      final san = sanitizeWithMap(sms);
      final evidence = projectOntoSanitized(extractEvidence(sms), san);
      expect(
        evidence
            .ofClass(EvidenceClass.number)
            .any((e) => e.text == '12345678901234'),
        isFalse,
      );
    });

    test('redacting a cue does not promote a number that was blocked', () {
      // `[ACCOUNT]` replaces digits near the card cue. The purchase amount must
      // still be the amount, and nothing else may become eligible.
      const sms = 'شراء 45.00 ر.س من حساب 12345678901234';
      final san = sanitizeWithMap(sms);
      final evidence = projectOntoSanitized(extractEvidence(sms), san);
      final numbers =
          evidence.ofClass(EvidenceClass.number).map((e) => e.text).toSet();
      expect(numbers.contains('45.00'), isTrue);
      expect(numbers.contains('12345678901234'), isFalse);
    });
  });

  group('a clean message still proves — the gate is not achieved by refusing all',
      () {
    test('an ordinary purchase with nothing to redact still proves', () {
      final r = proveSanitized('شراء بمبلغ 45.00 ر.س لدى مطعم البيك', '45.00');
      expect(r.isProven, isTrue,
          reason: 'sanitization must not break provable messages');
    });

    test('a purchase whose PAN was redacted still proves on its amount', () {
      final r = proveSanitized(
          'شراء ببطاقة 1234-5678-9012-3456 بمبلغ 45.00 ر.س', '45.00');
      expect(r.isProven, isTrue,
          reason: 'redacting a card must not cost the transaction its proof');
    });

    test('an OTP redaction leaves the amount provable', () {
      // The OTP cue is kept, its digits removed. Note the message still carries
      // an OTP state cue, so this asserts the AMOUNT survived, not that the
      // message commits.
      const sms = 'رمز التحقق 4471 والمبلغ 250.00 ر.س';
      final san = sanitizeWithMap(sms);
      final evidence = projectOntoSanitized(extractEvidence(sms), san);
      expect(
          evidence.ofClass(EvidenceClass.number).any((e) => e.text == '250.00'),
          isTrue);
      expect(san.text.contains('4471'), isFalse);
    });
  });
}
