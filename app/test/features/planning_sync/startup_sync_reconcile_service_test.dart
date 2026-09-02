import 'dart:io';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/db/money_v30_backfill.dart';
import 'package:money_companion/data/db/sql_value_codec.dart';
import 'package:money_companion/features/planning_sync/services/startup_sync_reconcile_service.dart';

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'test-key';
  @override
  Future<String?> readStoredKey() async => 'test-key';
}

Future<void> _insertAccount(
  AppDatabase db, {
  String id = 'acc-1',
  String? serverId,
  bool deleted = false,
}) async {
  final now = dateTimeToSql(DateTime.now().toUtc());
  await db.customStatement('''
    INSERT INTO accounts(id, name, currency, type, created_at, updated_at,
                         server_id, deleted_at)
    VALUES ('$id', 'Main', 'SAR', 'bank', '$now', '$now',
            ${serverId == null ? 'NULL' : "'$serverId'"},
            ${deleted ? "'$now'" : 'NULL'});
  ''');
  await backfillNonPlanningMoneyV30(db);
}

Future<void> _insertTx(
  AppDatabase db, {
  String id = 'tx-1',
  String? serverId,
}) async {
  final now = dateTimeToSql(DateTime.now().toUtc());
  await db.customStatement('''
    INSERT INTO transactions(id, amount, currency, type, source, occurred_at,
                             raw_message, parse_confidence, status,
                             created_at, updated_at, server_id)
    VALUES ('$id', 100.0, 'SAR', 'payment', 'bank', '$now', '', 0.9,
            'confirmed', '$now', '$now',
            ${serverId == null ? 'NULL' : "'$serverId'"});
  ''');
  await backfillNonPlanningMoneyV30(db);
}

Future<void> _queueTx(AppDatabase db, String txId) async {
  final now = dateTimeToSql(DateTime.now().toUtc());
  await db.customStatement('''
    INSERT INTO ledger_sync_outbox(id, transaction_id, operation, payload_json,
                                   attempt_count, created_at, updated_at)
    VALUES ('ob-$txId', '$txId', 'create', '{}', 0, '$now', '$now');
  ''');
}

void main() {
  late AppDatabase db;

  setUp(() async {
    db = await AppDatabase.open(
      executor: NativeDatabase.memory(),
      keyStore: _MemoryKeyStore(),
    );
    // A fresh DB seeds a default account (the migration-created B7 row) — clear
    // financial tables so each test controls the exact reconcile state.
    for (final t in const [
      'accounts',
      'transactions',
      'budgets',
      'goals',
      'subscriptions',
      'plans',
      'ledger_sync_outbox',
      'planning_sync_outbox',
    ]) {
      await db.customStatement('DELETE FROM $t;');
    }
  });

  tearDown(() async => db.close());

  StartupSyncReconcileService service() =>
      StartupSyncReconcileService(db: db, getAuthUserId: () async => 'u1');

  group('hasUnsyncedLocalData guard', () {
    test('false when there is no local data', () async {
      expect(await service().hasUnsyncedLocalData(), isFalse);
    });

    test('true for an account without a server_id', () async {
      await _insertAccount(db);
      expect(await service().hasUnsyncedLocalData(), isTrue);
    });

    test('false once the account is synced (server_id set)', () async {
      await _insertAccount(db, serverId: 'srv-1');
      expect(await service().hasUnsyncedLocalData(), isFalse);
    });

    test('ignores a soft-deleted unsynced account', () async {
      await _insertAccount(db, serverId: null, deleted: true);
      expect(await service().hasUnsyncedLocalData(), isFalse);
    });

    test('true for a transaction without a server_id', () async {
      await _insertTx(db);
      expect(await service().hasUnsyncedLocalData(), isTrue);
    });

    test('false when the unsynced transaction is already on the outbox',
        () async {
      await _insertTx(db);
      await _queueTx(db, 'tx-1');
      // The outbox push owns queued rows; the reconcile must not double-handle.
      expect(await service().hasUnsyncedLocalData(), isFalse);
    });

    test('true for a planning row (budget) without a server_id', () async {
      final catId = (await db
              .customSelect(
                  "SELECT id FROM categories WHERE key = 'restaurants' LIMIT 1;")
              .getSingle())
          .read<String>('id');
      await db.customStatement('''
        INSERT INTO budgets(id, category_id, amount, period, start_date,
          is_active)
        VALUES ('b1', '$catId', 500.0, 'monthly', '2026-07-01', 1);
      ''');
      // A never-uploaded budget must trip the guard — otherwise the sign-out
      // wipe destroys it permanently (no server copy to pull back).
      expect(await service().hasUnsyncedLocalData(), isTrue);
    });

    test('false when the unsynced planning row is already on the outbox',
        () async {
      final catId = (await db
              .customSelect(
                  "SELECT id FROM categories WHERE key = 'restaurants' LIMIT 1;")
              .getSingle())
          .read<String>('id');
      await db.customStatement('''
        INSERT INTO budgets(id, category_id, amount, period, start_date,
          is_active)
        VALUES ('b1', '$catId', 500.0, 'monthly', '2026-07-01', 1);
      ''');
      final now = dateTimeToSql(DateTime.now().toUtc());
      await db.customStatement('''
        INSERT INTO planning_sync_outbox(id, entity_type, entity_id, operation,
          payload_json, attempt_count, created_at, updated_at)
        VALUES ('ob-b1', 'budget', 'b1', 'create', '{}', 0, '$now', '$now');
      ''');
      expect(await service().hasUnsyncedLocalData(), isFalse,
          reason: 'the outbox push owns queued rows');
    });

    test('false when every row is synced or queued', () async {
      await _insertAccount(db, serverId: 'srv-1');
      await _insertTx(db, id: 'tx-a', serverId: 'srv-a');
      await _insertTx(db, id: 'tx-b'); // unsynced…
      await _queueTx(db, 'tx-b'); // …but queued
      expect(await service().hasUnsyncedLocalData(), isFalse);
    });
  });

  test('run() skips when Supabase is not configured (guest / test env)',
      () async {
    // SupabaseConfig.isConfigured is false under test, so run() short-circuits
    // to a guest skip without touching the network.
    await _insertTx(db);
    final outcome = await service().run();
    expect(outcome, ReconcileOutcome.skippedGuest);
  });
  // ── C-3 consent gate ─────────────────────────────────────────────────────
  //
  // `run()` returns `skippedGuest` before reaching the consent check whenever
  // SupabaseConfig is unconfigured, which is always true in a unit test, so the
  // gate cannot be exercised through the public entry point here. It is pinned
  // by source contract instead — the same technique this repository already
  // uses for the ads and SMS-capture invariants — plus the egress inventory
  // test, which now fails if this file stops being a gated decision.
  group('C-3 — the backfills are consent-gated (source contract)', () {
    final service = File(
      'lib/features/planning_sync/services/startup_sync_reconcile_service.dart',
    ).readAsStringSync();

    test('the gate defaults to DENY', () {
      // A caller that forgets to pass consent must get no network, not silent
      // egress. This is the same default the sibling push services use.
      expect(service, contains('_denyEgressByDefault'));
      expect(service, contains('_mayEgress = mayEgress ?? _denyEgressByDefault'));
      expect(service, contains('static Future<bool> _denyEgressByDefault() async => false;'));
    });

    test('consent is checked BEFORE any backfill is constructed', () {
      final gate = service.indexOf('if (!await _mayEgress())');
      expect(gate, greaterThan(-1), reason: 'the consent gate must exist');
      for (final backfill in const [
        'AccountsBackfillService(',
        'TransactionsBackfillService(',
        'PlanningPrimaryBackfillService(',
      ]) {
        final at = service.indexOf(backfill);
        if (at == -1) continue; // not driven from here
        expect(gate, lessThan(at),
            reason: '$backfill runs before consent is checked');
      }
    });

    test('refusal is its OWN outcome, not folded into an existing one', () {
      // `skippedNothingPending` would be a lie (there IS pending data) and
      // `blockedUnverifiedTransport` would be a different lie (that is a
      // capability problem the app can fix; this is the user's answer).
      expect(service, contains('skippedNoConsent'));
      expect(service, contains('return ReconcileOutcome.skippedNoConsent;'));
    });

    test('the DI provider passes the real consent authority', () {
      // A gate defaulting to deny is only useful if production actually
      // supplies the answer — otherwise the feature is silently dead.
      final di = File('lib/core/di/app_providers.dart').readAsStringSync();
      final at = di.indexOf('StartupSyncReconcileService(');
      expect(at, greaterThan(-1));
      final block = di.substring(at, di.indexOf(');', at));
      expect(block, contains('mayEgress:'));
      expect(block, contains('EgressClass.financialSync'));
    });
  });

}
