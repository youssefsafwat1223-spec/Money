import 'package:money_companion/data/db/app_database.dart';

/// A-7: a freshly opened database has ZERO accounts (no silent default). Tests
/// whose subject needs "an onboarded user with one account" call this right
/// after opening. It writes exactly the row the pre-A-7 seed used, so the
/// fixtures keep their meaning; it is test-only.
Future<void> seedTestAccount(AppDatabase db, {String currency = 'SAR'}) async {
  await db.customStatement(
    "INSERT OR IGNORE INTO accounts(id, name, currency, type, initial_balance, "
    "current_balance, is_default, sort_order, created_at, updated_at) "
    "VALUES('$kDefaultAccountLocalId', 'الحساب الرئيسي', '$currency', 'bank', "
    "NULL, NULL, 1, 0, '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z');",
  );
}

/// Wraps an `AppDatabase.open(...)` future: `seededDb(AppDatabase.open(...))`.
Future<AppDatabase> seededDb(Future<AppDatabase> opening) async {
  final db = await opening;
  await seedTestAccount(db);
  return db;
}
