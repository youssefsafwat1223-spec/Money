// PHASE 2 — minimal evidence layer.
//
// No AI anywhere in this file. Every assertion is about deterministic
// extraction from a literal string.
//
// The load-bearing test is `complete-token boundaries`: if a maximal numeric
// token could ever be split, a later phase could offer `9.5` or `500.00` as a
// financial candidate drawn from `9,500.00`, which is exactly the fabrication
// class the proof architecture exists to make impossible.

import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/engine/proof/evidence.dart';

Evidence? _num(EvidenceSet s, String text) {
  for (final e in s.ofClass(EvidenceClass.number)) {
    if (e.text == text) return e;
  }
  return null;
}

List<String> _numTexts(EvidenceSet s) =>
    [for (final e in s.ofClass(EvidenceClass.number)) e.text];

List<String> _isos(EvidenceSet s) =>
    [for (final e in s.ofClass(EvidenceClass.currency)) e.iso!];

void main() {
  group('span provenance', () {
    test('every span reproduces its own text from the source', () {
      const sources = [
        'تم خصم 125.75 ر.س لدى ستاربكس',
        'Purchase SAR 9,500.00 at NOON. Avl bal SAR 12,300.45',
        'تم خصم ٦٣٢٫١٢٤ ر.ع من حسابك',
        'Fee 5.25 KWD, balance 840.230 KWD',
      ];
      for (final src in sources) {
        final set = extractEvidence(src);
        expect(set.verifySpans(), isTrue, reason: src);
      }
    });

    test('UTF-16 offsets survive emoji before the money', () {
      // The emoji is a surrogate pair: 2 UTF-16 code units. Dart substring and
      // JS string indexing agree on that, which is why the convention is
      // declared as UTF-16 rather than "characters".
      const src = '🎉 تم خصم 125.75 ر.س';
      final set = extractEvidence(src);
      expect(set.verifySpans(), isTrue);
      final n = _num(set, '125.75')!;
      expect(src.substring(n.start, n.end), '125.75');
      expect(src.codeUnitAt(0), greaterThanOrEqualTo(0xD800),
          reason: 'confirms the leading char really is a surrogate pair');
    });

    test('astral-plane characters do not shift later spans', () {
      const src = '𝕏 balance 840.230 KWD';
      final set = extractEvidence(src);
      expect(set.verifySpans(), isTrue);
      expect(_num(set, '840.230'), isNotNull);
    });
  });

  group('complete-token boundaries — the fabrication guard', () {
    test('a grouped amount is ONE token and exposes no fragments', () {
      final set = extractEvidence('Purchase SAR 9,500.00 at NOON');
      expect(_numTexts(set), ['9,500.00']);
      // The fragments that a naive scanner would leak:
      expect(_num(set, '9'), isNull);
      expect(_num(set, '500.00'), isNull);
      expect(_num(set, '9.5'), isNull);
      expect(_num(set, '500'), isNull);
    });

    test('3-decimal amounts keep every digit', () {
      final set = extractEvidence('تم خصم 45.750 د.ك');
      final n = _num(set, '45.750')!;
      expect(n.canonical, '45.750');
      expect(n.decimals, 3);
      expect(_num(set, '45.75'), isNull,
          reason: 'a truncated form must not exist as evidence');
    });

    test('2-decimal and integer amounts', () {
      expect(_num(extractEvidence('SAR 123.45'), '123.45')!.decimals, 2);
      expect(_num(extractEvidence('SAR 123'), '123')!.decimals, 0);
    });

    test('trailing sentence punctuation is not part of the number', () {
      final set = extractEvidence('Paid 45.750. Thank you');
      expect(_numTexts(set), ['45.750']);
    });

    test('multiple numbers stay separate and ordered', () {
      final set = extractEvidence(
          'تم خصم 12.450 د.ك رسوم 0.500 د.ك الرصيد المتاح 840.230 د.ك');
      expect(_numTexts(set), ['12.450', '0.500', '840.230']);
      final ids = [for (final e in set.ofClass(EvidenceClass.number)) e.id];
      expect(ids, ['NUMBER_1', 'NUMBER_2', 'NUMBER_3']);
    });

    test('reference and card distractors are captured as numbers, not hidden',
        () {
      final set = extractEvidence(
          'Purchase SAR 75.50 at TALABAT ref 2291043355 card ending 4412');
      final texts = _numTexts(set);
      expect(texts, contains('75.50'));
      expect(texts, contains('2291043355'));
      expect(texts, contains('4412'));
      // Phase 2 only EXTRACTS. Deciding which of these may be money is the
      // Phase 3 checker's job, and it must be able to see all of them.
    });
  });

  group('Arabic-Indic digits and separators', () {
    test('Arabic-Indic digits normalise to a canonical value', () {
      final set = extractEvidence('تم خصم ٦٣٢٫١٢٤ ر.ع من حسابك');
      final n = _num(set, '٦٣٢٫١٢٤')!;
      expect(n.canonical, '632.124',
          reason: 'canonical form comes from the existing money normalizer');
      expect(n.decimals, 3);
      expect(set.verifySpans(), isTrue,
          reason: 'text stays the ORIGINAL Arabic-Indic substring');
    });

    test('Arabic thousands separator is grouped, not a decimal point', () {
      final set = extractEvidence('الرصيد ٩٬٥٠٠٫٠٠ ر.س');
      final n = _num(set, '٩٬٥٠٠٫٠٠')!;
      expect(n.canonical, '9500.00');
    });

    test('an AMBIGUOUS token is evidence with NO readable amount', () {
      // "12,50" is rejected by the existing normalizer as ambiguous. The node
      // still exists (so the checker can see it) but carries no canonical
      // value, so it can never be read as money.
      final set = extractEvidence('Amount 12,50 SAR');
      final n = _num(set, '12,50');
      expect(n, isNotNull);
      expect(n!.canonical, isNull,
          reason: 'refusing is safer than guessing 12.50 or 1250');
    });
  });

  group('currency evidence', () {
    test('Arabic aliases map to ISO with the right scale', () {
      const cases = {
        'تم خصم 10.00 ج.م': ('EGP', 2),
        'تم خصم 10.00 ر.س': ('SAR', 2),
        'تم خصم 10.000 د.ك': ('KWD', 3),
        'تم خصم 10.000 د.ب': ('BHD', 3),
        'تم خصم 10.000 ر.ع': ('OMR', 3),
        'تم خصم 10.00 ر.ق': ('QAR', 2),
      };
      cases.forEach((src, expected) {
        final set = extractEvidence(src);
        final c = set.ofClass(EvidenceClass.currency).first;
        expect(c.iso, expected.$1, reason: src);
        expect(c.scale, expected.$2, reason: src);
      });
    });

    test('Latin ISO codes are recognised', () {
      expect(_isos(extractEvidence('Purchase SAR 125.75')), ['SAR']);
      expect(_isos(extractEvidence('Charged USD 20.00')), ['USD']);
    });

    test('multi-currency keeps BOTH legs', () {
      final set = extractEvidence('Purchase USD 20.00, local amount AED 73.46');
      expect(_isos(set), ['USD', 'AED']);
      expect(_numTexts(set), ['20.00', '73.46']);
    });

    test('no currency in the message yields no currency evidence', () {
      expect(extractEvidence('Purchase 125.75 at NOON').ofClass(
        EvidenceClass.currency,
      ), isEmpty);
    });

    test('the layer never invents a currency', () {
      final set = extractEvidence('Purchase 100.00 at SHOP');
      expect(set.ofClass(EvidenceClass.currency), isEmpty);
    });
  });

  group('state cues', () {
    test('declined / pending / otp / promotional / balance are detected', () {
      expect(
        extractEvidence('Transaction DECLINED for SAR 450.00')
            .ofClass(EvidenceClass.stateCue)
            .map((e) => e.stateCue),
        contains(StateCueKind.declined),
      );
      expect(
        extractEvidence('عملية معلقة بقيمة 33.750 د.ب')
            .ofClass(EvidenceClass.stateCue)
            .map((e) => e.stateCue),
        contains(StateCueKind.pending),
      );
      expect(
        extractEvidence('Your OTP is 482910, do not share')
            .ofClass(EvidenceClass.stateCue)
            .map((e) => e.stateCue),
        contains(StateCueKind.otp),
      );
      expect(
        extractEvidence('عرض خاص! خصومات حتى 50')
            .ofClass(EvidenceClass.stateCue)
            .map((e) => e.stateCue),
        contains(StateCueKind.promotional),
      );
      expect(
        extractEvidence('الرصيد المتاح 840.230 د.ك')
            .ofClass(EvidenceClass.stateCue)
            .map((e) => e.stateCue),
        contains(StateCueKind.balanceOnly),
      );
    });

    test('a cue is lexical evidence, not a conclusion', () {
      // "balance" appears, but so does a completed purchase. Phase 2 reports
      // both; it does not decide.
      final set = extractEvidence(
          'تم خصم 12.450 د.ك لدى ABC والرصيد المتاح 840.230 د.ك');
      final kinds =
          set.ofClass(EvidenceClass.stateCue).map((e) => e.stateCue).toSet();
      expect(kinds, contains(StateCueKind.balanceOnly));
      expect(kinds, contains(StateCueKind.completed));
    });
  });

  group('direction cues (D1 only)', () {
    test('outgoing lexical cue', () {
      final cues = extractEvidence('تم خصم 125.75 ر.س')
          .ofClass(EvidenceClass.directionCue);
      expect(cues.map((e) => e.directionPolarity),
          contains(DirectionCuePolarity.outgoing));
    });

    test('incoming lexical cue', () {
      final cues = extractEvidence('تم إيداع راتب 5000.00 ر.س')
          .ofClass(EvidenceClass.directionCue);
      expect(cues.map((e) => e.directionPolarity),
          contains(DirectionCuePolarity.incoming));
    });

    test('contradictory cues are BOTH reported — Phase 3 resolves them', () {
      final cues = extractEvidence('تم خصم مبلغ ثم تم إيداع مبلغ آخر')
          .ofClass(EvidenceClass.directionCue)
          .map((e) => e.directionPolarity)
          .toSet();
      expect(cues, containsAll([
        DirectionCuePolarity.outgoing,
        DirectionCuePolarity.incoming,
      ]));
    });

    test('no cue means no direction evidence — never a guess', () {
      expect(
        extractEvidence('SAR 100.00 XYZ').ofClass(EvidenceClass.directionCue),
        isEmpty,
      );
    });
  });

  group('determinism and versioning', () {
    test('extraction is a pure function', () {
      const src = 'تم خصم 12.450 د.ك رسوم 0.500 د.ك';
      final a = extractEvidence(src).toJson().toString();
      final b = extractEvidence(src).toJson().toString();
      expect(a, b);
    });

    test('the envelope is versioned from day one', () {
      final json = extractEvidence('SAR 1.00').toJson();
      expect(json['v'], EvidenceSet.version);
      expect(json.containsKey('ev'), isTrue);
    });

    test('the envelope does NOT carry the raw source', () {
      final json = extractEvidence('تم خصم 12.450 د.ك لدى SECRETSHOP').toJson();
      expect(json.toString(), isNot(contains('SECRETSHOP')),
          reason: 'raw message text is not part of the evidence envelope');
    });

    test('empty and number-free input are safe', () {
      expect(extractEvidence('').items, isEmpty);
      expect(extractEvidence('مرحبا').ofClass(EvidenceClass.number), isEmpty);
    });
  });
}
