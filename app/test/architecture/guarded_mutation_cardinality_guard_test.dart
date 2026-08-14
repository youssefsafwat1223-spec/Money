// MALI-026 (Phase-9M) — architecture/contract guard: a concurrency-sensitive
// GUARDED PATCH/UPDATE (revision CAS, updated_at guard, not-already-deleted
// guard, `currency IS NULL` repair) — where 0 matched rows is LEGITIMATE control
// flow — MUST NOT decode with `.maybeSingle()` / `.single()`. Against a newer
// PostgREST those throw PGRST116 on a 0-row PATCH (a version-coupled cardinality
// error, proved live in Phase 9L), so the intended conflict never surfaces. These
// surfaces must decode the LIST via `guardedAck` (0/1/>1) instead.
//
// A create `upsert(...).select().single()` is allowed (a create always affects
// ≥1 row). This guard forbids only `.update(...)` chains ending in a singular
// decode. If a NEW guarded mutation surface is added, add its file here.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const _guardedMutationSurfaces = <String>[
  'lib/features/capture/services/ledger_push_service.dart',
  'lib/features/planning_sync/services/planning_push_service.dart',
  'lib/features/planning_sync/services/accounts_push_service.dart',
  'lib/features/planning_sync/services/planning_server_currency_repair.dart',
];

String _flatten(String src) {
  final noComments = src.split('\n').map((l) {
    final i = l.indexOf('//');
    return i >= 0 ? l.substring(0, i) : l;
  }).join('\n');
  return noComments.replaceAll(RegExp(r'\s+'), ' ');
}

// A `.update(...)` chain that reaches `.maybeSingle()`/`.single()` before its
// statement terminator — the forbidden singular decode of a guarded PATCH.
final _forbidden = RegExp(r'\.update\([^;]*?\.(?:maybeSingle|single)\(\)');

void main() {
  test(
      'no guarded PATCH/UPDATE decodes with maybeSingle()/single() '
      '(0-row must be a LIST → guardedAck, not a PGRST116 throw)', () {
    for (final path in _guardedMutationSurfaces) {
      final flat = _flatten(File(path).readAsStringSync());
      final hits = _forbidden.allMatches(flat).map((m) => m.group(0)!).toList();
      expect(hits, isEmpty,
          reason: 'forbidden singular decode of a guarded update in $path: '
              '${hits.map((h) => h.substring(0, h.length.clamp(0, 90))).toList()}');
      // And the LIST-based helper must be the decoder in use.
      expect(File(path).readAsStringSync().contains('guardedAck('), isTrue,
          reason: '$path must decode guarded mutations via guardedAck');
    }
  });
}
