// PHASE 2 — payload budget.
//
// The production endpoint enforces MAX_BODY_BYTES = 8192
// (supabase/functions/parse-sms/index.ts). That cap is NOT raised to make a
// verbose contract fit; the evidence layer is designed to be small instead.
//
// Target: serialized evidence envelope p99 <= 3 KB, so the later request has
// comfortable headroom for the sanitized text and the JSON wrapper rather than
// scraping under the limit.
//
// These tests measure the ENCODED UTF-8 byte length of the real envelope, not a
// character count — Arabic is multi-byte and a char count would understate the
// payload by roughly half.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/engine/proof/evidence.dart';

/// Encoded size of the evidence envelope exactly as it would be serialised.
int _bytes(String sms) =>
    utf8.encode(jsonEncode(extractEvidence(sms).toJson())).length;

/// The server cap the whole design must live inside.
const int kServerMaxBodyBytes = 8192;

/// Phase-2 self-imposed budget for the evidence envelope alone.
const int kEvidenceBudgetBytes = 3072;

void main() {
  group('payload budget vs MAX_BODY_BYTES = 8192', () {
    test('ordinary bank SMS is far inside budget', () {
      const sms = 'تم خصم 125.75 ر.س من بطاقتكم ****1234 لدى STARBUCKS';
      final n = _bytes(sms);
      expect(n, lessThan(kEvidenceBudgetBytes), reason: '$n bytes');
    });

    test('long Arabic SMS with many cues stays inside budget', () {
      const sms =
          'عميلنا العزيز، نفيدكم بأنه تم خصم مبلغ 1,250.75 ر.س من حسابكم '
          'المنتهي بـ 4412 وذلك لعملية شراء تمت لدى متجر التميمي المركزي '
          'بتاريخ 15/08/2026 الساعة 14:32، وقد بلغت الرسوم 5.25 ر.س '
          'والضريبة المضافة 1.88 ر.س، ليصبح الرصيد المتاح في حسابكم '
          '12,340.55 ر.س. الرقم المرجعي للعملية 2291043355. '
          'لمزيد من المعلومات يرجى التواصل مع خدمة العملاء.';
      final n = _bytes(sms);
      expect(n, lessThan(kEvidenceBudgetBytes), reason: '$n bytes');
    });

    test('many-number SMS stays inside budget BECAUSE the envelope is bounded',
        () {
      final sb = StringBuffer('تم خصم 100.00 ر.س ');
      for (var i = 0; i < 40; i++) {
        sb.write('${1000 + i}.${(i % 90) + 10} ر.س ');
      }
      final sms = sb.toString();
      final n = _bytes(sms);
      expect(n, lessThan(kEvidenceBudgetBytes),
          reason: 'node cap holds the envelope at $n bytes');
      // and the truncation is REPORTED, not hidden
      final json = extractEvidence(sms).toJson();
      expect(json['tr'], isTrue);
      expect(json['om'], greaterThan(0));
      expect((json['ev'] as List).length, EvidenceSet.maxNodes);
    });

    test('a DENSE 2000-char message — the server MAX_SMS_LENGTH worst case', () {
      // Unbounded, this message produced 287 nodes / ~24 KB — 3x the server
      // request cap. Bounded, it must fit.
      final sb = StringBuffer();
      while (sb.length < 2000) {
        sb.write('تم خصم 1,234.56 ر.س الرصيد 9,876.54 ر.س مرجع 2291043355 ');
      }
      final sms = sb.toString().substring(0, 2000);
      final n = _bytes(sms);
      expect(n, lessThan(kEvidenceBudgetBytes), reason: '$n bytes');
      expect(extractEvidence(sms).exceedsNodeCap, isTrue,
          reason: 'caller can detect incompleteness BEFORE serialising');
    });

    test('many-currency SMS', () {
      const sms = 'USD 20.00 / AED 73.46 / SAR 75.00 / EGP 980.00 / '
          'KWD 6.150 / BHD 7.540 / OMR 7.700 / QAR 72.80';
      final n = _bytes(sms);
      expect(n, lessThan(kEvidenceBudgetBytes), reason: '$n bytes');
    });

    test('a pathological message far beyond the server SMS cap still fits', () {
      final sb = StringBuffer();
      for (var i = 0; i < 120; i++) {
        sb.write('تم خصم ${i + 1}٬${(i * 7) % 900 + 100}٫${(i % 90) + 10} د.ك '
            'الرصيد المتاح ${i * 3}.${i % 100} د.ك ');
      }
      final n = _bytes(sb.toString());
      expect(n, lessThan(kServerMaxBodyBytes),
          reason: 'bounded envelope ⇒ $n bytes, under the 8192 server cap');
      expect(n, lessThan(kEvidenceBudgetBytes),
          reason: 'and under the Phase-2 budget too');
    });

    test('an untruncated set carries NO truncation marker', () {
      final json = extractEvidence('تم خصم 125.75 ر.س').toJson();
      expect(json.containsKey('tr'), isFalse);
      expect(json.containsKey('om'), isFalse);
    });

    test('budget headroom is reported, not merely asserted', () {
      const samples = [
        'تم خصم 125.75 ر.س لدى STARBUCKS',
        'Purchase SAR 9,500.00 at NOON. Avl bal SAR 12,300.45',
        'تم خصم 12.450 د.ك رسوم 0.500 د.ك الرصيد المتاح 840.230 د.ك',
      ];
      final sizes = [for (final s in samples) _bytes(s)];
      final worst = sizes.reduce((a, b) => a > b ? a : b);
      // ignore: avoid_print
      print('evidence envelope bytes: $sizes (worst $worst / '
          'budget $kEvidenceBudgetBytes / server cap $kServerMaxBodyBytes)');
      expect(worst, lessThan(kEvidenceBudgetBytes));
    });
  });
}
