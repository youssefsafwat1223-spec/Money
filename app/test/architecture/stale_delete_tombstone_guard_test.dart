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

import 'no_blind_overwrite_test.dart' show PostgrestUpdate, postgrestUpdates, withoutDartComments, unclassifiedUpdateOffsets;

/// The enumerated server-tombstone surfaces for the nine revision-covered
/// parents (transactions; accounts; the seven planning entities).
const _tombstoneSurfaces = <String>[
  'lib/features/capture/services/ledger_push_service.dart',
  'lib/features/planning_sync/services/planning_push_service.dart',
  'lib/features/planning_sync/services/accounts_push_service.dart',
];

// Direct map writes remain visible in ledger/accounts. Planning sends the
// immutable stamp through _tagMutation's callback parameter instead of placing
// the deleted_at map inline in update(). Pin that concrete binding before
// treating either update(body) branch as a tombstone.
List<PostgrestUpdate> _tombstones(String src) {
  src = withoutDartComments(src);
  if (unclassifiedUpdateOffsets(src).isNotEmpty) {
    throw StateError('Unclassified update prevents complete tombstone coverage');
  }
  final updates = postgrestUpdates(src);
  final result = updates.where((u) =>
      RegExp(r"""['"]deleted_at['"]:""").hasMatch(u.payload)).toList();
  if (!src.contains('class SupabasePlanningRemoteSink ')) return result;
  final start = src.indexOf('Future<Map<String, dynamic>?> guardedTombstone(',
      src.indexOf('class SupabasePlanningRemoteSink '));
  if (start == -1) throw StateError('Missing concrete planning tombstone');
  final end = src.indexOf('\n  @override', start);
  if (end == -1) throw StateError('Unbounded concrete planning tombstone');
  final body = src.substring(start, end);
  final stamp = RegExp(
      r"_SinkMutation\s+stamp\(\)\s*=>\s*_SinkMutation\(\s*"
      r"'guardedTombstone'\s*,\s*table\s*,\s*serverId\s*,\s*"
      r"expectedUpdatedAt\s*,\s*<String,\s*dynamic>\s*"
      r"\{\s*'deleted_at'\s*:\s*deletedAt\s*\}\s*\)\s*;");
  if (!stamp.hasMatch(body)) {
    throw StateError('Planning tombstone lost its immutable deleted_at stamp');
  }
  final tagged = RegExp(
      r'_tagMutation\(\s*stamp\(\)\s*,\s*\(body\)\s*=>\s*_client\s*$');
  final indirect = updates.where((u) => u.start >= start && u.end <= end).toList();
  if (indirect.length != 2 || indirect.any((u) => u.payload != 'body' ||
      !tagged.hasMatch(src.substring(start, u.start)))) {
    throw StateError('Both planning branches must dispatch the stamped body');
  }
  result.addAll(indirect);
  return result;
}

List<PostgrestUpdate> _unguardedTombstones(String src) =>
    _tombstones(src).where((u) => !u.guarded).toList();

void main() {
  test(
      'every revision-covered parent tombstone carries a guard predicate '
      '(never an unconditional id-only deleted_at write)', () {
    for (final path in _tombstoneSurfaces) {
      final src = File(path).readAsStringSync();
      final stmts = _tombstones(src);
      // Each existing surface has a timestamp branch and a not-deleted branch.
      // This also prevents an extractor regression from succeeding vacuously.
      expect(stmts, hasLength(2), reason: '$path must expose both tombstone writes');
      expect(_unguardedTombstones(src), isEmpty,
          reason: 'UNGUARDED tombstone in $path');
    }
  });

  for (final path in _tombstoneSurfaces) {
    for (var branch = 0; branch < 2; branch++) {
      test('$path tombstone branch $branch fails if its own guard is removed', () {
        final src = File(path).readAsStringSync();
        final writes = _tombstones(src);
        expect(writes, hasLength(2));
        final write = writes[branch];
        final guard = RegExp(
            r"\.eq\(\s*'updated_at'\s*,[^)]*\)|"
            r"\.isFilter\(\s*'deleted_at'\s*,\s*null\s*\)");
        expect(guard.allMatches(write.text), hasLength(1));
        final mutated = src.replaceRange(write.start, write.end,
            write.text.replaceFirst(guard, ''));
        expect(_tombstones(mutated), hasLength(2));
        expect(_unguardedTombstones(mutated), hasLength(1),
            reason: 'the other branch must not supply this branch\'s guard');
      });
    }
  }

  test('an additional blind SDK tombstone is detected', () {
    for (final path in _tombstoneSurfaces) {
      final src = File(path).readAsStringSync();
      final mutated = '$src\n'
          "Future<void> newBlindDelete() async {\n"
          "  await client.from('parents').update({'deleted_at': stamp})"
          ".eq('id', id);\n}\n";
      expect(_tombstones(mutated), hasLength(3), reason: path);
      expect(_unguardedTombstones(mutated), hasLength(1), reason: path);
    }
  });

  test('an aliased tombstone cannot escape complete update classification', () {
    for (final path in _tombstoneSurfaces) {
      final src = File(path).readAsStringSync();
      for (final guard in [".eq('id', id)", ".eq('updated_at', base)"]) {
        final mutated = '$src\n'
            "Future<void> aliasDelete() async {\n"
            "  final builder = client.from('parents');\n"
            "  await builder.update({'deleted_at': stamp})$guard;\n}\n";
        expect(() => _tombstones(mutated), throwsStateError, reason: path);
      }
    }
  });

  test('planning tombstone extraction requires the stamp and callback binding', () {
    final src = File(_tombstoneSurfaces[1]).readAsStringSync();
    for (final mutated in [
      src.replaceFirst("{'deleted_at': deletedAt}", "{'other': deletedAt}"),
      src.replaceFirst('_tagMutation(stamp(), (body) => _client',
          '_tagMutation(otherStamp(), (body) => _client'),
      src.replaceFirst('.update(body)', '.update(otherBody)'),
    ]) {
      expect(mutated, isNot(src));
      expect(() => _tombstones(mutated), throwsStateError);
    }
  });

  test('the pre-9K unconditional tombstone primitives are gone', () {
    final planning = File(_tombstoneSurfaces[1]).readAsStringSync();
    final accounts = File(_tombstoneSurfaces[2]).readAsStringSync();
    // The old void, id-only sink methods must not exist anywhere.
    expect(planning.contains('Future<void> tombstone('), isFalse);
    expect(accounts.contains('Future<void> tombstoneAccount('), isFalse);
    // And the guarded surface must be present (the replacement).
    // WP-5: the CAS tombstone is the sync_cas_tombstone RPC (revision_cas),
    // reached through the shared engine; the legacy guarded tombstone remains.
    expect(planning.contains('_cas.tombstone('), isTrue);
    expect(planning.contains('guardedTombstone('), isTrue);
    expect(accounts.contains('_cas.tombstone('), isTrue);
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
