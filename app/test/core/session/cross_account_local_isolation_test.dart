import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/privacy/data_wipe_service.dart';
import 'package:money_companion/core/session/app_session.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/db/money_v30_backfill.dart';
import '../../harness/seed_test_account.dart';

/// AUDIT 10 — USER B MUST NEVER SEE USER A's LOCAL DATA.
///
/// This app's local database is single-owner by design. There is no `user_id`
/// column to filter on: one account owns the file at a time, and isolation is
/// enforced by WIPING on an ownership transition. That makes the wipe a
/// security boundary, not a convenience, and it means three separate things all
/// have to hold at once:
///
///   1. every user-scoped table is in `DataWipeService.wipedTables`
///      — `data_wipe_service_test` proves this exhaustively against the live
///        schema, so no new table escapes classification;
///   2. the wipe empties them
///      — proven by construction: `wipeAll` loops the list;
///   3. the A -> B transition actually RUNS that wipe before admitting B.
///
/// Those were each covered in isolation. Nothing connected them, so a
/// regression in the wiring — the transition calling something else, calling it
/// after admission, or swallowing its failure — would have left every
/// individual test green while B inherited A's money. That is the gap this
/// closes: the REAL DataWipeService against a REAL database, driven through the
/// REAL AppSession transition, asserting residue by querying every table in the
/// wipe list rather than trusting the list.
///
/// `install_restore_matrix_test` covers the ordering and convergence of that
/// transition with a fake wipe; this covers what the real wipe leaves behind.

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'test-key';
  @override
  Future<String?> readStoredKey() async => 'test-key';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;

  Future<int> countOf(String table) async =>
      (await db.customSelect('SELECT COUNT(*) AS n FROM $table;').getSingle())
          .read<int>('n');

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    db = await AppDatabase.open(
      executor: NativeDatabase.memory(),
      keyStore: _MemoryKeyStore(),
    );
    await seedTestAccount(db);
    // The REAL wipe service, exactly as bootstrap_runner wires it.
    AppSession.instance.configureLocalDataWipe(DataWipeService(db).wipeAll);
    AppSession.instance.configureLocalResiduePurge(() async => true);
    AppSession.instance.configureCaptureDeviceUnlink(null);
    await AppSession.instance.wipeAndReset();
  });

  tearDown(() async {
    AppSession.instance.configureLocalDataWipe(null);
    AppSession.instance.configureLocalResiduePurge(null);
    await AppSession.instance.wipeAndReset();
    await db.close();
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

  /// Tables the wipe empties and then RESEEDS with catalog/default content, so
  /// a row count above zero is correct for them and proves nothing either way.
  /// A's own rows in these are checked by identity in [aRowsSurviving] instead.
  ///
  ///   accounts             — one default account, so the app can open
  ///   user_settings        — one defaults row (its CONTENT is asserted below)
  ///   streaks / xp_levels  — single-row gamification counters, reset
  ///   achievements         — the badge catalog, reset to zero progress
  ///   merchants,
  ///   merchant_category_map— the seeded merchant→category starter map
  const reseeded = {
    'accounts',
    'user_settings',
    'streaks',
    'xp_levels',
    'achievements',
    'merchants',
    'merchant_category_map',
  };

  /// Every table the wipe claims to empty, queried directly. The list is the
  /// production constant, so a table added to it is automatically checked here.
  Future<List<String>> tablesStillHoldingRows() async {
    final dirty = <String>[];
    for (final table in DataWipeService.wipedTables) {
      if (reseeded.contains(table)) continue;
      if (await countOf(table) > 0) dirty.add(table);
    }
    return dirty;
  }

  /// A's rows identified by primary key, including in the reseeded tables. This
  /// is the assertion that actually matters there: the badge catalog coming back
  /// is fine, A's unlocked badge coming back is not.
  Future<List<String>> aRowsSurviving() async {
    const owned = {
      'accounts': "id = 'a-acct'",
      'transactions': "id = 'a-tx'",
      'goals': "id = 'a-goal'",
      'budgets': "id = 'a-budget'",
      'subscriptions': "id = 'a-sub'",
      'merchants': "id = 'a-merchant'",
      'ledger_sync_outbox': "id = 'a-out'",
      'sync_cursors': "last_id = 'a-server-id'",
      'dedup_hashes': "hash = 'a-hash'",
      'notification_log_events': "id = 'a-note'",
      'achievements': "id = 'a-badge' OR unlocked_at IS NOT NULL",
    };
    final survivors = <String>[];
    for (final entry in owned.entries) {
      final n = (await db
              .customSelect('SELECT COUNT(*) AS n FROM ${entry.key} '
                  'WHERE ${entry.value};')
              .getSingle())
          .read<int>('n');
      if (n > 0) survivors.add('${entry.key} (${entry.value})');
    }
    return survivors;
  }

  test('signing in as B after A wipes every user-scoped table', () async {
    await AppSession.instance.setIdentity(method: 'google', userId: 'uid-a');
    await seedUserA();

    // Sanity: the fixture is real, or everything below is vacuous.
    expect(await countOf('transactions'), 1);
    expect(await countOf('goals'), 1);
    expect(await countOf('ledger_sync_outbox'), 1);

    // THE transition.
    await AppSession.instance.setIdentity(method: 'google', userId: 'uid-b');

    expect(await tablesStillHoldingRows(), isEmpty,
        reason: 'B inherited rows from A in these tables');
    // And nothing of A's survives in the reseeded tables either — including
    // A's merchant name and A's unlocked badge.
    expect(await aRowsSurviving(), isEmpty,
        reason: "these rows of A's are still readable by B");
    expect(await AppSession.instance.readLocalDataOwnerUid(), 'uid-b');
  });

  test("B cannot see A's money, name, queued writes or sync cursors",
      () async {
    await AppSession.instance.setIdentity(method: 'google', userId: 'uid-a');
    await seedUserA();
    await AppSession.instance.setIdentity(method: 'google', userId: 'uid-b');

    // Money, by value — not just by row count.
    final total = (await db
            .customSelect('SELECT COALESCE(SUM(amount_minor),0) AS m '
                'FROM transactions;')
            .getSingle())
        .read<int>('m');
    expect(total, 0, reason: "A's balance is visible to B");

    // Personal identity must be back to defaults, not A's.
    final settings = await db
        .customSelect('SELECT display_name, phone_number FROM user_settings;')
        .get();
    for (final row in settings) {
      expect(row.data['display_name'], isNot('User A'));
      expect(row.data['phone_number'], isNot('0500000000'));
    }

    // A's unsent writes must not be uploadable as B — this is the one that
    // would push A's private transactions into B's cloud account.
    expect(await countOf('ledger_sync_outbox'), 0);
    expect(await countOf('planning_sync_outbox'), 0);
    // A stale cursor would make B's first pull resume from A's high-water mark
    // and silently skip B's own history.
    expect(await countOf('sync_cursors'), 0);

    // And A's raw message text must be gone from the file entirely.
    final raw = await db
        .customSelect("SELECT COUNT(*) AS n FROM transactions "
            "WHERE raw_message LIKE '%A private message%';")
        .getSingle();
    expect(raw.read<int>('n'), 0);
  });

  test('the wipe leaves a consistent, usable database for B', () async {
    await AppSession.instance.setIdentity(method: 'google', userId: 'uid-a');
    await seedUserA();
    await AppSession.instance.setIdentity(method: 'google', userId: 'uid-b');

    // Referential integrity: a wipe that deleted parents but left children
    // would hand B a database that breaks on first read.
    expect(await db.customSelect('PRAGMA foreign_key_check;').get(), isEmpty);
    // Catalog data is reference material and must SURVIVE, or B opens into an
    // app with no categories to spend against.
    expect(await countOf('categories'), greaterThan(0));
    // A-7: no silent default account — B creates their own in Account Setup.
    expect(await countOf('accounts'), 0);
    expect(await countOf('user_settings'), 1);
  });

  test('a wipe that fails destroys nothing and does not admit B', () async {
    // The fail-closed contract, with the REAL service: if the wipe throws,
    // A's data must still be intact and the marker must still say A. A
    // half-wiped database handed to B is the worst outcome available.
    await AppSession.instance.setIdentity(method: 'google', userId: 'uid-a');
    await seedUserA();
    final before = await countOf('transactions');

    AppSession.instance.configureLocalDataWipe(
      () async => throw StateError('disk full'),
    );

    await expectLater(
      AppSession.instance.setIdentity(method: 'google', userId: 'uid-b'),
      throwsA(anything),
    );

    expect(await countOf('transactions'), before,
        reason: "A's data was destroyed by a failed transition");
    expect(await AppSession.instance.readLocalDataOwnerUid(), 'uid-a',
        reason: 'ownership must not move without a completed wipe');
  });

  test('re-signing in as the SAME user never wipes their data', () async {
    // The other direction of the boundary: an over-eager wipe is data loss.
    await AppSession.instance.setIdentity(method: 'google', userId: 'uid-a');
    await seedUserA();
    final before = await countOf('transactions');

    for (var launch = 0; launch < 3; launch++) {
      await AppSession.instance.setIdentity(method: 'google', userId: 'uid-a');
      expect(await countOf('transactions'), before,
          reason: 'launch $launch wiped a returning user');
    }
  });
}
