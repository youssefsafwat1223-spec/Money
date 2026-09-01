/// Contrastive tests for the production cue-role layer.
///
/// These mirror `research/sms_model_lab/proof_parser/test_cue_roles_contrastive.py`
/// case for case. The two implementations must agree, because the frozen
/// benchmark scores the Python one and the phone runs this one; a divergence
/// means the measured architecture is not the shipped architecture.
///
/// The cases are CONTRASTIVE by construction: each pair holds the surface
/// string "charge" fixed and varies only its grammatical role, so an
/// implementation cannot pass by keyword matching.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/engine/proof/cue_roles.dart';
import 'package:money_companion/engine/proof/evidence.dart';

/// Roles assigned to the NUMBER node whose source text is [token].
Set<String> rolesOf(String sms, String token) {
  final evidence = extractEvidence(sms);
  final roles = cueRoles(evidence);
  for (final n in evidence.ofClass(EvidenceClass.number)) {
    if (n.text == token) return roles[n.id] ?? const {};
  }
  fail('"$token" is not a NUMBER node of "$sms"');
}

bool isBlocked(String sms, String token) =>
    rolesOf(sms, token).intersection(kBlockingCueRoles).isNotEmpty;

void main() {
  group('generic transaction verbs do not assign a fee role', () {
    // The defect that failed the first Phase-4 seal: "charged" read as a fee
    // marker blocked the correct amount and let a line-item commit instead.
    test('was charged <amount> at MERCHANT -> amount stays eligible', () {
      expect(isBlocked('was charged AED 249.00 at SPOTIFY', '249.00'), isFalse);
    });

    test('Total charged <amount> -> amount stays eligible', () {
      expect(isBlocked('Total charged AED 47.25', '47.25'), isFalse);
      expect(rolesOf('Total charged AED 47.25', '47.25'), contains('total'));
    });

    test('a total is descriptive, never blocking', () {
      const sms = 'POS AED 45.00\nVAT AED 2.25\nTotal charged AED 47.25';
      expect(isBlocked(sms, '47.25'), isFalse,
          reason: 'the total IS the transaction amount');
      expect(isBlocked(sms, '2.25'), isTrue,
          reason: 'the VAT line is a component, not the transaction');
    });
  });

  group('explicit fee and tax nouns still assign a blocking role', () {
    test('service charge', () {
      expect(rolesOf('service charge AED 2.25', '2.25'), contains('fee'));
    });

    test('bare fee noun after a comma', () {
      expect(rolesOf('ATM withdrawal KWD 50.000, charge KWD 0.500', '0.500'),
          contains('fee'));
    });

    test('fee noun followed by the verb', () {
      expect(rolesOf('fee charged AED 2.25', '2.25'), contains('fee'));
    });

    test('VAT', () {
      expect(rolesOf('VAT AED 2.25', '2.25'), contains('vat'));
    });

    test('Arabic fee noun with a clitic prefix', () {
      // "ورسوم" is "and fees" — Arabic attaches the conjunction to the stem, so
      // a word-boundary rule must NOT be applied to it.
      expect(rolesOf('شراء 200.00 ر.س ورسوم خدمة 3.00 ر.س', '3.00'),
          contains('fee'));
    });

    test('Arabic VAT', () {
      expect(rolesOf('ضريبة القيمة المضافة 7.50 ر.س', '7.50'), contains('vat'));
    });
  });

  group('identifier cues attach only through local structure', () {
    test('a reference before an amount does not contaminate it', () {
      expect(isBlocked('REF 8837201 purchase AED 249.00', '249.00'), isFalse);
    });

    test('a reference after an amount does not contaminate it', () {
      expect(isBlocked('Purchase SAR 66.00 REF 4471902', '66.00'), isFalse);
    });

    test('a card cue does not claim the amount it precedes', () {
      expect(
          isBlocked('Your card was charged SAR 320.00 at NOON', '320.00'),
          isFalse);
    });

    test('the identifier itself keeps the reference role', () {
      expect(rolesOf('Purchase SAR 45.00 from account A/C 887766', '887766'),
          contains('accountRef'));
    });

    test('a long bare digit run is a reference by structure alone', () {
      expect(rolesOf('Ref 990012345678 paid SAR 12.00', '990012345678'),
          contains('accountRef'));
    });

    test('a decimal is never identifier-shaped, however close the cue', () {
      for (final c in const [
        ['Card ending 4412 charged SAR 133.00', '133.00'],
        ['A/C 887766 debited AED 75.50', '75.50'],
        ['مرجع 55821004 خصم 480.00 ج.م', '480.00'],
      ]) {
        expect(isBlocked(c[0], c[1]), isFalse, reason: c[0]);
      }
    });
  });

  group('the traps the layer exists for are still caught', () {
    // The cheapest way to pass everything above is to stop blocking. These
    // guard against a fix that is really just a hole.
    test('available balance', () {
      expect(
          rolesOf('Purchase SAR 40.00. Available balance SAR 9,120.75',
              '9,120.75'),
          contains('balance'));
    });

    test('Arabic balance', () {
      expect(rolesOf('الرصيد المتاح 3,410.20 ر.س', '3,410.20'),
          contains('balance'));
    });

    test('a balance cue may look backwards for Arabic trailing layouts', () {
      expect(rolesOf('840.230 د.ك المتاح', '840.230'), contains('balance'));
    });
  });

  group('determinism and degenerate input', () {
    test('repeated calls agree', () {
      const sms = 'Total charged AED 47.25 REF 88201 balance AED 900.00';
      final a = cueRoles(extractEvidence(sms));
      final b = cueRoles(extractEvidence(sms));
      expect(a.map((k, v) => MapEntry(k, v.toList()..sort())),
          equals(b.map((k, v) => MapEntry(k, v.toList()..sort()))));
    });

    test('no numbers is safe', () {
      expect(cueRoles(extractEvidence('balance available')), isEmpty);
      expect(cueRoles(extractEvidence('')), isEmpty);
    });
  });
}
