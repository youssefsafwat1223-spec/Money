// F-014 — Parser Lab parity, device side of the contract.
//
// The lab runs `admin/public/parser_lab.js`, a dart2js compilation of THIS
// engine. Parity holds when both sides produce the goldens below for the
// shared fixtures. The Dart engine (this test) is the AUTHORITY: when engine
// behaviour changes intentionally, regenerate the goldens from the engine and
// recompile parser_lab.js — `admin/tests/parser-lab-parity.test.mjs` then
// proves the compiled artifact is not stale. Neither side ever copies the
// other's output at runtime; the goldens are the meeting point.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/engine/parser/bank_profile.dart';
import 'package:money_companion/engine/parser/catalog_rule_matcher.dart';
import 'package:money_companion/engine/parser/parser_engine.dart';

void main() {
  test('F-014: the Dart engine reproduces the shared parity goldens', () {
    const dir = '../admin/tests/fixtures';
    final fixtures = jsonDecode(
        File('$dir/parser_parity_fixtures.json').readAsStringSync()) as Map;
    final goldens = jsonDecode(
        File('$dir/parser_parity_goldens.json').readAsStringSync()) as List;

    final rules = [
      for (final r in fixtures['rules'] as List)
        CatalogParserRule(
          id: r['id'] as String,
          senderPattern: r['sender_pattern'] as String,
          messagePattern: r['message_pattern'] as String,
          transactionType: r['transaction_type'] as String,
          priority: r['priority'] as int,
          extractedFields: (r['extracted_fields'] as Map)
              .map((k, v) => MapEntry(k.toString(), v)),
        ),
    ];

    const engine = ParserEngine();
    final cases = fixtures['cases'] as List;
    expect(goldens.length, cases.length,
        reason: 'goldens out of sync with fixtures — regenerate');

    for (var i = 0; i < cases.length; i++) {
      final c = cases[i] as Map;
      final g = goldens[i] as Map;
      final res = engine.parse(
        c['body'] as String,
        senderId: c['sender'] as String,
        bankProfiles: BankProfiles.all,
        catalogRules: rules,
      );
      final reason = 'case ${c['name']}: engine drifted from goldens — if '
          'intentional, regenerate goldens AND recompile parser_lab.js';
      expect(res.isTransaction, g['isTransaction'], reason: reason);
      expect(res.catalogRuleId, g['catalogRuleId'], reason: reason);
      expect(res.transaction?.amount, g['amount'], reason: reason);
      expect(res.transaction?.currency, g['currency'], reason: reason);
      expect(res.transaction?.type.name, g['type'], reason: reason);
      expect(res.transaction?.rawMerchant, g['merchant'], reason: reason);
      expect(res.transaction?.balanceAfter, g['balanceAfter'], reason: reason);
      expect(res.transaction?.parseConfidence, g['parseConfidence'],
          reason: reason);
    }
  });
}
