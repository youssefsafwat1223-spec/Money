/// Dumps the production cue-role assignment for a corpus of messages so the
/// research harness can prove the Dart and Python layers agree.
///
/// This exists because the frozen benchmark scores `cue_roles_v2.py` while the
/// phone runs `cue_roles.dart`. If the two disagree, the benchmark measures an
/// architecture that was never shipped — which is exactly the defect the second
/// Phase-4 seal was opened to eliminate. Agreement is therefore evidence, not
/// housekeeping, and it is checked mechanically rather than by reading both
/// files side by side.
///
///     dart run tool/dump_cue_roles.dart < corpus.jsonl > dart_roles.jsonl
///
/// Input:  one `{"id": ..., "sms": ...}` per line.
/// Output: one `{"id": ..., "roles": {"<token>@<start>": [roles]}}` per line.
///
/// Keyed by token span rather than evidence id: the two implementations number
/// their nodes independently, so ids are not a shared name, but spans are.
library;

import 'dart:convert';
import 'dart:io';

import 'package:money_companion/engine/proof/amount_candidates.dart';
import 'package:money_companion/engine/proof/cue_roles.dart';
import 'package:money_companion/engine/proof/evidence.dart';

void main() {
  for (String? line = stdin.readLineSync();
      line != null;
      line = stdin.readLineSync()) {
    if (line.trim().isEmpty) continue;
    final row = jsonDecode(line) as Map<String, dynamic>;
    final sms = (row['sms'] ?? '') as String;
    final evidence = extractEvidence(sms);
    final roles = cueRoles(evidence);
    final out = <String, List<String>>{};
    for (final n in evidence.ofClass(EvidenceClass.number)) {
      out['${n.text}@${n.start}'] = (roles[n.id] ?? const <String>{}).toList()
        ..sort();
    }
    final cands = amountCandidates(evidence)
        .map((e) => '${e.text}@${e.start}')
        .toList()
      ..sort();
    stdout.writeln(
        jsonEncode({'id': row['id'], 'roles': out, 'candidates': cands}));
  }
}
