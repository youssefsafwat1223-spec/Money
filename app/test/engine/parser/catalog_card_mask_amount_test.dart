import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/engine/parser/catalog_rule_matcher.dart';

import '../fixtures/bank_sms_golden_fixtures.dart';

/// The SNB/Riyad card-mask-as-amount defect, and the rules that must never
/// regress into it.
///
/// REPRODUCED, not hypothesised: with the currency token optional
/// (`(?:SAR|ريال|ر\.س)?`), the lazy `[\s\S]*?` let the amount group take the
/// FIRST digit run after the keyword. On the real SNB layout that run is the
/// masked card number:
///
///     عملية شراء
///     بطاقة:مدى;****<card>     <- first digit run, no currency before it
///     مبلغ:SAR <amount>        <- the money, currency immediately before it
///
/// so the rule returned the card suffix as the transaction amount. The engine's
/// 0.89 corroboration cap stopped auto-confirm, but the review queue still
/// showed the wrong money, one tap from confirmation.
///
/// The fix makes the currency token REQUIRED. Rules load from the canonical
/// source, so this suite tests what actually ships rather than a copy.
List<CatalogParserRule> _canonicalRules() {
  final raw = File('../supabase/catalog/parser_rules.json').readAsStringSync();
  final rules = (jsonDecode(raw) as Map<String, Object?>)['rules'] as List;
  return rules
      .cast<Map<String, Object?>>()
      .map((r) => CatalogParserRule(
            id: r['id']! as String,
            senderPattern: r['sender_pattern']! as String,
            messagePattern: r['message_pattern']! as String,
            transactionType: r['transaction_type']! as String,
            priority: r['priority']! as int,
            extractedFields:
                (r['extracted_fields'] as Map).cast<String, Object?>(),
          ))
      .toList();
}

const _snb = '10000000-0000-4000-8000-000000000101';
const _riyad = '10000000-0000-4000-8000-000000000103';

void main() {
  final rules = _canonicalRules();
  CatalogParserRule byId(String id) => rules.firstWhere((r) => r.id == id);

  group('a card mask can never become the amount', () {
    test('every anonymized fixture a canonical rule matches yields the '
        'expected amount, never the card suffix', () {
      // The regression case. Drives the REAL matcher over the repo's own
      // anonymized corpus — no message is invented here.
      var matched = 0;
      for (final f in [...realWorldBankSmsFixtures, ...parserGateFixtures]) {
        final sender = f.sender;
        if (sender == null) continue;
        final m = matchCatalogRule(rules, senderId: sender, messageText: f.rawSms);
        if (m == null) continue;
        matched++;
        if (f.expectedLast4 != null) {
          expect(m.amountText, isNot(f.expectedLast4),
              reason: '${f.id}: captured the card suffix as the amount');
        }
        if (f.expectedAmount != null && m.amountText != null) {
          final got = double.parse(m.amountText!.replaceAll(',', ''));
          expect(got, closeTo(f.expectedAmount!, 0.001),
              reason: '${f.id}: wrong amount from rule ${m.rule.id}');
        }
      }
      // Non-vacuity: if the rules stopped matching anything, every assertion
      // above would hold trivially.
      expect(matched, greaterThan(0),
          reason: 'no fixture matched — the assertions would be vacuous');
    });

    test('the SNB rule extracts the money, not the first digit run', () {
      final f = parserGateFixtures
          .firstWhere((x) => x.id == 'known_bank_known_merchant_auto_confirm');
      final m = matchCatalogRule([byId(_snb)],
          senderId: f.sender!, messageText: f.rawSms);
      expect(m, isNotNull, reason: 'the SNB rule must still match its own format');
      expect(double.parse(m!.amountText!.replaceAll(',', '')), 45.00);
      expect(m.amountText, isNot('4521'), reason: 'the card suffix');
    });

    test('the currency token is REQUIRED, so a bare digit run cannot match', () {
      // The narrowest statement of the fix.
      for (final id in [_snb, _riyad]) {
        expect(byId(id).messagePattern, contains(r'(?:SAR|ريال|ر\.س)\s*(?<amount>'),
            reason: '$id lost the required-currency guard');
        expect(byId(id).messagePattern.contains(r'(?:SAR|ريال|ر\.س)?\s*(?<amount>'),
            isFalse,
            reason: '$id made the currency optional again — the exact defect');
      }
    });
  });

  group('the SNB/Riyad rules keep their other contractual guarantees', () {
    test('sender scope is unchanged and still anchored', () {
      expect(byId(_snb).senderPattern, r'^(SNB|AlAhli|Al Ahli)$');
      expect(byId(_riyad).senderPattern, r'^(Riyad)$');
      // An anchored pattern must not match a superstring.
      for (final id in [_snb, _riyad]) {
        final re = RegExp(byId(id).senderPattern);
        expect(re.hasMatch('NOT-${byId(id).senderPattern}'), isFalse);
      }
      expect(RegExp(byId(_snb).senderPattern).hasMatch('SNB-PROMO'), isFalse);
      expect(RegExp(byId(_riyad).senderPattern).hasMatch('Riyadh'), isFalse);
    });

    test('a foreign sender never reaches these rules', () {
      final f = parserGateFixtures
          .firstWhere((x) => x.id == 'known_bank_known_merchant_auto_confirm');
      for (final sender in ['CIB', 'NBE', 'Fawry', 'stcbank', 'unknown']) {
        final m = matchCatalogRule([byId(_snb), byId(_riyad)],
            senderId: sender, messageText: f.rawSms);
        expect(m, isNull, reason: '$sender must not match an SA bank rule');
      }
    });

    test('currency and type stay as the catalog declares them', () {
      for (final id in [_snb, _riyad]) {
        expect(byId(id).extractedFields['currency'], 'SAR');
        expect(byId(id).transactionType, 'debit');
      }
    });
  });

  group('malformed input fails toward no-match, never toward wrong money', () {
    final snb = byId(_snb);

    test('a message with digits but NO currency token does not match', () {
      // Exactly the shape that produced the defect.
      const noCurrency = 'عملية شراء\nبطاقة:مدى;****4521\nمبلغ:45.00\nلدى:SHOP';
      final m = matchCatalogRule([snb], senderId: 'SNB', messageText: noCurrency);
      expect(m?.amountText, isNot('4521'));
    });

    test('a message with no digits at all does not yield an amount', () {
      final m = matchCatalogRule([snb],
          senderId: 'SNB', messageText: 'عملية شراء لدى:SHOP');
      expect(m?.amountText, isNull);
    });

    test('an empty and a whitespace-only message never match', () {
      expect(matchCatalogRule([snb], senderId: 'SNB', messageText: ''), isNull);
      expect(
          matchCatalogRule([snb], senderId: 'SNB', messageText: '   \n  ')?.amountText,
          isNull);
    });

    test('a null or empty sender never matches', () {
      final f = parserGateFixtures
          .firstWhere((x) => x.id == 'known_bank_known_merchant_auto_confirm');
      expect(matchCatalogRule([snb], senderId: null, messageText: f.rawSms), isNull);
      expect(matchCatalogRule([snb], senderId: '', messageText: f.rawSms), isNull);
    });
  });
}
