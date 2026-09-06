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

    test('the ENGLISH layout works too — currency AFTER the amount', () {
      // The bilingual half. An earlier fix required the currency BEFORE the
      // amount and silently made this layout unmatchable.
      final m = matchCatalogRule([byId(_snb)],
          senderId: 'SNB',
          messageText: 'Online Purchase\nAmount 8 SAR\nAccount *5172\nAt barq');
      expect(m?.amountText, '8');
    });

    test('a preceding digit run is never the amount, in either language', () {
      // The grammar requires a currency token ADJACENT to the amount, so a card
      // suffix, account suffix, reference or date cannot be captured — without
      // widening to "nearest number".
      const cases = <String, String?>{
        // card/account/reference/date with NO adjacent currency -> no amount
        'عملية شراء\nبطاقة:مدى;****4521\nلدى:SHOP': null,
        'Purchase\nAccount *998877\nAt SHOP': null,
        'Purchase\nRef 5566778899\nAt SHOP': null,
        // the same noise BEFORE a real amount -> the amount still wins
        'Purchase\nCard *4521\nAmount 12.50 SAR\nAt SHOP': '12.50',
        'شراء\nبطاقة:****4521\nمبلغ:ريال 99.75\nلدى:SHOP': '99.75',
        'Purchase\non 06/09/2026 at 14:22\nAmount 3.00 SAR\nAt SHOP': '3.00',
        // a trailing balance must not displace the amount
        'شراء\nمبلغ:SAR 45.00\nلدى:SHOP\nالرصيد:SAR 9,999.00': '45.00',
      };
      cases.forEach((message, expected) {
        final m = matchCatalogRule([byId(_snb)],
            senderId: 'SNB', messageText: message);
        expect(m?.amountText, expected,
            reason: 'message starting ${message.split('\n').first}');
      });
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

    test('SNB requires a currency ADJACENT to the amount, on either side', () {
      // The narrowest statement of the grammar: two zero-width assertions, so
      // the captured token itself is unchanged.
      final p = byId(_snb).messagePattern;
      expect(p, contains('(?<='), reason: 'lost the currency-before assertion');
      expect(p, contains('(?='), reason: 'lost the currency-after assertion');
      expect(p.contains(r'(?:SAR|ريال|ر\.س)?\s*(?<amount>'), isFalse,
          reason: 'the optional-currency form is the original defect');
    });

    test('Riyad is deliberately UNCHANGED, and that risk is recorded', () {
      // The same pattern shape, but the wrong-money failure could not be
      // reproduced: no available Riyad message matches the rule at all. A money
      // rule is not changed on resemblance, so this pins the current state and
      // the canonical file records why. Flip this test when bank-sourced
      // evidence arrives.
      expect(byId(_riyad).messagePattern, contains(r'(?:SAR|ريال|ر\.س)?\s*(?<amount>'),
          reason: 'Riyad changed without reproducing the defect');
      final canonical =
          File('../supabase/catalog/parser_rules.json').readAsStringSync();
      expect(canonical, contains('Riyad (...103): UNCHANGED'),
          reason: 'the unreproduced Riyad risk must stay documented');
      expect(canonical, contains('currency'),
          reason: 'including why the SNB fix would break it');
    });
  });

  group('the SNB/Riyad rules keep their other contractual guarantees', () {
    test('sender scope is unchanged and still anchored', () {
      expect(byId(_snb).senderPattern, r'^(SNB|AlAhli|Al Ahli)$');
      expect(byId(_riyad).senderPattern, r'^(Riyad)$');
      // Anchoring, tested the way the DEVICE compiles it: case-insensitively
      // (catalog_rule_matcher.dart uses caseSensitive: false). A case-sensitive
      // check here would pass for the wrong reason.
      final snbRe = RegExp(byId(_snb).senderPattern, caseSensitive: false);
      final riyadRe = RegExp(byId(_riyad).senderPattern, caseSensitive: false);
      expect(snbRe.hasMatch('SNB'), isTrue);
      expect(snbRe.hasMatch('snb'), isTrue, reason: 'the device matches this');
      expect(snbRe.hasMatch('SNB-PROMO'), isFalse);
      expect(snbRe.hasMatch('Snb الاهلي'), isFalse, reason: 'anchored');
      expect(riyadRe.hasMatch('riyad'), isTrue);
      expect(riyadRe.hasMatch('Riyadh'), isFalse);
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
