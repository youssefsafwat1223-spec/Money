import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/domain/finance/money_input.dart';
import 'package:money_companion/engine/parser/catalog_rule_matcher.dart';

/// BUG 3 — catalog rules assumed a 2-decimal currency.
///
/// The twelve seeded rules capture the amount with `(?:\.[0-9]{1,2})?`. Against
/// KWD/BHD/OMR that takes `12.45` out of `12.450` — a 10x error in minor units
/// that nothing downstream can detect, because `12.45` is a valid amount.
///
/// Two independent defences, tested separately:
///   * migration 0091 widens the seeded patterns to `{1,3}` (fixes the DATA);
///   * [untruncatedAmount] rejects any capture that is a prefix of a longer
///     number in the message (fixes the CONTRACT, for rules we do not control).
void main() {
  // The exact quantifier the twelve seeded rules ship with, pre-0091.
  const legacyTwoDecimalRule = r'(?<amount>[0-9][0-9,]*(?:\.[0-9]{1,2})?)';
  // What 0091 rewrites it to.
  const widenedRule = r'(?<amount>[0-9][0-9,]*(?:\.[0-9]{1,3})?)';

  // Deliberately mirrors the SHAPE of the twelve rules seeded by
  // 0002_catalog_mvp.sql — `[\s\S]*` wrappers around an optional currency and
  // the amount group — so the truncation reproduces the way it would in
  // production rather than the way a tidy pattern would.
  CatalogParserRule ruleWith(String amountGroup) => CatalogParserRule(
        id: 'test-rule',
        senderPattern: r'^NBK$',
        messagePattern: '[\\s\\S]*(?:خصم|شراء|Purchase|Debit)[\\s\\S]*?'
            '(?<currency>KWD|د\\.ك)?\\s*$amountGroup[\\s\\S]*',
        transactionType: 'debit',
        priority: 100,
        extractedFields: const {'amount': 'amount', 'currency': 'currency'},
      );

  group('untruncatedAmount — the engine-side guard', () {
    test('rejects a 2-decimal capture of a 3-decimal amount', () {
      expect(untruncatedAmount('12.45', 'خصم 12.450 KWD'), isNull);
      expect(untruncatedAmount('0.75', 'خصم 0.750 BHD'), isNull);
      expect(untruncatedAmount('123.45', 'debit 123.456 OMR'), isNull);
    });

    test('accepts a complete capture', () {
      expect(untruncatedAmount('12.450', 'خصم 12.450 KWD'), '12.450');
      expect(untruncatedAmount('125.75', 'Purchase SAR 125.75'), '125.75');
    });

    test('accepts an integer amount not followed by digits', () {
      expect(untruncatedAmount('12800', 'JPY 12800 total'), '12800');
    });

    test('handles Arabic-Indic digits on both sides', () {
      expect(untruncatedAmount('١٢٫٤٥', 'خصم ١٢٫٤٥٠ د.ك'), isNull);
      expect(untruncatedAmount('١٢٫٤٥٠', 'خصم ١٢٫٤٥٠ د.ك'), '١٢٫٤٥٠');
    });

    test('null in, null out', () {
      expect(untruncatedAmount(null, 'anything'), isNull);
    });
  });

  group('end-to-end through matchCatalogRule', () {
    test('a legacy {1,2} rule no longer yields a truncated KWD amount', () {
      final match = matchCatalogRule(
        [ruleWith(legacyTwoDecimalRule)],
        senderId: 'NBK',
        messageText: 'خصم 12.450 د.ك',
      );
      expect(match, isNotNull, reason: 'the rule still matches');
      // Pre-fix this was '12.45'. The engine now declines the truncated capture
      // and falls back to its own extraction rather than recording 12,450 fils
      // as 1,245.
      expect(match!.amountText, isNull);
    });

    test('the widened {1,3} rule captures all three decimals', () {
      final match = matchCatalogRule(
        [ruleWith(widenedRule)],
        senderId: 'NBK',
        messageText: 'خصم 12.450 د.ك',
      );
      expect(match, isNotNull);
      expect(match!.amountText, '12.450');
    });

    test('2-decimal currencies are unaffected by the widening', () {
      final match = matchCatalogRule(
        [
          const CatalogParserRule(
            id: 'r',
            senderPattern: r'^CIB$',
            messagePattern: 'خصم\\s*$widenedRule\\s*(?<currency>EGP)',
            transactionType: 'debit',
            priority: 100,
            extractedFields: {'amount': 'amount', 'currency': 'currency'},
          )
        ],
        senderId: 'CIB',
        messageText: 'خصم 60.00 EGP',
      );
      expect(match!.amountText, '60.00');
    });
  });

  group('every scale in the currency contract survives capture', () {
    test('0, 2 and 3 minor-digit currencies round-trip to canonical Money', () {
      for (final (text, code) in const [
        ('12800', 'JPY'), // 0 decimals
        ('125.75', 'SAR'), // 2 decimals
        ('12.450', 'KWD'), // 3 decimals
        ('0.750', 'BHD'),
        ('123.456', 'OMR'),
      ]) {
        final captured = untruncatedAmount(text, 'amount $text $code');
        expect(captured, text, reason: '$text $code must not be truncated');
        expect(() => parseLocalizedMoney(captured!, code), returnsNormally,
            reason: '$text $code must be canonical Money');
      }
    });
  });
}
