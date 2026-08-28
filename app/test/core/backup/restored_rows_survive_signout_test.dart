import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/backup/backup_snapshot_builder.dart';
import 'package:money_companion/core/session/unsynced_inventory.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';

/// Cross-model audit **H-22** — "restored financial rows can be wiped before
/// ever syncing" — RE-VERIFICATION against the post-Batch-5 implementation.
///
/// This file changes no production code. It exists to prove, rather than
/// assume, that the Batch 5 sign-out inventory already covers the restored-row
/// shape:
///
///   * the snapshot builder exports NO sync columns, and `restorableColumns`
///     whitelists none, so every restored row lands with `server_id = NULL`
///     and `sync_status = NULL`;
///   * restore enqueues nothing (it relies on the startup reconcile), so a
///     restored row has no outbox entry either.
///
/// That is exactly `unprovenFinancialRows`' predicate. If any financial family
/// were missing from it, restored rows of that family would still be wiped
/// silently — so every family is checked individually.
class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'test-key';
  @override
  Future<String?> readStoredKey() async => 'test-key';
}

void main() {
  late AppDatabase db;

  setUp(() async {
    db = await AppDatabase.open(
      executor: NativeDatabase.memory(),
      keyStore: _MemoryKeyStore(),
    );
    // Counting-only test: FK plumbing is irrelevant to the predicate.
    await db.customStatement('PRAGMA foreign_keys = OFF;');
    // Neutralise the migration-seeded default account so each family's
    // contribution is measured in isolation.
    await db.customStatement(
      "UPDATE accounts SET server_id = 'srv-seed', sync_status = 'synced';",
    );
  });
  tearDown(() => db.close());

  UnsyncedInventoryService service() =>
      UnsyncedInventoryService(db, localOnlyCardCount: () async => 0);

  Future<int> unproven() async =>
      (await service().collect()).unprovenFinancialRows;

  group('H-22 — the restored-row SHAPE is what the inventory looks for', () {
    test('the snapshot carries no sync columns, so restores land unproven', () {
      // The premise the whole finding rests on, asserted rather than assumed.
      const columns = BackupSnapshotBuilder.restorableColumns;
      for (final entry in columns.entries) {
        for (final forbidden in const [
          'server_id',
          'sync_status',
          'synced_at',
          'server_updated_at',
        ]) {
          expect(entry.value.contains(forbidden), isFalse,
              reason: '${entry.key} would restore a sync column, which could '
                  'make an unsynced row LOOK proven');
        }
      }
    });
  });

  group('H-22 — every restored financial family is counted', () {
    // One row per family, in the restored shape: server_id NULL, no outbox,
    // not soft-deleted. Each must raise the count by exactly one.
    final seeds = <String, String>{
      'accounts': """
        INSERT INTO accounts(id,name,currency,type,created_at,updated_at)
        VALUES('r-acc','Restored','SAR','bank','2026-01-01T00:00:00Z','2026-01-01T00:00:00Z');""",
      'transactions': """
        INSERT INTO transactions(id,account_id,amount,amount_minor,currency,category_id,
          type,source,status,raw_message,parse_confidence,occurred_at,created_at,updated_at)
        VALUES('r-tx','r-acc',10.0,1000,'SAR',NULL,'expense','manual','confirmed','',1.0,
          '2026-01-01T00:00:00Z','2026-01-01T00:00:00Z','2026-01-01T00:00:00Z');""",
      'budgets': """
        INSERT INTO budgets(id,category_id,currency,amount,amount_minor,period,start_date,
          is_active,last_notified_spent_amount,last_notified_spent_amount_minor,
          last_notified_period_start,show_on_header)
        VALUES('r-bud','c1','SAR',10.0,1000,'monthly','2026-01-01T00:00:00Z',1,0,0,
          '2026-01-01T00:00:00Z',0);""",
      'goals': """
        INSERT INTO goals(id,name,currency,target_amount,target_amount_minor,
          saved_amount,saved_amount_minor,vault_skin,status,created_at,
          last_notified_saved_amount,last_notified_saved_amount_minor)
        VALUES('r-goal','G','SAR',100.0,10000,0,0,'default','active',
          '2026-01-01T00:00:00Z',0,0);""",
      'goal_contributions': """
        INSERT INTO goal_contributions(id,goal_id,amount,amount_minor,created_at)
        VALUES('r-gc','r-goal',5.0,500,'2026-01-01T00:00:00Z');""",
      'subscriptions': """
        INSERT INTO subscriptions(id,merchant_id,name,amount,amount_minor,currency,type,
          period,frequency,next_due_date,reminder_on,is_confirmed,status,created_at)
        VALUES('r-sub','m1','S',9.0,900,'SAR','subscription','monthly','monthly',
          '2026-02-01T00:00:00Z',1,1,'active','2026-01-01T00:00:00Z');""",
      'bill_payments': """
        INSERT INTO bill_payments(id,bill_id,amount,amount_minor,currency,period_start,
          period_end,paid_at)
        VALUES('r-bp','r-sub',9.0,900,'SAR','2026-01-01T00:00:00Z','2026-02-01T00:00:00Z',
          '2026-01-05T00:00:00Z');""",
      'plans': """
        INSERT INTO plans(id,name,budget_amount,budget_amount_minor,currency,start_date,
          end_date,status,created_at)
        VALUES('r-plan','P',50.0,5000,'SAR','2026-01-01T00:00:00Z','2026-02-01T00:00:00Z',
          'active','2026-01-01T00:00:00Z');""",
    };

    for (final entry in seeds.entries) {
      test('${entry.key}: a restored row is reported as unproven', () async {
        final before = await unproven();
        await db.customStatement(entry.value);
        final after = await unproven();
        expect(after, before + 1,
            reason: '${entry.key} restored rows are invisible to the '
                'pre-sign-out inventory and would be wiped silently');
      });
    }

    test('a full restore of every family is counted in aggregate', () async {
      for (final sql in seeds.values) {
        await db.customStatement(sql);
      }
      final inv = await service().collect();
      expect(inv.unprovenFinancialRows, seeds.length);
      expect(inv.hasPendingUserData, isTrue,
          reason: 'sign-out must surface a confirmation, not wipe silently');
    });
  });

  group('H-22 — the count clears only through genuine proof', () {
    test('marking rows synced (a successful backfill) clears the warning',
        () async {
      await db.customStatement("""
        INSERT INTO accounts(id,name,currency,type,created_at,updated_at)
        VALUES('r-acc','Restored','SAR','bank','2026-01-01T00:00:00Z','2026-01-01T00:00:00Z');""");
      expect(await unproven(), 1);

      await db.customStatement(
        "UPDATE accounts SET server_id = 'srv-1', sync_status = 'synced' "
        "WHERE id = 'r-acc';",
      );
      expect(await unproven(), 0,
          reason: 'once the backfill proves persistence the obligation ends');
    });

    test('an outbox-queued restored row is not double-counted', () async {
      await db.customStatement("""
        INSERT INTO accounts(id,name,currency,type,created_at,updated_at)
        VALUES('r-acc','Restored','SAR','bank','2026-01-01T00:00:00Z','2026-01-01T00:00:00Z');""");
      expect(await unproven(), 1);
      await db.customStatement("""
        INSERT INTO planning_sync_outbox(id,entity_type,entity_id,operation,payload_json,
          created_at,updated_at)
        VALUES('o1','account','r-acc','create','{}','2026-01-01T00:00:00Z',
          '2026-01-01T00:00:00Z');""");
      expect(await unproven(), 0,
          reason: 'a queued row is the outbox count\'s responsibility');
      // …but it is still pending overall, so sign-out still warns.
      expect((await service().collect()).hasPendingUserData, isTrue);
    });
  });

  group('H-22 / Q7 — tombstones do not become a permanent warning', () {
    test('a soft-deleted restored row is NOT counted', () async {
      await db.customStatement("""
        INSERT INTO budgets(id,category_id,currency,amount,amount_minor,period,start_date,
          is_active,last_notified_spent_amount,last_notified_spent_amount_minor,
          last_notified_period_start,show_on_header,deleted_at)
        VALUES('r-bud-del','c1','SAR',10.0,1000,'monthly','2026-01-01T00:00:00Z',1,0,0,
          '2026-01-01T00:00:00Z',0,'2026-01-02T00:00:00Z');""");
      expect(await unproven(), 0,
          reason: 'a correctly deleted row must not warn forever');
    });

    test("an 'ignored' transaction is counted, and CAN still be proven",
        () async {
      // `status='ignored'` is the transaction soft-delete. It is counted —
      // correctly, because the backfill explicitly INCLUDES ignored rows and
      // pushes their status, so the obligation is dischargeable rather than
      // permanent.
      await db.customStatement("""
        INSERT INTO transactions(id,account_id,amount,amount_minor,currency,category_id,
          type,source,status,raw_message,parse_confidence,occurred_at,created_at,updated_at)
        VALUES('r-tx-ign','r-acc',10.0,1000,'SAR',NULL,'expense','manual','ignored','',1.0,
          '2026-01-01T00:00:00Z','2026-01-01T00:00:00Z','2026-01-01T00:00:00Z');""");
      expect(await unproven(), 1);

      await db.customStatement(
        "UPDATE transactions SET server_id = 'srv-x', sync_status = 'synced' "
        "WHERE id = 'r-tx-ign';",
      );
      expect(await unproven(), 0,
          reason: 'ignored rows are backfillable, so this is not a permanent '
              'warning');
    });
  });
}
