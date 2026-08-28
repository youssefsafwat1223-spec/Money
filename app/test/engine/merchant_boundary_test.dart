import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/engine/parser/catalog_rule_matcher.dart';
import 'package:money_companion/engine/parser/parser_engine.dart';

/// F-015 — the merchant must not swallow the trailing date clause.
///
/// Two independent halves, and fixing only the first leaves the bug live:
///
/// 1. `_cleanMerchant` strips `في` / `on` / `يوم` / `الساعة` but NOT `بتاريخ`
///    ("on date"), which is the form the Saudi/Egyptian banks actually use.
///
/// 2. A merchant captured by a CATALOG RULE bypasses `_cleanMerchant`
///    altogether (`parser_engine.dart`: `catalogMatch?.merchant ?? …`). All 12
///    seeded rules capture `(?<merchant>[^\n]+)` — greedy to end of line — so
///    every rule-matched message carries the date in the merchant.
///
/// That second half is why this is not a Dart-only fix in the way it was first
/// filed: the greedy capture lives in admin-authored rule DATA. Normalisation
/// therefore belongs in the ENGINE, where it is written once and tested, rather
/// than in each rule's regex, where it must be got right by every future author.
void main() {
  const engine = ParserEngine();

  CatalogParserRule greedyMerchantRule() => const CatalogParserRule(
        id: 'rule-greedy',
        senderPattern: r'^alrajhi$',
        messagePattern:
            r'خصم[\s\S]*?(?<amount>[0-9][0-9,]*(?:\.[0-9]{1,2})?)\s*ريال[\s\S]*?لدى\s*(?<merchant>[^\n]+)',
        transactionType: 'debit',
        priority: 100,
        extractedFields: {'amount': 'amount', 'merchant': 'merchant'},
      );

  group('the heuristic path', () {
    test('strips a بتاريخ date clause', () {
      final result = engine.parse(
        'تم خصم مبلغ 350.00 ريال من حسابك لدى STARBUCKS COFFEE بتاريخ 16/06/2026',
        senderId: 'alrajhi',
      );
      expect(result.isTransaction, isTrue);
      expect(result.transaction!.rawMerchant, 'STARBUCKS COFFEE',
          reason: 'the date is not part of the merchant name');
    });

    test('still strips the clauses it already handled', () {
      for (final sms in [
        'تم خصم مبلغ 350.00 ريال من حسابك لدى STARBUCKS COFFEE في 16/06/2026',
      ]) {
        final r = engine.parse(sms, senderId: 'alrajhi');
        expect(r.transaction?.rawMerchant, contains('STARBUCKS'),
            reason: 'regression on an already-handled form: $sms');
        expect(r.transaction?.rawMerchant, isNot(contains('16/06/2026')));
      }
    });
  });

  group('the catalog-rule path', () {
    test('a greedy rule capture is normalised by the engine', () {
      // The rule captures to end of line — exactly what all 12 seeded rules do.
      // The engine must not accept that verbatim, or every rule-matched message
      // carries the date.
      final result = engine.parse(
        'تم خصم مبلغ 350.00 ريال من حسابك لدى STARBUCKS COFFEE بتاريخ 16/06/2026',
        senderId: 'alrajhi',
        catalogRules: [greedyMerchantRule()],
      );

      expect(result.isTransaction, isTrue);
      expect(result.transaction!.rawMerchant, 'STARBUCKS COFFEE',
          reason: 'a rule-captured merchant must pass through the same cleaner '
              'as the heuristic one — otherwise rule authors must each get the '
              'boundary right, and all 12 seeded rules did not');
    });

    test('the rule still supplies the merchant it matched', () {
      // Normalising must not mean discarding: the rule remains the extraction
      // authority, the engine only trims the boundary.
      final result = engine.parse(
        'تم خصم مبلغ 350.00 ريال من حسابك لدى AMAZON',
        senderId: 'alrajhi',
        catalogRules: [greedyMerchantRule()],
      );
      expect(result.transaction!.rawMerchant, 'AMAZON');
    });
  });

  group('F-015b — a clause keyword must start at a word boundary', () {
    test('a merchant ending in "on" is not truncated', () {
      // Pre-existing and shipped: the `on` alternation had no leading boundary,
      // so it matched the "ON" inside AMAZON and the merchant became "AMAZ".
      // Found while testing F-015 — one of the most common merchants there is.
      final result = engine.parse(
        'تم خصم مبلغ 350.00 ريال من حسابك لدى AMAZON',
        senderId: 'alrajhi',
      );
      expect(result.transaction!.rawMerchant, 'AMAZON');
    });

    test('other merchants containing clause words survive', () {
      for (final entry in {
        'CARREFOUR': 'CARREFOUR',
        'LONDON COFFEE': 'LONDON COFFEE',
        'MARATHON SPORTS': 'MARATHON SPORTS',
      }.entries) {
        final r = engine.parse(
          'تم خصم مبلغ 350.00 ريال من حسابك لدى ${entry.key}',
          senderId: 'alrajhi',
        );
        expect(r.transaction!.rawMerchant, entry.value, reason: entry.key);
      }
    });

    test('a genuine trailing clause is still stripped', () {
      final r = engine.parse(
        'تم خصم مبلغ 350.00 ريال من حسابك لدى AMAZON بتاريخ 16/06/2026',
        senderId: 'alrajhi',
      );
      expect(r.transaction!.rawMerchant, 'AMAZON');
    });
  });
}
