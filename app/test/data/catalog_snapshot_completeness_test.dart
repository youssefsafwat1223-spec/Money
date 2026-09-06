import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/catalog/catalog_sync_service.dart';

/// The authoritative-snapshot contract.
///
/// Revocation is one-way on the device (`retainOnlyServable` deactivates but
/// never reactivates), and a device whose version already matches the server
/// will not be sent the rules again. So a WRONG revocation cannot self-heal,
/// which makes "refuse to act unless the snapshot proves itself" the only safe
/// rule. Three ways a snapshot can lie, all of which must be inert:
///   * malformed body            (null / string / object instead of a list)
///   * TRUNCATED page            (count disagrees with what arrived)
///   * stale / torn read         (snapshot describes another catalog version)
void main() {
  Map<String, Object?> body({
    Object? snapshot,
    int version = 48,
  }) =>
      {
        'meta': {'category': 'parsers', 'version': version, 'since_version': 0},
        'items': const [],
        'deleted_ids': const [],
        if (snapshot != null) 'servable_snapshot': snapshot,
      };

  Map<String, Object?> goodSnapshot({
    List<String> ids = const ['a', 'b'],
    int? count,
    int max = 500,
    int version = 48,
    bool complete = true,
  }) =>
      {
        'complete': complete,
        'ids': ids,
        'count': count ?? ids.length,
        'max': max,
        'catalog_version': version,
      };

  group('a snapshot must prove itself before anything is revoked', () {
    test('a complete, counted, current snapshot IS authoritative', () {
      // Non-vacuity first: if this did not pass, every rejection below would
      // hold trivially and the contract would revoke nothing, ever.
      expect(
        debugAuthoritativeServableIds(body(snapshot: goodSnapshot()), 48),
        ['a', 'b'],
      );
    });

    test('an empty but complete snapshot is authoritative — current prod state',
        () {
      // Production has zero validated parsers. "Revoke everything" is the
      // correct instruction there, and must not be confused with a bad body.
      expect(
        debugAuthoritativeServableIds(
            body(snapshot: goodSnapshot(ids: const [])), 48),
        isEmpty,
      );
    });

    test('an absent snapshot revokes nothing (old server)', () {
      expect(debugAuthoritativeServableIds(body(), 48), isNull);
    });

    test('a malformed snapshot revokes nothing', () {
      for (final bad in <Object>[
        'all',
        42,
        const ['a'],
      ]) {
        expect(debugAuthoritativeServableIds(body(snapshot: bad), 48), isNull,
            reason: '$bad must not be treated as authoritative');
      }
    });

    test('complete:false revokes nothing', () {
      expect(
        debugAuthoritativeServableIds(
            body(snapshot: goodSnapshot(complete: false)), 48),
        isNull,
      );
    });

    test('a TRUNCATED snapshot revokes nothing', () {
      // The count the server computed disagrees with what arrived — the exact
      // shape a paginated result would take.
      expect(
        debugAuthoritativeServableIds(
            body(snapshot: goodSnapshot(ids: const ['a'], count: 900)), 48),
        isNull,
      );
    });

    test('a snapshot exceeding the declared maximum revokes nothing', () {
      expect(
        debugAuthoritativeServableIds(
            body(snapshot: goodSnapshot(ids: const ['a', 'b'], max: 1)), 48),
        isNull,
      );
    });

    test('a snapshot for a DIFFERENT catalog version revokes nothing', () {
      // A torn read across concurrent writes, or a stale cached body.
      expect(
        debugAuthoritativeServableIds(
            body(snapshot: goodSnapshot(version: 47), version: 48), 48),
        isNull,
      );
    });

    test('ids that are not strings revoke nothing', () {
      expect(
        debugAuthoritativeServableIds(
            body(snapshot: {
              'complete': true,
              'ids': 'a,b',
              'count': 2,
              'max': 500,
              'catalog_version': 48,
            }),
            48),
        isNull,
      );
    });
  });
}
