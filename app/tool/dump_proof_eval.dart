/// Runs the full PRODUCTION deterministic path over `{id, sms, sender}` rows
/// and reports what the phone would conclude, with no model involved.
///
/// This exists so a challenge set can be scored against production itself
/// rather than against a Python approximation of it. Everything here is the
/// shipping code path: the real bank profiles, the real catalog rules, the real
/// corroboration and the real amount-candidate filter.
///
///     dart run tool/dump_proof_eval.dart <catalog_rules.json> < rows.jsonl
library;

import 'dart:convert';
import 'dart:io';

import 'package:money_companion/engine/parser/bank_profile.dart';
import 'package:money_companion/engine/parser/catalog_rule_matcher.dart';
import 'package:money_companion/engine/parser/parser_engine.dart';
import 'package:money_companion/engine/proof/amount_candidates.dart';
import 'package:money_companion/engine/proof/direction_corroboration.dart';
import 'package:money_companion/engine/proof/evidence.dart';

void main(List<String> argv) {
  final rules = <CatalogParserRule>[];
  if (argv.isNotEmpty && File(argv.first).existsSync()) {
    final decoded =
        jsonDecode(File(argv.first).readAsStringSync()) as Map<String, Object?>;
    for (final r in (decoded['rules'] as List).cast<Map<String, Object?>>()) {
      rules.add(CatalogParserRule(
        id: r['id'] as String,
        senderPattern: r['sender_pattern'] as String,
        messagePattern: r['message_pattern'] as String,
        transactionType: r['transaction_type'] as String,
        priority: (r['priority'] as num).toInt(),
        extractedFields: (r['extracted_fields'] as Map).cast<String, Object?>(),
      ));
    }
  }
  stderr.writeln('catalog rules: ${rules.length}');

  const engine = ParserEngine();
  for (String? line = stdin.readLineSync();
      line != null;
      line = stdin.readLineSync()) {
    if (line.trim().isEmpty) continue;
    final row = jsonDecode(line) as Map<String, dynamic>;
    final sms = (row['sms'] ?? '') as String;
    final sender = (row['sender'] ?? '') as String;

    final result = engine.parse(
      sms,
      senderId: sender.isEmpty ? null : sender,
      bankProfiles: BankProfiles.all,
      catalogRules: rules,
    );
    BankProfile? profile;
    for (final b in BankProfiles.all) {
      if (b.bankKey == result.bankKey) {
        profile = b;
        break;
      }
    }
    CatalogParserRule? matched;
    for (final r in rules) {
      if (r.id == result.catalogRuleId) {
        matched = r;
        break;
      }
    }

    final evidence = extractEvidence(sms);
    final corroborators = deterministicCorroborators(
      sms: sms,
      evidence: evidence,
      bank: profile,
      catalogRule: matched,
    );
    final resolution = resolveDirection(corroborators);
    final candidates = amountCandidates(evidence, bank: profile);

    stdout.writeln(jsonEncode({
      'id': row['id'],
      'bank_key': result.bankKey,
      'catalog_rule_id': result.catalogRuleId,
      'direction_outcome': resolution.outcome.name,
      'direction_polarity': resolution.polarity?.name,
      'corroborators': [
        for (final c in corroborators)
          {'source': c.source.wire, 'polarity': c.polarity.name,
           'provenance': c.provenance}
      ],
      'candidates': [
        for (final c in candidates) {'text': c.text, 'start': c.start}
      ],
      'candidate_count': candidates.length,
      'total_due_excluded': totalDueExclusions(evidence, profile),
    }));
  }
}
