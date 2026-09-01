/// PHASE 6 — projecting evidence onto the sanitized text.
///
/// Evidence is extracted from the ORIGINAL message; the model only ever sees
/// the SANITIZED one. Shipping original-coordinate spans alongside sanitized
/// text is the stale-offset bug in its purest form — the ids resolve, the spans
/// look valid, and they describe different characters.
///
/// The property under test is not "projection works" but "projection cannot
/// lie": every surviving node quotes its own text in the transmitted string,
/// and anything touching a redaction is gone rather than approximated.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/engine/privacy/sanitization_edit_map.dart';
import 'package:money_companion/engine/proof/evidence.dart';

const _corpus = <String>[
  'Purchase 1234 5678 9012 3456 SAR 45.00',
  'شراء ببطاقة 1234-5678-9012-3456 بمبلغ 45.00 ر.س',
  'Transfer from 12345678901234 SAR 500.00',
  'IBAN SA0380000000608010167519 amount SAR 12.00',
  'OTP 998877 do not share. Amount SAR 60.00',
  'Call 0512345678 about SAR 20.00',
  'عزيزي أحمد تم خصم 45.00 ر.س',
  '🎉 شراء 45.00 ر.س 🎉 بطاقة 1234567890123456',
  'تم خصم ٤٥٫٧٥٠ د.ك من بطاقتكم ١٢٣٤',
  '   trailing whitespace SAR 10.00   ',
  'شراء 40.00 ر.س. الرصيد المتاح 9,120.75 ر.س',
];

void main() {
  group('projected evidence cannot carry a stale offset', () {
    test('every surviving node quotes its own text in the sanitized string',
        () {
      for (final sms in _corpus) {
        final san = sanitizeWithMap(sms);
        final projected = projectOntoSanitized(extractEvidence(sms), san);
        expect(projected.source, san.text);
        for (final e in projected.items) {
          expect(e.end <= san.text.length, isTrue,
              reason: 'span past end of sanitized text: $sms');
          expect(san.text.substring(e.start, e.end), e.text,
              reason: '${e.id} does not quote itself after projection: $sms');
        }
      }
    });

    test('verifySpans() holds on every projected set', () {
      for (final sms in _corpus) {
        final san = sanitizeWithMap(sms);
        expect(projectOntoSanitized(extractEvidence(sms), san).verifySpans(),
            isTrue,
            reason: sms);
      }
    });

    test('no projected node overlaps a redacted region', () {
      for (final sms in _corpus) {
        final san = sanitizeWithMap(sms);
        final original = extractEvidence(sms);
        final projected = projectOntoSanitized(original, san);
        final keptIds = projected.items.map((e) => e.id).toSet();
        for (final e in original.items) {
          final touches =
              san.redactions.any((r) => r.intersects(e.start, e.end));
          if (touches) {
            expect(keptIds.contains(e.id), isFalse,
                reason: '${e.id} "${e.text}" touched a redaction in "$sms" '
                    'and must have been dropped');
          }
        }
      }
    });
  });

  group('what must be dropped, and what must survive', () {
    test('a PAN node is dropped entirely', () {
      const sms = 'Purchase 1234 5678 9012 3456 SAR 45.00';
      final san = sanitizeWithMap(sms);
      final projected = projectOntoSanitized(extractEvidence(sms), san);
      for (final e in projected.items) {
        expect(e.text.contains('1234'), isFalse,
            reason: 'PAN fragments must not survive projection');
      }
    });

    test('the AMOUNT survives and stays resolvable', () {
      for (final c in const [
        ['Purchase 1234 5678 9012 3456 SAR 45.00', '45.00'],
        ['Transfer from 12345678901234 SAR 500.00', '500.00'],
        ['OTP 998877 do not share. Amount SAR 60.00', '60.00'],
        ['عزيزي أحمد تم خصم 45.00 ر.س', '45.00'],
      ]) {
        final san = sanitizeWithMap(c[0]);
        final projected = projectOntoSanitized(extractEvidence(c[0]), san);
        final amounts = projected
            .ofClass(EvidenceClass.number)
            .where((e) => e.text == c[1]);
        expect(amounts, isNotEmpty,
            reason: 'sanitization must not destroy the amount: ${c[0]}');
      }
    });

    test('currency evidence survives sanitization', () {
      const sms = 'Purchase 1234 5678 9012 3456 SAR 45.00';
      final san = sanitizeWithMap(sms);
      final projected = projectOntoSanitized(extractEvidence(sms), san);
      expect(projected.ofClass(EvidenceClass.currency), isNotEmpty);
    });

    test('dropping is NOT truncation — the two stay distinguishable', () {
      // `exceedsNodeCap` means "the envelope was too small". Redaction is a
      // different failure and must not be reported as that one.
      const sms = 'Purchase 1234 5678 9012 3456 SAR 45.00';
      final san = sanitizeWithMap(sms);
      final projected = projectOntoSanitized(extractEvidence(sms), san);
      expect(projected.exceedsNodeCap, isFalse);
    });
  });

  group('adversarial encodings survive projection intact', () {
    test('emoji do not desynchronise projected spans', () {
      const sms = '🎉 شراء 45.00 ر.س 🎉 بطاقة 1234567890123456';
      final san = sanitizeWithMap(sms);
      final projected = projectOntoSanitized(extractEvidence(sms), san);
      expect(projected.verifySpans(), isTrue);
      expect(projected.ofClass(EvidenceClass.number).any((e) => e.text == '45.00'),
          isTrue);
    });

    test('Arabic-Indic digits project exactly', () {
      const sms = 'تم خصم ٤٥٫٧٥٠ د.ك من بطاقتكم ١٢٣٤';
      final san = sanitizeWithMap(sms);
      final projected = projectOntoSanitized(extractEvidence(sms), san);
      expect(projected.verifySpans(), isTrue);
    });

    test('a leading trim shifts every span and still verifies', () {
      const sms = '   trailing whitespace SAR 10.00   ';
      final san = sanitizeWithMap(sms);
      final projected = projectOntoSanitized(extractEvidence(sms), san);
      expect(projected.verifySpans(), isTrue);
      expect(projected.ofClass(EvidenceClass.number).any((e) => e.text == '10.00'),
          isTrue);
    });
  });
}
