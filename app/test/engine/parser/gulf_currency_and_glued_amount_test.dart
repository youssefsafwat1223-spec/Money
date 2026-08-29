import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/domain/finance/currency_scale.dart';
import 'package:money_companion/domain/finance/money_input.dart';
import 'package:money_companion/engine/parser/bank_profile.dart';
import 'package:money_companion/engine/parser/normalizer.dart';
import 'package:money_companion/engine/parser/parser_engine.dart';

/// Regression tests for two money-correctness defects found during the
/// on-device model bake-off (research/sms_model_lab).
///
/// Both were found by running Mali's real engine over adversarial Gulf-market
/// messages, not by reading the code, so both get a test that fails on the
/// pre-fix engine.
void main() {
  const engine = ParserEngine();

  group('BUG 1 — Gulf currency abbreviations resolved to SAR', () {
    // `تم خصم 0.750 د.ب` parsed as 0.750 **SAR**. Two things were wrong:
    // the currency, and — because BHD has scale 3 while SAR has scale 2 —
    // the resulting pair was not even representable as canonical Money.
    test('د.ك resolves to KWD, not the SAR default', () {
      expect(Normalizer.normalizeCurrencyTokens('12.450 د.ك'), '12.450 KWD');
    });

    test('د.ب resolves to BHD, not the SAR default', () {
      expect(Normalizer.normalizeCurrencyTokens('0.750 د.ب'), '0.750 BHD');
    });

    test('ر.ع resolves to OMR and is not swallowed by the bare ريال rule', () {
      expect(Normalizer.normalizeCurrencyTokens('123.456 ر.ع'), '123.456 OMR');
    });

    test('ر.ق resolves to QAR', () {
      expect(Normalizer.normalizeCurrencyTokens('99.00 ر.ق'), '99.00 QAR');
    });

    test('the bare ريال fallback still means SAR', () {
      expect(Normalizer.normalizeCurrencyTokens('45 ريال'), '45 SAR');
    });

    test('every GCC abbreviation maps to a currency with a registered scale',
        () {
      for (final entry in const {
        'د.ك': 'KWD',
        'د.ب': 'BHD',
        'ر.ع': 'OMR',
        'ر.ق': 'QAR',
        'د.إ': 'AED',
        'ر.س': 'SAR',
      }.entries) {
        final code =
            Normalizer.normalizeCurrencyTokens('1 ${entry.key}').split(' ').last;
        expect(code, entry.value);
        expect(isSupportedCurrency(code), isTrue,
            reason: '$code has no registered minor-unit scale');
      }
    });

    test('end-to-end: a BHD debit is not read as SAR', () {
      final result = engine.parse(
        'تم خصم 0.750 د.ب من حسابكم لدى كوفي بيت الرياض',
        senderId: 'NBB',
        bankProfiles: BankProfiles.all,
      );
      expect(result.isTransaction, isTrue);
      expect(result.transaction!.currency, 'BHD');
      expect(result.transaction!.amountText, '0.750');
    });

    test('end-to-end: a KWD debit is not read as SAR', () {
      final result = engine.parse(
        'تم خصم 12.450 د.ك من بطاقتكم ****1234 لدى ABC MARKET '
        'والمتاح 840.230 د.ك',
        senderId: 'NBK',
        bankProfiles: BankProfiles.all,
      );
      expect(result.isTransaction, isTrue);
      expect(result.transaction!.currency, 'KWD');
      expect(result.transaction!.amountText, '12.450');
    });

    test('the parsed pair is always constructible as canonical Money', () {
      // This is the property the bug actually violated: 3 fractional digits
      // against a 2-digit currency. parseLocalizedMoney rejects over-precision,
      // so the wrong currency did not corrupt data — it blocked the capture.
      for (final sms in const [
        'تم خصم 0.750 د.ب من حسابكم لدى متجر',
        'تم خصم 12.450 د.ك من حسابكم لدى متجر',
        'تم خصم 123.456 ر.ع من حسابكم لدى متجر',
      ]) {
        final parsed =
            engine.parse(sms, bankProfiles: BankProfiles.all).transaction;
        expect(parsed, isNotNull, reason: sms);
        final txn = parsed!;
        expect(
          () => parseLocalizedMoney(txn.amountText!, txn.currency),
          returnsNormally,
          reason: '${txn.amountText} ${txn.currency} must be canonical Money',
        );
      }
    });
  });

  group('BUG 2 — currency glued to the amount truncated the value', () {
    // `شراء SAR129.90 لدى كارفور` extracted `90`. There is no word boundary
    // between `R` and `1`, so the amount matcher's `\b` anchored after the
    // decimal point instead.
    test('separateGluedCurrency splits a leading code', () {
      expect(Normalizer.separateGluedCurrency('SAR129.90'), 'SAR 129.90');
      expect(Normalizer.separateGluedCurrency('AED45.00'), 'AED 45.00');
      expect(Normalizer.separateGluedCurrency('KWD12.450'), 'KWD 12.450');
    });

    test('separateGluedCurrency splits a trailing code', () {
      expect(Normalizer.separateGluedCurrency('129.90SAR'), '129.90 SAR');
    });

    test('it leaves already-separated text untouched', () {
      expect(Normalizer.separateGluedCurrency('SAR 129.90'), 'SAR 129.90');
    });

    test('it does not split a code embedded in a longer word', () {
      // `USAR123` must not become `US AR123`; the guard is the letter lookbehind.
      expect(Normalizer.separateGluedCurrency('USAR123'), 'USAR123');
    });

    test('it does not turn reference numbers into amounts', () {
      // The rejected alternative fix — loosening the amount regex's `\b` —
      // would have made `REF123456` matchable as money. This must not happen.
      expect(Normalizer.separateGluedCurrency('REF123456'), 'REF123456');
    });

    test('end-to-end: glued SAR amount is captured whole, not fragmented', () {
      final result = engine.parse(
        'شراء SAR129.90 لدى كارفور المتاح SAR1,203.44',
        senderId: 'ALRAJHI',
        bankProfiles: BankProfiles.all,
      );
      expect(result.isTransaction, isTrue);
      expect(result.transaction!.amountText, '129.90',
          reason: 'must not be the "90" fragment');
      expect(result.transaction!.currency, 'SAR');
    });

    test('end-to-end: glued KWD keeps all three decimals', () {
      final result = engine.parse(
        'Purchase KWD12.450 at ABC MARKET',
        senderId: 'NBK',
        bankProfiles: BankProfiles.all,
      );
      expect(result.isTransaction, isTrue);
      expect(result.transaction!.amountText, '12.450');
      expect(result.transaction!.currency, 'KWD');
    });
  });
}
