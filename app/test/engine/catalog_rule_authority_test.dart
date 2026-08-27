// F-016 — catalog parser rules must be the DEVICE runtime authority.
//
// Pre-fix Main compiled sender_pattern/message_pattern only to validate their
// syntax, then converted rule presence into generic keyword hints; priority
// was a bare ORDER BY into a merged profile. Admin edits therefore had zero
// behavioural effect (demo QA F-016, confirmed against Main source
// rules_client.dart). These tests drive the REAL engine entry
// (`ParserEngine.parse(..., catalogRules: …)`) and fail on pre-fix Main.

import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/engine/models/transaction_type.dart';
import 'package:money_companion/engine/parser/catalog_rule_matcher.dart';
import 'package:money_companion/engine/parser/parser_engine.dart';

CatalogParserRule rule({
  String id = 'rule-1',
  String senderPattern = r'^(AlRajhiBank|alrajhi)$',
  String messagePattern =
      r'خصم[\s\S]*?(?<amount>[0-9][0-9,]*(?:\.[0-9]{1,2})?)\s*(?<currency>ريال|SAR)[\s\S]*?لدى\s*:?\s*(?<merchant>[^\n.]+)',
  String transactionType = 'debit',
  int priority = 100,
  Map<String, Object?> extractedFields = const {
    'type': 'debit',
    'amount': 'amount',
    'currency': 'currency',
    'merchant': 'merchant',
  },
}) =>
    CatalogParserRule(
      id: id,
      senderPattern: senderPattern,
      messagePattern: messagePattern,
      transactionType: transactionType,
      priority: priority,
      extractedFields: extractedFields,
    );

const alRajhiPurchase =
    'تم خصم مبلغ 350.00 ريال من حسابك لدى STARBUCKS COFFEE بتاريخ 16/06/2026. '
    'الرصيد المتاح: 4,250.00 ريال';

void main() {
  const engine = ParserEngine();

  group('F-016 catalog rule authority (engine end-to-end)', () {
    test('Al Rajhi purchase: matched rule supplies type/amount/currency/'
        'merchant and a deterministic high confidence', () {
      final result = engine.parse(
        alRajhiPurchase,
        senderId: 'alrajhi',
        catalogRules: [rule()],
      );

      expect(result.isTransaction, isTrue);
      final txn = result.transaction!;
      expect(txn.amount, 350.00);
      expect(txn.currency, 'SAR');
      expect(txn.type, TransactionType.payment);
      expect(txn.rawMerchant, contains('STARBUCKS'));
      expect(txn.parseConfidence, ParserEngine.catalogRuleConfidence,
          reason: 'an admin-authored match is deterministic, not heuristic');
    });

    test('sender mismatch: the rule has ZERO behavioural effect', () {
      final withRule = engine.parse(
        alRajhiPurchase,
        senderId: 'd360', // sender does not satisfy ^(AlRajhiBank|alrajhi)$
        catalogRules: [
          rule(
            // A rule that would grossly mis-extract if it ever ran.
            messagePattern: r'(?<amount>4,250\.00)',
            extractedFields: const {'type': 'credit', 'amount': 'amount'},
          ),
        ],
      );
      final withoutRule = engine.parse(alRajhiPurchase, senderId: 'd360');

      expect(withRule.isTransaction, withoutRule.isTransaction);
      expect(withRule.transaction?.amount, withoutRule.transaction?.amount);
      expect(withRule.transaction?.type, withoutRule.transaction?.type);
      expect(withRule.transaction?.parseConfidence,
          withoutRule.transaction?.parseConfidence,
          reason: 'a non-eligible rule must not even perturb confidence');
    });

    test('message mismatch: eligible sender but non-matching body → '
        'zero behavioural effect', () {
      final withRule = engine.parse(
        alRajhiPurchase,
        senderId: 'alrajhi',
        catalogRules: [
          rule(messagePattern: r'THIS NEVER MATCHES (?<amount>[0-9]+)'),
        ],
      );
      final withoutRule = engine.parse(alRajhiPurchase, senderId: 'alrajhi');

      expect(withRule.transaction?.amount, withoutRule.transaction?.amount);
      expect(withRule.transaction?.parseConfidence,
          withoutRule.transaction?.parseConfidence);
    });

    test('priority collision: the higher-priority rule wins deterministically, '
        'and equal priority resolves by rule id', () {
      // Both rules match; they extract DIFFERENT amounts so the winner is
      // observable in the result.
      final low = rule(
        id: 'b-low',
        priority: 10,
        messagePattern: r'الرصيد المتاح:\s*(?<amount>[0-9][0-9,]*\.[0-9]{2})',
        extractedFields: const {'type': 'debit', 'amount': 'amount'},
      );
      final high = rule(id: 'a-high', priority: 90);

      final result = engine.parse(
        alRajhiPurchase,
        senderId: 'alrajhi',
        catalogRules: [low, high], // order given must not matter
      );
      expect(result.transaction!.amount, 350.00,
          reason: 'priority 90 must beat priority 10 regardless of list order');
      expect(result.transaction!.parseConfidence,
          ParserEngine.catalogRuleConfidence,
          reason: 'provenance: the value must come from the RULE, not from the '
              'heuristics coincidentally agreeing');

      // Equal priority → lexicographic rule id ('a-high' < 'b-low') — a total
      // order, so the same input can never flip between runs.
      final tied = engine.parse(
        alRajhiPurchase,
        senderId: 'alrajhi',
        catalogRules: [low, rule(id: 'a-high', priority: 10)],
      );
      expect(tied.transaction!.amount, 350.00);
    });

    test('D360 wallet credit: rule-declared income type is applied', () {
      const d360Message = 'إضافة 1,000.00 ريال إلى محفظتك من تحويل وارد';
      final result = engine.parse(
        d360Message,
        senderId: 'D360',
        catalogRules: [
          rule(
            senderPattern: r'^D360$',
            messagePattern:
                r'إضافة\s*(?<amount>[0-9][0-9,]*(?:\.[0-9]{1,2})?)\s*(?<currency>ريال)',
            transactionType: 'credit',
            extractedFields: const {
              'type': 'credit',
              'amount': 'amount',
              'currency': 'currency',
            },
          ),
        ],
      );
      expect(result.isTransaction, isTrue);
      expect(result.transaction!.type, TransactionType.income);
      expect(result.transaction!.amount, 1000.00);
    });

    test('Al Ahli transfer: rule type `transfer` overrides keyword heuristics',
        () {
      const alAhli = 'تحويل صادر بمبلغ 2,500.00 ريال إلى حساب أحمد';
      final result = engine.parse(
        alAhli,
        senderId: 'AlAhliBank',
        catalogRules: [
          rule(
            senderPattern: r'^AlAhliBank$',
            messagePattern:
                r'تحويل\s+صادر\s+بمبلغ\s*(?<amount>[0-9][0-9,]*(?:\.[0-9]{1,2})?)',
            transactionType: 'debit',
            extractedFields: const {'type': 'transfer', 'amount': 'amount'},
          ),
        ],
      );
      expect(result.transaction!.type, TransactionType.transfer);
      expect(result.transaction!.amount, 2500.00);
      expect(result.transaction!.parseConfidence,
          ParserEngine.catalogRuleConfidence,
          reason: 'provenance: rule-decided, not keyword-ladder coincidence');
    });

    test('income/salary: a credit rule turns a message the heuristics call '
        'a debit into income', () {
      // 'خصم' appears in the body noise, which biases the heuristics toward
      // payment — the matched rule must still decide income.
      const salary = 'إيداع راتب بمبلغ 12,000.00 ريال (بدون خصم) في حسابك';
      final result = engine.parse(
        salary,
        senderId: 'alrajhi',
        catalogRules: [
          rule(
            messagePattern:
                r'إيداع\s+راتب\s+بمبلغ\s*(?<amount>[0-9][0-9,]*(?:\.[0-9]{1,2})?)',
            transactionType: 'credit',
            extractedFields: const {'type': 'credit', 'amount': 'amount'},
          ),
        ],
      );
      expect(result.transaction!.type, TransactionType.income);
      expect(result.transaction!.amount, 12000.00);
      expect(result.transaction!.parseConfidence,
          ParserEngine.catalogRuleConfidence,
          reason: 'provenance: rule-decided, not keyword-ladder coincidence');
    });

    test('malformed regex fails CLOSED: the broken rule is skipped, a valid '
        'lower-priority rule still wins, and no exception escapes', () {
      final result = engine.parse(
        alRajhiPurchase,
        senderId: 'alrajhi',
        catalogRules: [
          rule(id: 'broken', priority: 999, messagePattern: r'([unclosed'),
          rule(id: 'valid', priority: 1),
        ],
      );
      expect(result.isTransaction, isTrue);
      expect(result.transaction!.amount, 350.00);
      expect(result.transaction!.parseConfidence,
          ParserEngine.catalogRuleConfidence,
          reason: 'the valid rule must still match after the broken one is '
              'skipped fail-closed');
    });

    test('no catalog rules → byte-identical legacy behaviour (explicit '
        'fallback semantics)', () {
      final withEmpty = engine.parse(alRajhiPurchase,
          senderId: 'alrajhi', catalogRules: const []);
      final legacy = engine.parse(alRajhiPurchase, senderId: 'alrajhi');
      expect(withEmpty.isTransaction, legacy.isTransaction);
      expect(withEmpty.transaction?.amount, legacy.transaction?.amount);
      expect(withEmpty.transaction?.type, legacy.transaction?.type);
      expect(withEmpty.transaction?.parseConfidence,
          legacy.transaction?.parseConfidence);
    });

    test('bounded execution: an oversized message or pattern is refused '
        'fail-closed, not executed', () {
      final huge = 'خصم 10.00 ريال ${'x' * kMaxCatalogMessageLength}';
      expect(
        matchCatalogRule([rule()], senderId: 'alrajhi', messageText: huge),
        isNull,
      );
      final hugePattern =
          rule(messagePattern: '(?<amount>${'a' * kMaxCatalogPatternLength})x');
      expect(
        matchCatalogRule([hugePattern],
            senderId: 'alrajhi', messageText: alRajhiPurchase),
        isNull,
      );
    });
  });
}
