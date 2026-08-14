// MALI-026 (Phase-9M) — the guarded-mutation cardinality contract: 0/1/>1 by
// LIST length, NOT by any English PGRST116 wording.
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/sync/guarded_mutation.dart';

void main() {
  test('0 rows → null (the expected zero-match / conflict branch)', () {
    expect(guardedAck(const [], 'surface'), isNull);
  });

  test('1 row → that row (ACK decoded)', () {
    expect(
        guardedAck([
          {'id': 'a', 'updated_at': 't', 'revision': 2}
        ], 'surface'),
        {'id': 'a', 'updated_at': 't', 'revision': 2});
  });

  test(
      '>1 rows → GuardedMutationCardinalityError (invariant violation — NOT a '
      'conflict, NOT silently the first row)', () {
    expect(
        () => guardedAck([
              {'id': 'a'},
              {'id': 'b'}
            ], 'planning.casUpdate[user_goals]'),
        throwsA(isA<GuardedMutationCardinalityError>()
            .having((e) => e.rowCount, 'rowCount', 2)
            .having((e) => e.surface, 'surface',
                'planning.casUpdate[user_goals]')));
  });

  test('the zero branch is length-based, never message-based (version-proof)',
      () {
    // A [] is the zero-match regardless of any PostgREST error wording; the
    // helper never inspects a "Results contain 0 rows" / "The result contains 0
    // rows" string.
    expect(guardedAck(const <Map<String, dynamic>>[], 'x'), isNull);
  });
}
