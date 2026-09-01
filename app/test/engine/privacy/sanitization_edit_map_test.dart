/// PHASE 6 — the sanitization edit map security gate.
///
/// Evidence spans are computed on the ORIGINAL message; the text that leaves
/// the device is the SANITIZED one. Sanitization changes lengths, so a span
/// carried across unchanged is a STALE OFFSET — still two well-formed integers,
/// now pointing at different characters. A proof built on it would be a proof
/// about the wrong part of the message, and nothing downstream could tell.
///
/// The gate has three obligations and these tests are organised around them:
///   1. the sanitized TEXT must not change (equivalence with the shipped
///      sanitizer), or Phase 6 would be a privacy change smuggled in as a
///      plumbing change;
///   2. spans that touch redacted text must be DROPPED, never remapped;
///   3. surviving spans must still quote their own text — asserted, not assumed.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/engine/models/transaction_type.dart';
import 'package:money_companion/engine/privacy/sanitization_edit_map.dart';
import 'package:money_companion/engine/privacy/sms_sanitizer.dart';

/// Messages spanning every redaction class plus the adversarial encodings.
const _corpus = <String>[
  // ── plain, nothing to redact ────────────────────────────────────────────
  'شراء بمبلغ 45.00 ر.س لدى مطعم البيك',
  'Purchase SAR 45.00 at PANDA',
  // ── PAN / card ──────────────────────────────────────────────────────────
  'Purchase 1234 5678 9012 3456 SAR 45.00',
  'شراء ببطاقة 1234-5678-9012-3456 بمبلغ 45.00 ر.س',
  // ── account / IBAN-like long digit runs ─────────────────────────────────
  'Transfer from 12345678901234 SAR 500.00',
  'حساب 98765432101234567890 خصم 75.50 ر.س',
  'IBAN SA0380000000608010167519 amount SAR 12.00',
  // ── phone ───────────────────────────────────────────────────────────────
  'Call 0512345678 about SAR 20.00',
  'اتصل 01012345678 بخصوص 30.00 ج.م',
  'Contact +966512345678 re AED 15.00',
  // ── OTP / reference ─────────────────────────────────────────────────────
  'رمز التحقق 4471 لعملية بمبلغ 250.00 ر.س',
  'OTP 998877 do not share. Amount SAR 60.00',
  'Purchase SAR 66.00 REF 4471902',
  'Your verification code is 123456',
  'رمز التحقق هو 4471 والمبلغ 250.00 ر.س',
  'IBAN SA0380000000608010167519 amount SAR 12.00',
  'Transfer to GB29NWBK60161331926819 SAR 90.00',
  // ── beneficiary / greeting ──────────────────────────────────────────────
  'تحويل 750.00 ر.س إلى: محمد أحمد',
  'Transfer SAR 300.00 To: John Smith',
  'عزيزي أحمد تم خصم 45.00 ر.س',
  'عزيزي 12345678901 تم خصم 45.00 ر.س', // the sequential-order trap
  // ── adversarial Unicode ─────────────────────────────────────────────────
  '🎉 شراء 45.00 ر.س 🎉 بطاقة 1234567890123456',
  'تم خصم ٤٥٫٧٥٠ د.ك من بطاقتكم ١٢٣٤',
  '‏شراء‎ 45.00 ر.س‏ 0512345678',
  '👨‍👩‍👧‍👦 family plan SAR 99.00 card 1234 5678 9012 3456',
  '   leading and trailing whitespace SAR 10.00   ',
  'مبلغ 45.00 ر.س\n\nحساب 12345678901\n\nشكرا',
];

void main() {
  group('1. the sanitized text is unchanged — equivalence with the shipped sanitizer',
      () {
    test('byte-identical output for every corpus message', () {
      for (final sms in _corpus) {
        for (final t in <TransactionType?>[
          null,
          TransactionType.payment,
          TransactionType.transfer,
          TransactionType.income,
          TransactionType.withdrawal,
        ]) {
          expect(sanitizeWithMap(sms, detectedType: t).text,
              SmsSanitizer.sanitize(sms, detectedType: t),
              reason: 'edit map must not alter WHAT is redacted, only record '
                  'where it went — message: $sms, type: $t');
        }
      }
    });

    test('the sequential-ordering trap is preserved', () {
      // `عزيزي 12345678901` → the account pass fires first, then the greeting
      // pass matches its OUTPUT and removes the whole thing. A single-pass
      // rewrite would redact a different span.
      const sms = 'عزيزي 12345678901 تم خصم 45.00 ر.س';
      expect(sanitizeWithMap(sms).text, SmsSanitizer.sanitize(sms));
    });

    test('sanitization is deterministic', () {
      for (final sms in _corpus) {
        expect(sanitizeWithMap(sms).text, sanitizeWithMap(sms).text);
      }
    });
  });

  group('2. redacted and intersecting spans are DROPPED, never remapped', () {
    test('a span inside a redaction does not survive', () {
      const sms = 'Purchase 1234 5678 9012 3456 SAR 45.00';
      final s = sanitizeWithMap(sms);
      final panStart = sms.indexOf('1234 5678');
      expect(s.mapSpan(panStart, panStart + 19), isNull,
          reason: 'the PAN itself must not map anywhere');
      expect(s.mapOffset(panStart), isNull);
    });

    test('a span that merely TOUCHES a redaction is dropped', () {
      const sms = 'Purchase 1234 5678 9012 3456 SAR 45.00';
      final s = sanitizeWithMap(sms);
      final panStart = sms.indexOf('1234');
      // Straddles the boundary: one character of real text plus the PAN.
      expect(s.mapSpan(panStart - 1, panStart + 4), isNull);
    });

    test('a span STRADDLING a redaction is dropped, not silently shortened', () {
      const sms = 'A 1234567890123 B';
      final s = sanitizeWithMap(sms);
      expect(s.mapSpan(0, sms.length), isNull,
          reason: 'no partial or "nearest offset" remapping is permitted');
    });

    test('surviving spans on the far side of a redaction still map exactly', () {
      const sms = 'Purchase 1234 5678 9012 3456 SAR 45.00';
      final s = sanitizeWithMap(sms);
      final amt = sms.indexOf('45.00');
      final mapped = s.mapSpan(amt, amt + 5);
      expect(mapped, isNotNull);
      expect(s.text.substring(mapped!.$1, mapped.$2), '45.00');
      expect(mapped.$1, isNot(amt), reason: 'the offset genuinely shifted');
    });
  });

  group('3. no stale offsets — every surviving span quotes its own text', () {
    test('exhaustive: every single-character span in every message', () {
      for (final sms in _corpus) {
        final s = sanitizeWithMap(sms);
        for (var i = 0; i < sms.length; i++) {
          final m = s.mapOffset(i);
          if (m == null) continue;
          expect(s.text.codeUnitAt(m), sms.codeUnitAt(i),
              reason: 'offset $i of "$sms" maps to the wrong character');
        }
      }
    });

    test('exhaustive: every surviving multi-character span verifies', () {
      for (final sms in _corpus) {
        final s = sanitizeWithMap(sms);
        for (var i = 0; i < sms.length; i++) {
          for (var j = i + 1; j <= sms.length && j <= i + 12; j++) {
            if (s.mapSpan(i, j) != null) {
              expect(s.verifySpan(i, j), isTrue,
                  reason: 'span [$i,$j) of "$sms" mapped but does not quote '
                      'its own text');
            }
          }
        }
      }
    });

    test('out-of-range and inverted spans are refused', () {
      final s = sanitizeWithMap('Purchase SAR 45.00');
      expect(s.mapSpan(-1, 3), isNull);
      expect(s.mapSpan(3, 3), isNull);
      expect(s.mapSpan(5, 4), isNull);
      expect(s.mapSpan(0, 9999), isNull);
      expect(s.mapOffset(9999), isNull);
    });
  });

  group('4. privacy coverage — the classes that must not survive', () {
    void expectRedacted(String sms, String secret, String label) {
      final s = sanitizeWithMap(sms);
      expect(s.text.contains(secret), isFalse,
          reason: '$label leaked into the sanitized text: $sms');
      final at = sms.indexOf(secret);
      expect(s.mapSpan(at, at + secret.length), isNull,
          reason: '$label still had a mappable span');
    }

    test('PAN', () {
      expectRedacted('Purchase 1234 5678 9012 3456 SAR 45.00',
          '1234 5678 9012 3456', 'PAN');
      expectRedacted('شراء ببطاقة 1234-5678-9012-3456 بمبلغ 45.00 ر.س',
          '1234-5678-9012-3456', 'PAN with dashes');
    });

    test('account / long digit runs', () {
      expectRedacted('Transfer from 12345678901234 SAR 500.00',
          '12345678901234', 'account');
      expectRedacted('حساب 98765432101234567890 خصم 75.50 ر.س',
          '98765432101234567890', 'long account');
    });

    test('phone numbers', () {
      expectRedacted('Call 0512345678 about SAR 20.00', '0512345678', 'SA phone');
      expectRedacted(
          'اتصل 01012345678 بخصوص 30.00 ج.م', '01012345678', 'EG phone');
      expectRedacted(
          'Contact +966512345678 re AED 15.00', '+966512345678', 'intl phone');
    });

    test('beneficiary names are stripped for non-purchase types', () {
      final s = sanitizeWithMap('تحويل 750.00 ر.س إلى: محمد أحمد',
          detectedType: TransactionType.transfer);
      expect(s.text.contains('محمد'), isFalse);
    });

    test('OTP codes are redacted, cue-anchored', () {
      expectRedacted('OTP 998877 do not share. Amount SAR 60.00', '998877',
          'OTP');
      expectRedacted('Your verification code is 123456', '123456',
          'verification code');
      expectRedacted('رمز التحقق هو 4471 والمبلغ 250.00 ر.س', '4471',
          'Arabic OTP');
    });

    test('OTP redaction NEVER destroys an amount', () {
      // A shape-based rule would eat these. The cue anchor is what prevents it.
      for (final c in const [
        ['Purchase SAR 1234.00 at STORE', '1234.00'],
        ['شراء 45.00 ر.س لدى مطعم', '45.00'],
        ['Amount 9999 SAR', '9999'],
      ]) {
        final s = sanitizeWithMap(c[0]);
        expect(s.text.contains(c[1]), isTrue,
            reason: 'a bare digit run with NO otp cue must survive: ${c[0]}');
      }
    });

    test('IBANs are redacted — the digit rule cannot catch them', () {
      expectRedacted('IBAN SA0380000000608010167519 amount SAR 12.00',
          'SA0380000000608010167519', 'Saudi IBAN');
      expectRedacted('Transfer to GB29NWBK60161331926819 SAR 90.00',
          'GB29NWBK60161331926819', 'UK IBAN');
    });

    test('masked card suffixes are deliberately KEPT', () {
      // Documented as non-PII by the sanitizer, and the proof layer relies on
      // them for the accountRef role.
      final s = sanitizeWithMap('بطاقة ****3321 مبلغ 260.00 ر.س');
      expect(s.text.contains('****3321'), isTrue);
    });

    test('greeting names are stripped', () {
      final s = sanitizeWithMap('عزيزي أحمد تم خصم 45.00 ر.س');
      expect(s.text.contains('أحمد'), isFalse);
    });

    test('the AMOUNT survives every redaction class', () {
      // The gate must not be achieved by destroying the thing being proven.
      for (final c in const [
        ['Purchase 1234 5678 9012 3456 SAR 45.00', '45.00'],
        ['Transfer from 12345678901234 SAR 500.00', '500.00'],
        ['Call 0512345678 about SAR 20.00', '20.00'],
        ['عزيزي أحمد تم خصم 45.00 ر.س', '45.00'],
      ]) {
        final s = sanitizeWithMap(c[0]);
        expect(s.text.contains(c[1]), isTrue,
            reason: 'the amount must survive: ${c[0]}');
        final at = c[0].indexOf(c[1]);
        expect(s.verifySpan(at, at + c[1].length), isTrue,
            reason: 'the amount span must remain provable: ${c[0]}');
      }
    });
  });

  group('5. adversarial Unicode — emoji, Arabic-Indic digits, RTL marks', () {
    test('emoji before the amount do not desynchronise offsets', () {
      const sms = '🎉 شراء 45.00 ر.س 🎉 بطاقة 1234567890123456';
      final s = sanitizeWithMap(sms);
      final at = sms.indexOf('45.00');
      expect(s.verifySpan(at, at + 5), isTrue);
      expect(s.text.contains('1234567890123456'), isFalse);
    });

    test('a ZWJ emoji sequence keeps spans exact', () {
      const sms = '👨‍👩‍👧‍👦 family plan SAR 99.00 card 1234 5678 9012 3456';
      final s = sanitizeWithMap(sms);
      final at = sms.indexOf('99.00');
      expect(s.verifySpan(at, at + 5), isTrue);
      expect(s.text.contains('1234 5678 9012 3456'), isFalse);
    });

    test('Arabic-Indic digits are preserved and mappable', () {
      const sms = 'تم خصم ٤٥٫٧٥٠ د.ك من بطاقتكم ١٢٣٤';
      final s = sanitizeWithMap(sms);
      final at = sms.indexOf('٤٥٫٧٥٠');
      expect(s.verifySpan(at, at + '٤٥٫٧٥٠'.length), isTrue,
          reason: 'Arabic-Indic digits are not ASCII and must still map');
    });

    test('RTL/LTR marks do not shift the map', () {
      const sms = '‏شراء‎ 45.00 ر.س‏ 0512345678';
      final s = sanitizeWithMap(sms);
      final at = sms.indexOf('45.00');
      expect(s.verifySpan(at, at + 5), isTrue);
      expect(s.text.contains('0512345678'), isFalse);
    });

    test('leading/trailing trim is modelled, not ignored', () {
      const sms = '   leading and trailing whitespace SAR 10.00   ';
      final s = sanitizeWithMap(sms);
      expect(s.text, SmsSanitizer.sanitize(sms));
      final at = sms.indexOf('10.00');
      expect(s.verifySpan(at, at + 5), isTrue,
          reason: 'the trim shifts every offset left and must be recorded');
      expect(s.mapOffset(0), isNull, reason: 'trimmed whitespace is gone');
    });

    test('an empty message is safe', () {
      final s = sanitizeWithMap('');
      expect(s.text, '');
      expect(s.mapOffset(0), isNull);
      expect(s.mapSpan(0, 1), isNull);
    });
  });
}
