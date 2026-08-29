import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/engine/parser/catalog_rule_matcher.dart';
import 'package:money_companion/engine/parser/parser_engine.dart';

/// C-1 — an admin-authored catalog rule must not, on its own, write CONFIRMED
/// money into the ledger.
///
/// Chain this guards (docs/plans/QIRSH_MASTER_PLAN_V2.md §10.1):
///   * `catalog-delta` serves only `validation_status='passed'` parsers
///     (`supabase/functions/catalog-delta/index.ts:96-98`) — but migration
///     `0004_parser_lab.sql:15` blanket-stamped every pre-existing rule
///     `'passed'` without running a single golden test, so the gate admits
///     rules that were never validated.
///   * a matched rule was then given a fixed confidence of 0.95, which clears
///     `AddTransactionUseCase.autoConfirmThreshold` (0.92).
///
/// Result: an unvalidated regex authored in the admin panel could set confirmed
/// money with no human review, on the automatic capture path.
///
/// The client-side invariant asserted here is deliberately independent of any
/// server state: a rule-captured amount that the engine's own heuristics cannot
/// corroborate may still parse, but it must land in the review queue rather
/// than auto-confirm. This mirrors the existing `dateAmbiguous` treatment,
/// which caps at 0.89 precisely so a wrong date "can never ride through to
/// auto-confirm".
void main() {
  // Kept in sync with AddTransactionUseCase.autoConfirmThreshold / the parser's
  // pendingThreshold. Duplicated as literals on purpose: if either constant
  // moves, this test should fail rather than silently follow it.
  const autoConfirmThreshold = 0.92;
  const pendingThreshold = 0.70;

  CatalogParserRule ruleCapturing(String messagePattern) => CatalogParserRule(
        id: 'rule-under-test',
        senderPattern: r'^TESTBANK$',
        messagePattern: messagePattern,
        transactionType: 'debit',
        priority: 100,
        extractedFields: const {'amount': 'amount', 'merchant': 'merchant'},
      );

  test(
      'a rule-captured amount the heuristics CANNOT corroborate does not '
      'auto-confirm', () {
    // The rule captures "999.00" from a reference-number tail that the engine's
    // own amount extraction does not read as the transaction amount. A rule
    // like this is exactly what an unvalidated admin regex produces.
    const sms = 'TESTBANK: purchase of SAR 25.00 at COFFEE REF 999.00';

    final result = const ParserEngine().parse(
      sms,
      senderId: 'TESTBANK',
      catalogRules: [
        ruleCapturing(
          r'REF\s+(?<amount>[0-9][0-9,]*(?:\.[0-9]{1,2})?)',
        ),
      ],
    );

    expect(result.isTransaction, isTrue,
        reason: 'the rule still parses — we are gating confirmation, not '
            'discarding the message');
    final txn = result.transaction!;
    expect(txn.amount, 999.00,
        reason: 'the rule remains the extraction authority');
    expect(
      txn.parseConfidence,
      lessThan(autoConfirmThreshold),
      reason: 'an uncorroborated rule amount must NOT reach auto-confirm — '
          'this is the C-1 money-integrity invariant',
    );
    expect(
      txn.parseConfidence,
      greaterThanOrEqualTo(pendingThreshold),
      reason: 'it must still reach the review queue, not be dropped',
    );
  });

  test('a rule-captured amount the heuristics DO corroborate still auto-confirms',
      () {
    // Same message, but now the rule captures the real transaction amount that
    // the engine independently extracts. Two independent readings agree, so the
    // F-016 benefit (deterministic admin authority) is preserved.
    const sms = 'TESTBANK: purchase of SAR 25.00 at COFFEE';

    final result = const ParserEngine().parse(
      sms,
      senderId: 'TESTBANK',
      catalogRules: [
        ruleCapturing(
          r'SAR\s+(?<amount>[0-9][0-9,]*(?:\.[0-9]{1,2})?)\s+at\s+(?<merchant>[A-Z ]+)',
        ),
      ],
    );

    expect(result.isTransaction, isTrue);
    final txn = result.transaction!;
    expect(txn.amount, 25.00);
    expect(
      txn.parseConfidence,
      greaterThanOrEqualTo(autoConfirmThreshold),
      reason: 'a corroborated rule match keeps its deterministic authority',
    );
  });
}
