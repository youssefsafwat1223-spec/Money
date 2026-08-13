// MALI-026 (Phase-9K) — architecture/contract guard: NO revision-covered parent
// tombstone may be an unconditional id-only `UPDATE ... deleted_at WHERE id`. A
// stale delete that overwrites a newer accepted update is exactly the lost-update
// this phase closes, and it blocked multi-device / CAS activation. Every server
// tombstone write in the three parent push surfaces MUST travel with a guard
// predicate in the SAME chained statement: a revision CAS (`.eq('revision', …)`),
// an optimistic timestamp compare (`.eq('updated_at', …)`), or an
// already-deleted guard (`.isFilter('deleted_at', null)`).
//
// If a NEW parent tombstone surface is added, add its file here and it must
// satisfy the same contract.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The enumerated server-tombstone surfaces for the nine revision-covered
/// parents (transactions; accounts; the seven planning entities).
const _tombstoneSurfaces = <String>[
  'lib/features/capture/services/ledger_push_service.dart',
  'lib/features/planning_sync/services/planning_push_service.dart',
  'lib/features/planning_sync/services/accounts_push_service.dart',
];

/// Strip `//` line comments so prose (e.g. "never id-only") can't satisfy — or
/// spuriously trip — the guard, then collapse whitespace so a chained statement
/// that spans lines is one searchable string.
String _flatten(String src) {
  final noComments = src.split('\n').map((l) {
    final i = l.indexOf('//');
    return i >= 0 ? l.substring(0, i) : l;
  }).join('\n');
  return noComments.replaceAll(RegExp(r'\s+'), ' ');
}

/// Every `deleted_at` server write, sliced from the `update({'deleted_at'` up to
/// the statement's terminating `.maybeSingle()`.
final _tombstoneStmt =
    RegExp(r"update\(\{'deleted_at'.*?maybeSingle\(\)", dotAll: true);

bool _isGuarded(String stmt) =>
    stmt.contains(".eq('revision'") ||
    stmt.contains(".eq('updated_at'") ||
    stmt.contains(".isFilter('deleted_at'");

void main() {
  test(
      'every revision-covered parent tombstone carries a guard predicate '
      '(never an unconditional id-only deleted_at write)', () {
    for (final path in _tombstoneSurfaces) {
      final flat = _flatten(File(path).readAsStringSync());
      final stmts = _tombstoneStmt.allMatches(flat).map((m) => m.group(0)!);
      expect(stmts, isNotEmpty,
          reason: '$path must contain at least one tombstone write');
      for (final stmt in stmts) {
        expect(_isGuarded(stmt), isTrue,
            reason: 'UNGUARDED tombstone in $path: '
                '${stmt.substring(0, stmt.length.clamp(0, 160))}');
      }
    }
  });

  test('the pre-9K unconditional tombstone primitives are gone', () {
    final planning = File(_tombstoneSurfaces[1]).readAsStringSync();
    final accounts = File(_tombstoneSurfaces[2]).readAsStringSync();
    // The old void, id-only sink methods must not exist anywhere.
    expect(planning.contains('Future<void> tombstone('), isFalse);
    expect(accounts.contains('Future<void> tombstoneAccount('), isFalse);
    // And the guarded surface must be present (the replacement).
    expect(planning.contains('casTombstone('), isTrue);
    expect(planning.contains('guardedTombstone('), isTrue);
    expect(accounts.contains('casTombstoneAccount('), isTrue);
    expect(accounts.contains('guardedTombstoneAccount('), isTrue);
  });

  test(
      'the ledger delete guards the tombstone (base tokens + a fetch-state '
      'classifier), never a blind id-only overwrite', () {
    final ledger = File(_tombstoneSurfaces[0]).readAsStringSync();
    // The delete path resolves a zero-row tombstone instead of assuming success.
    expect(ledger.contains('_resolveDeleteConflict('), isTrue);
    // It reads the base revision from the (now enriched) delete payload.
    expect(ledger.contains("payload['server_revision']"), isTrue);
  });
}
