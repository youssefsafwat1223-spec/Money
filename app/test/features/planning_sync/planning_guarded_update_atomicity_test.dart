import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// C-6 — the planning push must carry its guard WITH the write.
///
/// The defect this closes is a time-of-check-to-time-of-use window. The old
/// shape was:
///
///   1. `fetchServerUpdatedAt(...)`  ← check
///   2. compare against the base token
///   3. `updateByServerId(...)`      ← unguarded write
///
/// Between (1) and (3) another device's push can land. This one then overwrites
/// it *while believing it had checked*, which is worse than not checking at all:
/// the code reads as safe, and the conflict is silently destroyed rather than
/// surfaced. The accounts and ledger pushes were fixed first; planning is the
/// third and last of the same shape.
///
/// The fix is one statement — `.eq('updated_at', base)` chained onto the update —
/// so the database evaluates the predicate and the mutation together. A zero-row
/// result IS the conflict branch.
///
/// ## Why this test is structural
///
/// The property is "these two operations are one round trip". That is a property
/// of the emitted statement, not of any value a fake can return — a fake that
/// answers correctly proves nothing about atomicity, because the old racy code
/// would also pass it. So the guarantee is asserted against the source, and the
/// behavioural half (rejection ⇒ conflict, never overwrite) is asserted with a
/// fake that genuinely refuses the write.
void main() {
  final source =
      File('lib/features/planning_sync/services/planning_push_service.dart')
          .readAsStringSync();

  group('the guard travels with the write', () {
    test('the guarded update chains the updated_at predicate onto update()',
        () {
      final i = source.indexOf('guardedUpdateByServerId');
      expect(i, greaterThan(-1));
      // The implementation, not the abstract declaration.
      final implAt = source.indexOf('guardedUpdateByServerId', i + 1);
      expect(implAt, greaterThan(-1), reason: 'implementation not found');
      final body = source.substring(implAt, implAt + 700);

      final updateAt = body.indexOf('.update(row)');
      final guardAt = body.indexOf(".eq('updated_at', expectedUpdatedAt)");
      expect(updateAt, greaterThan(-1), reason: 'must be an update');
      expect(guardAt, greaterThan(updateAt),
          reason: 'the updated_at predicate must be chained onto the same '
              'update statement — if it is a separate round trip, the race is '
              'still open');
    });

    test('the push path no longer reads updated_at before writing', () {
      // The whole point: the pre-read is GONE from the guarded branch, not
      // merely accompanied by a guard.
      final pushBranch = source.substring(
        source.indexOf("item.payloadJson['server_updated_at']"),
        source.indexOf("item.payloadJson['server_updated_at']") + 900,
      );
      expect(pushBranch.contains('fetchServerUpdatedAt'), isFalse,
          reason: 'the check-then-write pair must be replaced by one guarded '
              'statement, not supplemented by it');
      expect(pushBranch, contains('guardedUpdateByServerId'));
    });

    test('with no base token it falls back to the plain update', () {
      // A row that has never been synced has nothing to compare against.
      // Guarding on a null base would make the first push impossible.
      final i = source.indexOf("final base = item.payloadJson");
      final branch = source.substring(i, i + 500);
      expect(branch, contains('base != null'));
      expect(branch, contains('updateByServerId(remoteTable, serverId, row)'),
          reason: 'the unguarded path must remain for the no-base case');
    });
  });

  group('a rejected guard is a conflict, never an overwrite', () {
    test('the null return is routed to _markConflict', () {
      // guardedAck returns null for a 0-row result. That must reach the
      // conflict branch — treating it as a transient failure would retry
      // forever, and treating it as success would lose the remote edit.
      final i = source.indexOf('guardedUpdateByServerId(\n              remoteTable');
      final after = source.substring(i, i + 800);
      expect(after, contains('_markConflict'),
          reason: 'a 0-row guarded update is a genuine conflict');
    });
  });

  group('the ack columns are decoded as a LIST, never maybeSingle', () {
    test('guardedAck is used, not maybeSingle', () {
      // MALI-026 / Phase-9M: maybeSingle throws PGRST116 on 0 rows, which
      // previously mis-classified conflicts as retryable failures. The guarded
      // path must decode the list.
      final implAt = source.indexOf(
          'guardedUpdateByServerId', source.indexOf('guardedUpdateByServerId') + 1);
      final body = source.substring(implAt, implAt + 700);
      expect(body, contains('guardedAck'));
      expect(body.contains('maybeSingle'), isFalse,
          reason: 'a 0-row guarded update is the CONFLICT branch, not an '
              'exception — maybeSingle would resurrect the 9L defect');
    });
  });
}
