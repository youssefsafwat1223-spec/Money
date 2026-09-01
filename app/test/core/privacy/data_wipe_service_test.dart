import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/privacy/data_wipe_service.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/db/money_v30_backfill.dart';

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'test-key';

  @override
  Future<String?> readStoredKey() async => 'test-key';
}

Future<AppDatabase> _openDb() {
  return AppDatabase.open(
    executor: NativeDatabase.memory(),
    keyStore: _MemoryKeyStore(),
  );
}

Future<int> _count(AppDatabase db, String table) async {
  final row =
      await db.customSelect('SELECT COUNT(*) AS n FROM $table;').getSingle();
  return row.read<int>('n');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // B1: sign-out (and the pre-existing "erase all my data" action) must wipe
  // every table that can hold a previous user's financial or personal data —
  // not just the original short list this service used to cover. A gap here
  // is exactly what let a signed-out user's transactions get uploaded to the
  // next signed-in user's Supabase account via the backfill services.

  test('wipeAll clears every user-scoped financial/personal/capture table',
      () async {
    final db = await _openDb();
    addTearDown(db.close);
    final now = DateTime.now().toUtc().toIso8601String();

    // Seed one row representative of each category the fix must clear.
    await db.customStatement(
      "INSERT INTO transactions(id, amount, currency, type, source, occurred_at, "
      "raw_message, parse_confidence, status, created_at, updated_at) "
      "VALUES ('t1', 10, 'SAR', 'expense', 'manual', '$now', 'raw', 1.0, 'active', '$now', '$now');",
    );
    await backfillNonPlanningMoneyV30(db);
    await db.customStatement(
      "UPDATE user_settings SET display_name = 'Previous User', phone_number = '0500000000';",
    );
    await db.customStatement(
      "INSERT INTO sender_bank_mappings(id, sender_id, normalized_sender_id, bank_key, "
      "suggested_bank_name, suggested_country, confidence, status, source, "
      "first_seen_at, last_seen_at, confirmed_at, created_at, updated_at) "
      "VALUES ('m1', 'SENDER', 'sender', 'bank_x', 'Bank X', 'SA', 0.9, 'confirmed', "
      "'user_manual', '$now', '$now', '$now', '$now', '$now');",
    );
    await db.customStatement(
      "INSERT INTO dedup_hashes(hash, transaction_id, occurred_at, saved_at) "
      "VALUES ('h1', 't1', '$now', '$now');",
    );
    await db.customStatement(
      "INSERT INTO ledger_sync_outbox(id, transaction_id, operation, payload_json, created_at, updated_at) "
      "VALUES ('o1', 't1', 'create', '{}', '$now', '$now');",
    );
    await db.customStatement(
      "INSERT INTO sync_cursors(entity, last_updated_at, last_id) "
      "VALUES ('ledger_transactions', '$now', 'server-t1');",
    );
    await db.customStatement(
      "INSERT INTO pending_merchant_feedback(normalized_keyword, last_seen_at) "
      "VALUES ('MERCHANT X', '$now');",
    );
    await db.customStatement(
      "INSERT INTO cards(id, account_id, last4, network, source, created_at, updated_at) "
      "VALUES ('card-user-a', (SELECT id FROM accounts LIMIT 1), '1234', "
      "'visa', 'manual', '$now', '$now');",
    );
    await db.customStatement(
      "INSERT INTO categories(id, key, name_ar, icon, color, is_income, sort_order, sync_status) "
      "VALUES ('cat-user-a', 'custom_user_a', 'خاصة', 'tag', '#000000', 0, 999, 'pending');",
    );
    // MALI-011: these user-scoped operational tables used to survive the wipe
    // and leak to the next user on the same device.
    await db.customStatement(
      "INSERT INTO financial_import_runs(package_id, format, mode, result_json, completed_at) "
      "VALUES ('pkg1', 'csv', 'append', '{\"imported\":42}', '$now');",
    );
    await db.customStatement(
      "INSERT INTO notification_log_events(id, notification_log_id, event_type, channel, "
      "notification_type, payload_json, occurred_at, created_at) "
      "VALUES ('n1', 'log1', 'sent', 'push', 'budget_alert', '{}', '$now', '$now');",
    );

    final accountsBefore = await _count(db, 'accounts');
    expect(accountsBefore, greaterThan(0),
        reason: 'a default account is seeded on open');
    final categoriesBefore = await _count(db, 'categories');
    expect(categoriesBefore, greaterThan(0));

    await DataWipeService(db).wipeAll();

    for (final table in [
      'transactions',
      'sender_bank_mappings',
      'dedup_hashes',
      'ledger_sync_outbox',
      'sync_cursors',
      'pending_merchant_feedback',
      'cards',
      'financial_import_runs',
      'notification_log_events',
    ]) {
      expect(await _count(db, table), 0, reason: '$table must be wiped');
    }

    expect(
      await db
          .customSelect(
            "SELECT COUNT(*) AS n FROM categories WHERE key LIKE 'custom_%';",
          )
          .getSingle()
          .then((row) => row.read<int>('n')),
      0,
      reason: 'custom categories from the previous user must be wiped',
    );

    // Reference/catalog tables are not personal — preserved across users.
    expect(await _count(db, 'categories'), categoriesBefore - 1,
        reason: 'built-in category catalog is shared and remains seeded');
  });

  test(
      'wipeAll resets user_settings to defaults and reseeds it immediately '
      '— the app must not crash reading it in the same session', () async {
    final db = await _openDb();
    addTearDown(db.close);
    await db.customStatement(
      "UPDATE user_settings SET display_name = 'Previous User', "
      "phone_number = '0500000000', country = 'EG', currency = 'EGP';",
    );

    await DataWipeService(db).wipeAll();

    final row = await db
        .customSelect('SELECT * FROM user_settings LIMIT 1;')
        .getSingle();
    expect(row.readNullable<String>('display_name'), isNull,
        reason: 'the previous user\'s name must not survive the wipe');
    expect(row.readNullable<String>('phone_number'), isNull);
    expect(row.read<String>('country'), 'SA',
        reason: 'reset to the app default, not left showing EG');
  });

  test('wipeAll leaves exactly one default account for the app to open into',
      () async {
    final db = await _openDb();
    addTearDown(db.close);
    await db.customStatement(
      "INSERT INTO accounts(id, name, currency, type, is_default, sort_order, created_at, updated_at) "
      "VALUES ('a2', 'Second account', 'USD', 'bank', 0, 1, '2026-01-01', '2026-01-01');",
    );
    await backfillNonPlanningMoneyV30(db);
    expect(await _count(db, 'accounts'), greaterThanOrEqualTo(2));

    await DataWipeService(db).wipeAll();

    expect(await _count(db, 'accounts'), 1);
    final defaults = await db
        .customSelect('SELECT id FROM accounts WHERE is_default = 1;')
        .get();
    expect(defaults, hasLength(1));
  });

  test(
      'the reseeded default account keeps a STABLE id across sign-out cycles '
      '(so sign-in never accumulates duplicate server accounts)', () async {
    final db = await _openDb();
    addTearDown(db.close);

    Future<String> defaultId() async => (await db
            .customSelect(
                'SELECT id FROM accounts WHERE is_default = 1 LIMIT 1;')
            .getSingle())
        .read<String>('id');

    final first = await defaultId();
    await DataWipeService(db).wipeAll(); // sign-out #1
    final second = await defaultId();
    await DataWipeService(db).wipeAll(); // sign-out #2
    final third = await defaultId();

    expect(first, kDefaultAccountLocalId,
        reason: 'the auto-seeded default must use the fixed sentinel id');
    expect(second, first,
        reason: 'a random id here is exactly what accumulated duplicates');
    expect(third, first);
  });

  test('wipeAll is idempotent — calling it twice in a row is safe', () async {
    final db = await _openDb();
    addTearDown(db.close);

    await DataWipeService(db).wipeAll();
    await DataWipeService(db).wipeAll();

    expect(await _count(db, 'accounts'), 1);
    expect(await _count(db, 'user_settings'), 1);
  });

  // MALI-011 regression guard: every persistent table must be a CONSCIOUS
  // choice — wiped (user data) or preserved (reference/catalog). A new table
  // added to the schema without classifying it here fails this test, so it can
  // never silently join the "leaks to the next user" list the way
  // financial_import_runs / notification_log_events did.
  test('every schema table is classified as wiped or intentionally preserved',
      () async {
    final db = await _openDb();
    addTearDown(db.close);

    // Reference/catalog data (re-synced from the server) and single-row tables
    // reseeded to defaults by wipeAll — deliberately NOT emptied per user.
    // `categories` is special-cased (custom rows wiped, built-ins kept).
    const preserved = <String>{
      'catalog_metadata',
      'parsing_rules',
      'remote_announcements',
      'remote_banks',
      'remote_categories',
      'remote_countries',
      'remote_coupons',
      // COUPONS Phase 1 — server catalog, like every remote_* row here. It
      // holds merchant identity, never anything about this user: which
      // merchants the user actually shops at lives in `merchants` and
      // `merchant_category_map`, both of which ARE wiped.
      'remote_catalog_merchants',
      'remote_merchant_aliases',
      'remote_currencies',
      'remote_feature_flags',
      'remote_growth_campaigns',
      'remote_merchant_keywords',
      'remote_parsers',
      'categories',
    };

    final rows = await db
        .customSelect(
          "SELECT name FROM sqlite_master WHERE type = 'table' "
          "AND name NOT LIKE 'sqlite_%' AND name NOT LIKE 'android_%';",
        )
        .get();
    final allTables = rows.map((row) => row.read<String>('name')).toSet();

    for (final table in allTables) {
      if (preserved.contains(table)) continue;
      if (table.endsWith('_new')) continue; // transient migration temps
      expect(DataWipeService.wipedTables.contains(table), isTrue,
          reason: 'schema table "$table" is neither preserved nor in the '
              'DataWipeService wipe list — classify it (MALI-011).');
    }
  });
}
