import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// C-6 — the guarded UPDATE must be atomic, not read-then-write.
///
/// `AccountsPushService` (and its ledger/planning siblings) guard a concurrent
/// remote edit like this:
///
///   1. `fetchAccountUpdatedAt(serverId)`      ← read the server's base
///   2. compare it against the base captured at enqueue
///   3. `updateAccountByServerId(serverId, row)`  ← blind write by id
///
/// Steps 1 and 3 are separate round-trips, so a remote write landing between
/// them is silently clobbered: the guard passed against a value that is no
/// longer true by the time the write executes. Classic TOCTOU.
///
/// The correct pattern is already in this very file, used for tombstones:
/// chain `.eq('updated_at', expectedUpdatedAt)` onto the UPDATE so the database
/// itself enforces the precondition, and treat 0 affected rows as the conflict.
/// The fix is to apply the pattern the codebase already trusts.
void main() {
  String read(String p) => File(p).readAsStringSync();

  final accounts = read(
    'lib/features/planning_sync/services/accounts_push_service.dart',
  );

  /// Extracts a method body from the IMPLEMENTATION class.
  ///
  /// Searching the whole file would match the abstract declaration first, which
  /// has no body — and a test that reads an empty body proves nothing.
  String body(String src, String signature) {
    final classStart = src.indexOf('class SupabaseAccountsRemoteSink');
    expect(classStart, greaterThan(-1), reason: 'sink implementation missing');
    final start = src.indexOf(signature, classStart);
    expect(start, greaterThan(-1), reason: 'missing $signature');
    final next = src.indexOf('@override', start + signature.length);
    return src.substring(start, next == -1 ? src.length : next);
  }

  test('the guarded update binds the base into the statement itself', () {
    final impl = body(accounts, 'Future<Map<String, dynamic>?> guardedUpdateAccount');
    expect(
      impl,
      contains(".eq('updated_at'"),
      reason: 'without this predicate the database cannot enforce the guard, '
          'and a remote write in the read→write window is clobbered',
    );
    expect(impl, contains(".eq('id'"));
  });

  test('it matches the tombstone pattern already trusted in this file', () {
    // The tombstone path has been atomic all along. The update path being
    // read-then-write was an inconsistency, not a considered trade-off.
    final tombstone =
        body(accounts, 'Future<Map<String, dynamic>?> guardedTombstoneAccount');
    expect(tombstone, contains(".eq('updated_at'"));
  });

  test('zero affected rows is decoded as a conflict, never a throw', () {
    // A guarded write that matches nothing means someone else won the race.
    // That is a conflict to resolve, not an exception to swallow.
    final impl = body(accounts, 'Future<Map<String, dynamic>?> guardedUpdateAccount');
    expect(impl, contains('guardedAck'));
  });

  test('the push path no longer reads the base in a separate round-trip', () {
    // The whole defect is the gap between the read and the write. If the
    // fetch-then-update sequence survives anywhere in the update path, the race
    // survives with it.
    final pushBody = accounts.substring(
      accounts.indexOf('Future<AccountsPushResult> push()'),
    );
    final fetchAt = pushBody.indexOf('fetchAccountUpdatedAt');
    if (fetchAt != -1) {
      // Permitted only for CLASSIFYING a failed guarded write (deciding whether
      // the row vanished or was overwritten) — never before it.
      final guardedAt = pushBody.indexOf('guardedUpdateAccount');
      expect(guardedAt, greaterThan(-1),
          reason: 'the guarded update must be used');
      expect(
        fetchAt,
        greaterThan(guardedAt),
        reason: 'reading the base BEFORE the write is the TOCTOU itself',
      );
    }
  });

  group('ledger push has the same guarantee', () {
    final ledger = read(
      'lib/features/capture/services/ledger_push_service.dart',
    );

    test('the update binds the base into the statement', () {
      // Same TOCTOU shape as accounts: SELECT updated_at, compare, then blind
      // write by id. Two round-trips, so a remote write in the gap was lost.
      final push = ledger.substring(
        ledger.indexOf('_PushOutcome> _pushUpdate'),
        ledger.indexOf('_PushOutcome> _pushDelete'),
      );
      expect(push, contains(".eq('updated_at', base)"),
          reason: 'the guard predicate must travel with the write');
    });

    test('it no longer SELECTs updated_at before writing', () {
      // The separate read IS the vulnerability window.
      final push = ledger.substring(
        ledger.indexOf('_PushOutcome> _pushUpdate'),
        ledger.indexOf('_PushOutcome> _pushDelete'),
      );
      expect(push, isNot(contains('.maybeSingle()')),
          reason: 'a pre-write read of the base reinstates the race');
    });

    test('the tombstone branch was already atomic — the pattern existed', () {
      expect(ledger, contains(".eq('updated_at', base)"));
    });
  });
}
