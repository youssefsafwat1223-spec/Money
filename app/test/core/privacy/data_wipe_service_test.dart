import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/privacy/data_wipe_service.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';

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
      "INSERT INTO pending_merchant_feedback(normalized_keyword, last_seen_at) "
      "VALUES ('MERCHANT X', '$now');",
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
      'pending_merchant_feedback',
    ]) {
      expect(await _count(db, table), 0, reason: '$table must be wiped');
    }

    // Reference/catalog tables are not personal — preserved across users.
    expect(await _count(db, 'categories'), categoriesBefore,
        reason: 'category catalog is shared, not personal');
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

    final row = await db.customSelect('SELECT * FROM user_settings LIMIT 1;')
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
    expect(await _count(db, 'accounts'), greaterThanOrEqualTo(2));

    await DataWipeService(db).wipeAll();

    expect(await _count(db, 'accounts'), 1);
    final defaults = await db
        .customSelect('SELECT id FROM accounts WHERE is_default = 1;')
        .get();
    expect(defaults, hasLength(1));
  });

  test('wipeAll is idempotent — calling it twice in a row is safe', () async {
    final db = await _openDb();
    addTearDown(db.close);

    await DataWipeService(db).wipeAll();
    await DataWipeService(db).wipeAll();

    expect(await _count(db, 'accounts'), 1);
    expect(await _count(db, 'user_settings'), 1);
  });
}
