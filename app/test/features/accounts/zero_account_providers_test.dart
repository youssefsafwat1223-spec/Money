import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/features/budgets/budgets_providers.dart';
import 'package:money_companion/features/dashboard/dashboard_providers.dart';
import 'package:money_companion/features/goals/goals_providers.dart';
import 'package:money_companion/features/reports/reports_providers.dart';
import 'package:money_companion/features/subscriptions/subscriptions_providers.dart';

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'memory-key';
  @override
  Future<String?> readStoredKey() async => 'memory-key';
}

/// A-7: a database with ZERO accounts (fresh, post-wipe) must never crash a
/// reader of getDefault()/defaultAccount; each shows an empty state.
void main() {
  late AppDatabase db;
  late ProviderContainer container;

  setUp(() async {
    db = await AppDatabase.open(
      executor: NativeDatabase.memory(),
      keyStore: _MemoryKeyStore(),
    );
    container = ProviderContainer(
        overrides: [appDatabaseProvider.overrideWithValue(db)]);
  });
  tearDown(() async {
    container.dispose();
    await db.close();
  });

  test('zero-account providers resolve without error', () async {
    expect(await container.read(accountsProvider.future), isEmpty);
    // Falls back to the user-settings currency, not a missing account.
    expect(await container.read(baseCurrencyProvider.future), 'SAR');
    expect(await container.read(goalsListProvider.future), isEmpty);
    expect(await container.read(savedBillsProvider.future), isEmpty);
    expect(await container.read(billsScopeAccountProvider.future), isNull);
    expect(await container.read(budgetsViewProvider.future), isNotNull);
    expect(await container.read(reportsProvider.future), isNotNull);
    expect(await container.read(dashboardDataProvider.future), isNotNull);
  });
}
