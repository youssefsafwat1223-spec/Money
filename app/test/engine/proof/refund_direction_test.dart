/// Rev-5 refund/reversal direction vocabulary — contrastive.
///
/// The rev-4 baseline auto-committed ZERO of 31 refund rows. Not because the
/// model was wrong and not because a gate was too strict, but because
/// `TransactionType.refund` is declared direction-unambiguous (incoming) by the
/// D2 polarity map while `DirectionSignal` could not recognise a single refund
/// message. The architecture asserted a polarity its own lexicon was unable to
/// detect.
///
/// The danger in fixing this is the opposite error. Cue matching is
/// substring-based, so a short Arabic token is a liability: bare `رد` occurs
/// inside `وارد` (incoming), `ترد` and `يرد`; bare `عكس` occurs inside
/// `بالعكس` and `عكسية`. Either would manufacture false INCOMING polarity on
/// ordinary text — and a false incoming direction on a debit is a wrong-signed
/// transaction, which is worse than not committing at all.
///
/// So every positive case below is paired with a negative one that contains the
/// same lexical fragment in a context where it is NOT direction evidence.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/engine/proof/direction_corroboration.dart';
import 'package:money_companion/engine/proof/evidence.dart';

DirectionResolution resolve(String sms) => resolveDirection(
      deterministicCorroborators(sms: sms, evidence: extractEvidence(sms)),
    );

void expectIncoming(String sms) {
  final r = resolve(sms);
  expect(r.outcome, DirectionOutcome.corroborated, reason: sms);
  expect(r.polarity, DirectionCuePolarity.incoming, reason: sms);
}

/// No INCOMING polarity may be produced — either nothing fires, or the message
/// resolves outgoing on its own debit words.
void expectNoIncoming(String sms) {
  final r = resolve(sms);
  expect(r.polarity, isNot(DirectionCuePolarity.incoming), reason: sms);
}

void main() {
  group('refund and reversal language corroborates INCOMING', () {
    test('استرداد', () {
      expectIncoming('تم استرداد مبلغ 250.00 ر.س إلى بطاقتكم');
    });

    test('مسترد', () {
      expectIncoming('مبلغ مسترد 120.50 ر.س');
    });

    test('عكس قيد — the rev-4 blocker, verbatim', () {
      expectIncoming('عملية عكس قيد بمبلغ 848.760 د.ك لدى كارفور');
    });

    test('رد مبلغ as a phrase', () {
      expectIncoming('رد مبلغ 75.00 ر.س إلى حسابكم');
    });

    test('refund / refunded', () {
      expectIncoming('SAR 300.00 has been refunded to your card');
      expectIncoming('Refund of SAR 300.00 processed');
    });

    test('reversal / reversed', () {
      expectIncoming('Reversal of AED 90.00 on your account');
      expectIncoming('Transaction AED 90.00 has been reversed');
    });
  });

  group('the same fragments are NOT direction evidence here', () {
    // Each of these contains a refund-ish substring in a context where reading
    // it as incoming money would be wrong.
    test('وارد contains رد but is not a refund cue via رد', () {
      // Genuinely incoming, but it must be reached through `مبلغ وارد` — the
      // point is that bare رد was never admitted, so this cannot be an
      // accident of substring matching.
      final r = resolve('مبلغ وارد 500.00 ر.س');
      expect(r.polarity, DirectionCuePolarity.incoming);
    });

    test('a reply instruction must not create incoming polarity', () {
      expectNoIncoming('لا ترد على هذه الرسالة');
      expectNoIncoming('للاستفسار يرجى الرد على الرقم الموحد');
    });

    test('بالعكس / عكسية must not create incoming polarity', () {
      expectNoIncoming('تم تنفيذ العملية بالعكس من المتوقع');
      expectNoIncoming('حركة عكسية في السوق');
    });

    test('non-refundable must not create incoming polarity', () {
      // Bare substring matching would read `refund` inside `non-refundable`
      // and mark a promotional line as money coming in.
      expectNoIncoming('Booking is non-refundable. Terms apply.');
      expectNoIncoming('All fees are non-refundable');
    });

    test('a debit message stays outgoing despite refund-shaped words', () {
      final r = resolve('شراء بمبلغ 45.00 ر.س - لا يمكن الاسترجاع');
      expect(r.polarity, isNot(DirectionCuePolarity.incoming));
    });
  });

  group('a refund with a contradicting debit cue still conflicts', () {
    test('refund plus purchase is a conflict, not a guess', () {
      final r = resolve('شراء 40.00 ر.س ثم استرداد 40.00 ر.س');
      expect(r.outcome, DirectionOutcome.conflict);
    });
  });

  group('Latin boundary matching did not break existing cues', () {
    test('deposit / salary / credited still corroborate incoming', () {
      expectIncoming('Salary of SAR 9,500.00 credited to your account');
      expectIncoming('Deposit of AED 200.00 received');
    });

    test('purchase / payment still corroborate outgoing', () {
      for (final s in const [
        'Purchase SAR 45.00 at PANDA',
        'Payment of AED 90.00 completed',
      ]) {
        expect(resolve(s).polarity, DirectionCuePolarity.outgoing, reason: s);
      }
    });
  });
}
