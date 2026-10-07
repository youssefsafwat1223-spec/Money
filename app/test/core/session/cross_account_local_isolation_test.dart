import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/privacy/data_wipe_service.dart';
import 'package:money_companion/core/session/account_scope.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/money_v30_backfill.dart';
import 'package:money_companion/data/db/replica_store.dart';

/// AUDIT 10 — USER B MUST NEVER SEE USER A's LOCAL DATA (WP-3b form).
///
/// Isolation used to be a WIPE on an ownership transition inside one shared
/// file. With one encrypted replica per uid it holds by construction: B is
/// opened on B's own file, A's file is locked and untouched, and no handle to A's
/// database is reachable once the scope has switched. These tests drive the real
/// account-scope host over real SQLCipher replicas.
late AccountScopeHost host;
AppDatabase get db => host.current!.database;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory support;
  late ReplicaStore store;

  Future<int> countOf(AppDatabase d, String table) async =>
      (await d.customSelect('SELECT COUNT(*) AS n FROM $table;').getSingle())
          .read<int>('n');

  setUp(() {
    support = Directory.systemTemp.createTempSync('cross_account_');
    FlutterSecureStorage.setMockInitialValues({});
    store = ReplicaStore(appSupportDirectory: support.path);
    host = AccountScopeHost(
      store: store,
      initialize: (db, uid) async => const AccountScopeInit(),
    );
  });

  tearDown(() async {
    await host.lock();
    host.dispose();
    if (support.existsSync()) support.deleteSync(recursive: true);
  });

  final now = DateTime.now().toUtc().toIso8601String();

  /// Distinctive data for user A, spread across the financial, personal,
  /// capture-derived, queue and gamification families — so a family the wipe
  /// forgets shows up as a specific table name rather than a vague failure.
  Future<void> seedUserA() async {
    await db.customStatement(
      "INSERT INTO accounts(id, name, currency, type, created_at, updated_at) "
      "VALUES ('a-acct', 'A Bank', 'SAR', 'bank', '$now', '$now');",
    );
    await db.customStatement(
      "INSERT INTO transactions(id, amount, currency, type, source, "
      "occurred_at, raw_message, parse_confidence, status, created_at, "
      "updated_at, account_id, note) VALUES ('a-tx', 4321.5, 'SAR', 'payment', "
      "'bank', '$now', 'A private message', 1.0, 'confirmed', '$now', '$now', "
      "'a-acct', 'A note');",
    );
    await backfillNonPlanningMoneyV30(db);
    await db.customStatement(
      "INSERT INTO goals(id, name, target_amount, saved_amount, vault_skin, "
      "status, created_at) VALUES ('a-goal', 'A car', 50000, 1200, 'classic', "
      "'active', '$now');",
    );
    final category = (await db
            .customSelect('SELECT id FROM categories LIMIT 1;')
            .getSingle())
        .read<String>('id');
    await db.customStatement(
      "INSERT INTO budgets(id, category_id, amount, period, start_date, "
      "is_active) VALUES ('a-budget', '$category', 900, 'monthly', '$now', 1);",
    );
    // subscriptions.merchant_id is NOT NULL and FKs onto merchants, so the
    // merchant A shops with is seeded too — another wiped table covered.
    await db.customStatement(
      "INSERT INTO merchants(id, raw_name, normalized_name, first_seen_at, "
      "last_seen_at) VALUES ('a-merchant', 'A NETFLIX', 'a netflix', "
      "'$now', '$now');",
    );
    await db.customStatement(
      "INSERT INTO subscriptions(id, merchant_id, name, amount, currency, "
      "period, is_confirmed, reminder_on, next_due_date, created_at) "
      "VALUES ('a-sub', 'a-merchant', 'A Netflix', 55, 'SAR', 'monthly', "
      "1, 1, '$now', '$now');",
    );
    // Personal profile — the field that used to survive into the next session.
    await db.customStatement(
      "UPDATE user_settings SET display_name = 'User A', "
      "phone_number = '0500000000';",
    );
    // Queues: A's unsent writes must never upload under B's credentials.
    await db.customStatement(
      "INSERT INTO ledger_sync_outbox(id, transaction_id, operation, "
      "payload_json, created_at, updated_at) VALUES ('a-out', 'a-tx', "
      "'create', '{}', '$now', '$now');",
    );
    await db.customStatement(
      "INSERT INTO sync_cursors(entity, last_updated_at, last_id) "
      "VALUES ('ledger_transactions', '$now', 'a-server-id');",
    );
    // Capture-derived evidence about A's messages.
    await db.customStatement(
      "INSERT INTO dedup_hashes(hash, transaction_id, occurred_at, saved_at) "
      "VALUES ('a-hash', 'a-tx', '$now', '$now');",
    );
    await db.customStatement(
      "INSERT INTO notification_log_events(id, notification_log_id, "
      "event_type, channel, notification_type, payload_json, occurred_at, "
      "created_at) VALUES ('a-note', 'a-log', 'sent', 'push', 'budget_alert', "
      "'{}', '$now', '$now');",
    );
    // Gamification — A's progress is a statement about A.
    await db.customStatement(
      "INSERT INTO achievements(id, key, name_ar, unlocked_at, progress) "
      "VALUES ('a-badge', 'a_first_save', 'أول توفير', '$now', 1.0);",
    );
  }


  Future<List<String>> tablesHoldingA(AppDatabase d) async {
    final dirty = <String>[];
    const reseeded = {
      'accounts',
      'user_settings',
      'streaks',
      'xp_levels',
      'achievements',
      'merchants',
      'merchant_category_map',
    };
    for (final table in DataWipeService.wipedTables) {
      if (reseeded.contains(table)) continue;
      if (await countOf(d, table) > 0) dirty.add(table);
    }
    return dirty;
  }

  test("B sees none of A's rows, money, queues, cursors or profile", () async {
    await host.activate('uid-a');
    await seedUserA();
    expect(await countOf(db, 'transactions'), 1);
    expect(await countOf(db, 'ledger_sync_outbox'), 1);

    await host.activate('uid-b');

    expect(host.current!.uid, 'uid-b');
    expect(await tablesHoldingA(db), isEmpty);
    final total = (await db
            .customSelect('SELECT COALESCE(SUM(amount_minor),0) AS m '
                'FROM transactions;')
            .getSingle())
        .read<int>('m');
    expect(total, 0);
    final settings = await db
        .customSelect('SELECT display_name, phone_number FROM user_settings;')
        .get();
    for (final row in settings) {
      expect(row.data['display_name'], isNot('User A'));
      expect(row.data['phone_number'], isNot('0500000000'));
    }
    expect(await db.customSelect('PRAGMA foreign_key_check;').get(), isEmpty);
    expect(await countOf(db, 'categories'), greaterThan(0));
  });

  test("A's data is untouched and comes back when A re-authenticates",
      () async {
    await host.activate('uid-a');
    await seedUserA();
    await host.activate('uid-b');
    await host.activate('uid-a');

    expect(host.current!.uid, 'uid-a');
    expect(await countOf(db, 'transactions'), 1);
    expect(await countOf(db, 'goals'), 1);
    expect(await countOf(db, 'ledger_sync_outbox'), 1,
        reason: "A's unsent writes survive for A");
  });

  test('no cross-uid handle survives a switch: the old database is closed',
      () async {
    await host.activate('uid-a');
    final oldDb = db;
    final oldGeneration = host.current!.generation;

    await host.activate('uid-b');

    expect(host.current!.generation, greaterThan(oldGeneration));
    expect(oldDb.lifecycleState, isNot(DatabaseLifecycleState.open));
    await expectLater(
        oldDb.customSelect('SELECT 1;').get(), throwsA(anything));
  });

  test('the previous scope is withdrawn BEFORE the old database closes',
      () async {
    await host.activate('uid-a');
    final seen = <bool>[];
    final oldDb = db;
    host.addListener(() {
      if (host.current == null) {
        seen.add(oldDb.lifecycleState == DatabaseLifecycleState.open);
      }
    });

    await host.activate('uid-b');

    expect(seen, [true],
        reason: 'listeners (the root widget) learn of the withdrawal while the '
            'old database is still open, so providers dispose before close');
  });

  test('re-signing in as the SAME uid keeps the open scope', () async {
    await host.activate('uid-a');
    await seedUserA();
    final gen = host.current!.generation;
    for (var i = 0; i < 3; i++) {
      await host.activate('uid-a');
    }
    expect(host.current!.generation, gen);
    expect(await countOf(db, 'transactions'), 1);
  });
}
