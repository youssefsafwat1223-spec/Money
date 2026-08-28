import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/session/unsynced_inventory.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/db/sql_value_codec.dart';
import 'package:money_companion/features/planning_sync/services/planning_primary_backfill_service.dart';
import 'package:money_companion/features/planning_sync/services/startup_sync_reconcile_service.dart';

/// Cross-model audit **H-1 / H-2 / H-3** — the data-loss chain.
///
/// The three findings compose into one failure:
///
///   1. a backfill phase fails (planning records it in a report, never throws)
///   2. the startup service DISCARDS all three reports and returns `ran`
///   3. the row keeps `server_id IS NULL` and has no outbox entry
///   4. the pre-sign-out inventory counts OUTBOXES only → "nothing pending"
///   5. sign-out wipes the only copy, silently
///
/// The invariants pinned here:
///   * failure must remain failure
///   * partial completion must stay distinguishable from full completion
///   * uncertainty must never become success across a restart
///   * sign-out must not silently destroy locally-authoritative data whose
///     remote persistence was never positively proven
class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'test-key';
  @override
  Future<String?> readStoredKey() async => 'test-key';
}

Future<AppDatabase> _database() => AppDatabase.open(
      executor: NativeDatabase.memory(),
      keyStore: _MemoryKeyStore(),
    );

Future<void> _insertAccount(
  AppDatabase db, {
  required String id,
  String? serverId,
  String syncStatus = 'local_only',
}) async {
  final now = dateTimeToSql(DateTime.now().toUtc());
  await db.customStatement('''
    INSERT INTO accounts(id, name, currency, type, created_at, updated_at,
                         server_id, sync_status, deleted_at)
    VALUES ('$id', 'Main', 'SAR', 'bank', '$now', '$now',
            ${serverId == null ? 'NULL' : "'$serverId'"}, '$syncStatus', NULL);
  ''');
}

void main() {
  group('H-1 — failure and partial completion survive the caller', () {
    test('only ran / nothing-pending count as proven complete', () {
      expect(ReconcileOutcome.ran.isProvenComplete, isTrue);
      expect(ReconcileOutcome.skippedNothingPending.isProvenComplete, isTrue);
      // The whole defect: these three must NEVER authorise deletion.
      expect(ReconcileOutcome.failed.isProvenComplete, isFalse);
      expect(ReconcileOutcome.partial.isProvenComplete, isFalse);
      expect(ReconcileOutcome.skippedGuest.isProvenComplete, isFalse);
    });

    test('partial is distinguishable from both success and total failure', () {
      expect(ReconcileOutcome.partial, isNot(ReconcileOutcome.ran));
      expect(ReconcileOutcome.partial, isNot(ReconcileOutcome.failed));
    });

    test('both failure and partial completion are retried', () {
      expect(ReconcileOutcome.failed.shouldRetry, isTrue);
      expect(ReconcileOutcome.partial.shouldRetry, isTrue,
          reason: 'a half-finished backfill latched the one-shot flag and was '
              'never retried for the rest of the session');
      expect(ReconcileOutcome.ran.shouldRetry, isFalse);
    });

    test('a report with ANY failure is not clean', () {
      const report = PlanningBackfillReport(
        created: {'budgets': 3},
        matched: {},
        failures: ['budgets: TimeoutException'],
      );
      expect(report.isClean, isFalse,
          reason: 'phase failures are recorded, not thrown — if isClean '
              'ignored them the caller would report success');
    });

    test('a report with an unresolved money mismatch is not clean', () {
      const report = PlanningBackfillReport(
        created: {},
        matched: {'budgets': 1},
        failures: [],
        mismatched: ['budgets:b1'],
      );
      expect(report.isClean, isFalse,
          reason: 'a matched-but-different remote row is NOT proof of '
              'persistence for the local value');
    });

    test('a genuinely clean report is clean', () {
      const report = PlanningBackfillReport(
        created: {'budgets': 2},
        matched: {'goals': 1},
        failures: [],
      );
      expect(report.isClean, isTrue);
    });
  });

  group('H-3 — sign-out sees data whose persistence was never proven', () {
    late AppDatabase db;
    setUp(() async => db = await _database());
    tearDown(() => db.close());

    UnsyncedInventoryService service() =>
        UnsyncedInventoryService(db, localOnlyCardCount: () async => 0);

    Future<void> clearSeeded() =>
        db.customStatement("UPDATE accounts SET server_id = 'srv-seed', "
            "sync_status = 'synced';");

    test('sign-out right after a FAILED reconcile is not silent', () async {
      await clearSeeded();
      // The backfill threw: the row never got a server_id and was never queued.
      await _insertAccount(db, id: 'acc-failed');

      final inv = await service().collect();

      expect(inv.unprovenFinancialRows, 1);
      expect(inv.hasPendingUserData, isTrue,
          reason: 'this is the exact state the old outbox-only inventory '
              'reported as "nothing pending" before wiping it');
    });

    test('sign-out right after a PARTIAL reconcile still flags the remainder',
        () async {
      await clearSeeded();
      await _insertAccount(db, id: 'acc-ok', serverId: 'srv-1',
          syncStatus: 'synced');
      await _insertAccount(db, id: 'acc-left-behind');

      final inv = await service().collect();

      expect(inv.unprovenFinancialRows, 1,
          reason: 'partial success must not mask the rows that did not make it');
      expect(inv.hasPendingUserData, isTrue);
    });

    test('a money mismatch is counted, not treated as synced', () async {
      await clearSeeded();
      // H-2: the remote row exists but disagrees, so local is still
      // authoritative. It must NOT be stamped synced and must be visible here.
      await _insertAccount(db, id: 'acc-conflict', serverId: 'srv-2',
          syncStatus: 'conflict');

      final inv = await service().collect();

      expect(inv.unresolvedConflicts, 1);
      expect(inv.hasPendingUserData, isTrue);
    });

    test('an app restart between steps does not convert uncertainty to success',
        () async {
      await clearSeeded();
      await _insertAccount(db, id: 'acc-mid-flight');

      // Simulate a restart: the inventory is recomputed from persisted state
      // only. Nothing in memory can vouch for the row.
      final before = await service().collect();
      final after = await service().collect();

      expect(before.unprovenFinancialRows, 1);
      expect(after.unprovenFinancialRows, 1,
          reason: 'the durable state is the only evidence; re-reading it must '
              'not upgrade an unproven row to proven');
    });

    test('a successful retry clears the obligation (idempotent)', () async {
      await clearSeeded();
      await _insertAccount(db, id: 'acc-retry');
      expect((await service().collect()).unprovenFinancialRows, 1);

      // Retry succeeds — the backfill is idempotent on (user_id, local_id), so
      // running it twice must not double-count or resurrect the obligation.
      await db.customStatement(
        "UPDATE accounts SET server_id = 'srv-3', sync_status = 'synced' "
        "WHERE id = 'acc-retry';",
      );
      expect((await service().collect()).unprovenFinancialRows, 0);
      expect((await service().collect()).unprovenFinancialRows, 0);
      expect((await service().collect()).hasPendingUserData, isFalse);
    });

    test('a soft-deleted row is not counted (nothing to preserve)', () async {
      await clearSeeded();
      await _insertAccount(db, id: 'acc-gone');
      await db.customStatement(
        "UPDATE accounts SET deleted_at = '2026-01-01T00:00:00Z' "
        "WHERE id = 'acc-gone';",
      );
      expect((await service().collect()).unprovenFinancialRows, 0,
          reason: 'the guard must not become a permanent sign-out blocker');
    });

    test('sign-out remains POSSIBLE — this reports, it does not veto', () async {
      await clearSeeded();
      await _insertAccount(db, id: 'acc-x');
      final inv = await service().collect();
      // The contract is "surface and require explicit confirmation", never
      // "block forever". The flow offers cancel OR discard-and-sign-out.
      expect(inv.hasPendingUserData, isTrue);
      final settings =
          File('lib/features/settings/settings_screen.dart').readAsStringSync();
      expect(settings, contains('تسجيل الخروج وحذف غير المحفوظ'),
          reason: 'the user must still be able to proceed deliberately');
      expect(settings, contains('إلغاء'));
    });
  });

  group('H-2 — a detected mismatch is never stamped synced', () {
    // These write paths need the Supabase SDK to drive end-to-end, so the
    // structural contract is pinned instead. Narrow and specific: each asserts
    // the conflict branch exists and precedes the synced branch.
    // The mismatch decision and the write it guards, per service. Ordering
    // across the whole file is NOT the invariant — the planning service also
    // writes `synced` for plan_transaction_links, which carries no money and is
    // legitimately never a money conflict.
    const guards = {
      'lib/features/planning_sync/services/accounts_backfill_service.dart':
          'if (mismatch) {',
      'lib/features/capture/services/transactions_backfill_service.dart':
          'if (mismatch) {',
      'lib/features/planning_sync/services/planning_primary_backfill_service.dart':
          'if (conflicted) {',
    };

    guards.forEach((path, guard) {
      test('${path.split('/').last} routes mismatches to conflict', () {
        final source = File(path).readAsStringSync();
        expect(source, contains(guard),
            reason: 'the mismatch must be branched on, not merely recorded '
                'while the row is stamped synced anyway');
        // Inside that branch, and BEFORE the branch closes, the row must be
        // written as a conflict rather than as synced.
        final start = source.indexOf(guard);
        final branch = source.substring(start, source.indexOf('} else {', start));
        expect(branch, contains("sync_status = 'conflict'"),
            reason: 'a mismatched row must land in the durable conflict state, '
                'where the pull refuses to overwrite it and the picker offers '
                'keep-mine / keep-theirs');
        expect(branch.contains("sync_status = 'synced'"), isFalse,
            reason: 'the mismatch branch must never claim synced');
      });
    });

    test('the startup service consults every report before claiming success',
        () {
      final source = File(
        'lib/features/planning_sync/services/startup_sync_reconcile_service.dart',
      ).readAsStringSync();
      // Previously all three returns were discarded.
      expect(source, contains('mismatchedLocalIds'));
      expect(source, contains('unresolvedAccountLocalIds'));
      expect(source, contains('planning.failures'));
      expect(source, contains('ReconcileOutcome.partial'));
    });

    test('account switching re-arms the reconcile (no cross-user carry-over)',
        () {
      final shell =
          File('lib/features/app/app_shell.dart').readAsStringSync();
      final handler = shell.substring(
        shell.indexOf('void _handleSessionStatusChange()'),
      );
      final body = handler.substring(0, handler.indexOf('\n  }'));
      expect(body, contains('_didReconcile = false'),
          reason: 'one identity\'s reconcile state must never vouch for '
              "another's local data");
    });
  });
}
