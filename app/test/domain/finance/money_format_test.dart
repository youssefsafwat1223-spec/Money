import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/domain/finance/currency_scale.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/domain/finance/money_format.dart';

/// R-8 — money presentation must be exact and currency-correct.
///
/// The domain remediation removed `double` from storage and transport. The UI
/// was still funnelling every displayed amount through `Money.toDouble()`, which
/// is documented as approximate beyond 2^53 minor units. Formatting is
/// presentation, but presenting a wrong number is still presenting a wrong
/// number — and it is the reported symptom in UX-035.
///
/// R-8a — there must be exactly ONE currency-scale table. There were two, and
/// they had already drifted.
void main() {
  group('R-8a — display scale comes from the canonical registry', () {
    test('every canonical currency displays with its canonical scale', () {
      // The drift that existed: KMF is 0-decimal in kCurrencyScale and was
      // simply absent from the display table, so it fell through to 2 and
      // showed `1000` as `1000.00` — more precision than the value can hold.
      for (final entry in kCurrencyScale.entries) {
        expect(currencyDecimalDigits(entry.key), entry.value,
            reason: '${entry.key}: display scale must equal the canonical '
                'scale, or the UI shows a precision the data does not have');
      }
    });

    test('KMF specifically — the code that was drifting', () {
      expect(currencyDecimalDigits('KMF'), 0);
      expect(formatMoney(Money(1000, 'KMF')), '1,000');
    });

    test('an unknown code degrades to 2 rather than throwing', () {
      // Deliberate asymmetry with currency_scale.dart, which THROWS: minting
      // canonical minor units from a guess is corruption, but a display surface
      // must not crash on an unfamiliar code.
      expect(currencyDecimalDigits('ZZZ'), 2);
    });
  });

  group('R-8 — formatting is exact, never through double', () {
    test('the currencies the product exists to serve', () {
      expect(formatMoney(Money(1250, 'EGP')), '12.50');
      expect(formatMoney(Money(12990, 'SAR')), '129.90');
      expect(formatMoney(Money(12345, 'KWD')), '12.345'); // 3-decimal
      expect(formatMoney(Money(1500, 'JPY')), '1,500'); // 0-decimal
    });

    test('grouping', () {
      expect(formatMoney(Money(150050, 'SAR')), '1,500.50');
      expect(formatMoney(Money(100000000, 'SAR')), '1,000,000.00');
      expect(formatMoney(Money(123456789, 'SAR')), '1,234,567.89');
    });

    test('negatives keep their sign and grouping', () {
      expect(formatMoney(Money(-124050, 'SAR')), '-1,240.50');
      expect(formatMoney(Money(-1, 'SAR')), '-0.01');
    });

    test('zero and sub-unit values', () {
      expect(formatMoney(Money(0, 'SAR')), '0.00');
      expect(formatMoney(Money(0, 'JPY')), '0');
      expect(formatMoney(Money(1, 'KWD')), '0.001');
      expect(formatMoney(Money(5, 'SAR')), '0.05');
    });

    test('UX-035 — very large values keep every significant digit', () {
      // The reported symptom was large amounts collapsing into an unreadable,
      // zero-like result. A double-based formatter loses digits past 2^53; this
      // path never constructs one.
      final huge = Money(9007199254740993, 'SAR'); // 2^53 + 1 minor units
      final out = formatMoney(huge);
      expect(out, '90,071,992,547,409.93');
      expect(out.contains('0 0 0'), isFalse);

      // And the exactness claim, stated directly: the formatted digits are the
      // minor units, not a re-derived approximation.
      expect(out.replaceAll(',', '').replaceAll('.', ''),
          huge.minorUnits.toString());
    });

    test('the formatter does not agree with the double path at scale', () {
      // Demonstrates WHY this exists rather than asserting it in the abstract.
      final huge = Money(9007199254740993, 'SAR');
      final viaDouble = formatMoneyAmount(huge.toDouble(), 'SAR');
      expect(formatMoney(huge), isNot(viaDouble),
          reason: 'if these ever agree at this magnitude the double path has '
              'become exact, which it cannot be — re-check the test, not the '
              'formatter');
    });
  });

  group('the exact-money guarantees are not weakened by presentation', () {
    test('formatting never rounds a 3-decimal currency to 2', () {
      // The parser bug class (12.450 read as 12.45) must not reappear as a
      // display bug.
      expect(formatMoney(Money(12450, 'KWD')), '12.450');
      expect(formatMoney(Money(12455, 'BHD')), '12.455');
      expect(formatMoney(Money(1, 'OMR')), '0.001');
    });

    test('round-trip: formatted output re-parses to the same Money', () {
      for (final m in [
        Money(150050, 'SAR'),
        Money(12345, 'KWD'),
        Money(-99, 'EGP'),
        Money(0, 'JPY'),
      ]) {
        final reparsed = Money.parse(
          formatMoney(m).replaceAll(',', ''),
          m.currency,
        );
        expect(reparsed, m, reason: 'display lost information for $m');
      }
    });
  });
}
