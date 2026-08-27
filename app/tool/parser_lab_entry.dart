// Entry point compiled to JS for the admin Parser Lab.
// Build: dart compile js tool/parser_lab_entry.dart -O2 -o ../admin/public/parser_lab.js
//
// Exposes:
//   window.parseSms(rawMessage, sender): string (JSON)            — legacy
//   window.parseSmsWithRules(rawMessage, sender, rulesJson): string (JSON)
//   window.parserLabContract: string
//
// Uses the SAME Dart engine as the app — single source of truth. F-014/F-016:
// `rulesJson` is the catalog rules array exactly as the admin API serves it
// (sender_pattern / message_pattern / transaction_type / priority /
// extracted_fields), so the Lab exercises the identical rule authority the
// device applies, not an approximation.

import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:money_companion/engine/parser/bank_profile.dart';
import 'package:money_companion/engine/parser/catalog_rule_matcher.dart';
import 'package:money_companion/engine/parser/parse_result.dart';
import 'package:money_companion/engine/parser/parser_engine.dart';

/// Bump when the parse-relevant contract changes; the Lab page displays it so
/// a stale compiled artifact is visible instead of silently divergent.
const String parserLabContract = 'engine-2026-08-27+catalog-rules-v1';

List<CatalogParserRule> _decodeRules(String rulesJson) {
  if (rulesJson.trim().isEmpty) return const [];
  final Object? decoded;
  try {
    decoded = jsonDecode(rulesJson);
  } on FormatException {
    return const []; // fail closed — no rules, device-identical fallback
  }
  if (decoded is! List) return const [];
  final rules = <CatalogParserRule>[];
  for (final item in decoded) {
    if (item is! Map) continue;
    final sender = item['sender_pattern'];
    final message = item['message_pattern'];
    if (sender is! String || message is! String) continue;
    final extracted = item['extracted_fields'];
    rules.add(CatalogParserRule(
      id: '${item['id'] ?? ''}',
      senderPattern: sender,
      messagePattern: message,
      transactionType: '${item['transaction_type'] ?? ''}',
      priority: (item['priority'] as num?)?.toInt() ?? 0,
      extractedFields: extracted is Map
          ? extracted.map((k, v) => MapEntry(k.toString(), v))
          : const {},
    ));
  }
  return rules;
}

String _parse(String rawMessage, String sender, String rulesJson) {
  const engine = ParserEngine();
  final ParseResult result;
  try {
    result = engine.parse(
      rawMessage,
      senderId: sender.isEmpty ? null : sender,
      bankProfiles: BankProfiles.all,
      catalogRules: _decodeRules(rulesJson),
    );
  } catch (e) {
    return json.encode({'isTransaction': false, 'error': '$e'});
  }

  final map = <String, Object?>{
    'isTransaction': result.isTransaction,
    'bankKey': result.bankKey,
    'confidence': result.confidence,
    'catalogRuleId': result.catalogRuleId,
    'contract': parserLabContract,
  };

  if (result.isTransaction && result.transaction != null) {
    final txn = result.transaction!;
    map['amount'] = txn.amount;
    map['currency'] = txn.currency;
    map['type'] = txn.type.name;
    map['source'] = txn.source.name;
    map['merchant'] = txn.rawMerchant;
    map['cardLast4'] = txn.cardLast4;
    map['balanceAfter'] = txn.balanceAfter;
    map['occurredAt'] = txn.occurredAt?.toIso8601String();
    map['foreignAmount'] = txn.foreignAmount;
    map['foreignCurrency'] = txn.foreignCurrency;
    map['fundingSource'] = txn.fundingSource;
    map['parseConfidence'] = txn.parseConfidence;
  }

  return json.encode(map);
}

void main() {
  globalContext['parserLabContract'] = parserLabContract.toJS;
  globalContext['parseSms'] = ((JSString rawMessage, JSString sender) {
    return _parse(rawMessage.toDart, sender.toDart, '').toJS;
  }).toJS;
  globalContext['parseSmsWithRules'] =
      ((JSString rawMessage, JSString sender, JSString rulesJson) {
    return _parse(rawMessage.toDart, sender.toDart, rulesJson.toDart).toJS;
  }).toJS;
}
