// Phase-7 Batch-2 §MALI-029 — domain-scoped revision proof: an unrelated-table
// write produces ZERO rebuilds of a scoped provider; a relevant (or display-
// dependency) write produces exactly one; a write burst coalesces to one; and the
// broad financial revision ignores purely-operational tables. Uses real Drift
// writes through a real AppDatabase and a real ProviderContainer.
//
// A no-op `DELETE FROM <t> WHERE 1=0` is a valid data write that emits the table
// signal without needing valid FK/NOT NULL rows — ideal for exercising routing.
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';

class _K implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'k';
  @override
  Future<String?> readStoredKey() async => 'k';
}

/// Longer than the 300ms coalescing quiet-gap so a pending tick surfaces.
Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 450));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  late ProviderContainer container;

  setUp(() async {
    db = await AppDatabase.open(
        executor: NativeDatabase.memory(), keyStore: _K());
    container = ProviderContainer(
      overrides: [appDatabaseProvider.overrideWithValue(db)],
    );
  });
  tearDown(() async {
    container.dispose();
    await db.close();
  });

  Future<void> write(String table) =>
      db.customStatement('DELETE FROM $table WHERE 1=0;');

  /// Subscribes to [provider] and returns a counter of coalesced revision ticks.
  int Function() ticksOf(ProviderListenable<AsyncValue<int>> provider) {
    var ticks = 0;
    container.listen(provider, (prev, next) {
      if (next is AsyncData<int>) ticks++;
    });
    container.read(provider); // force build → subscribe to the write stream
    return () => ticks;
  }

  group('scopedRevisionProvider (reports domain = {categories, transactions})', () {
    test('an UNRELATED write (accounts, goals) produces zero rebuilds', () async {
      final ticks = ticksOf(scopedRevisionProvider(kReportsRevisionTables));
      await settle(); // let the subscription establish
      await write('accounts');
      await write('goals');
      await write('notification_log_events');
      await settle();
      expect(ticks(), 0, reason: 'reports must not rebuild on non-reports writes');
    });

    test('a RELEVANT write (transactions) rebuilds exactly once', () async {
      final ticks = ticksOf(scopedRevisionProvider(kReportsRevisionTables));
      await settle();
      await write('transactions');
      await settle();
      expect(ticks(), 1);
    });

    test('a DISPLAY-DEPENDENCY write (categories → renamed) still refreshes',
        () async {
      final ticks = ticksOf(scopedRevisionProvider(kReportsRevisionTables));
      await settle();
      await write('categories');
      await settle();
      expect(ticks(), 1, reason: 'a category rename must refresh reports rows');
    });

    test('a 100-write burst coalesces to a bounded number of rebuilds', () async {
      final ticks = ticksOf(scopedRevisionProvider(kReportsRevisionTables));
      await settle();
      for (var i = 0; i < 100; i++) {
        await write('transactions');
      }
      await settle();
      expect(ticks(), lessThanOrEqualTo(2),
          reason: '100 writes must not emit 100 rebuilds (coalesced)');
      expect(ticks(), greaterThanOrEqualTo(1), reason: 'final state still surfaces');
    });
  });

  group('financialRevisionProvider (broad; excludes operational tables)', () {
    test('purely-operational writes produce zero financial rebuilds', () async {
      final ticks = ticksOf(financialRevisionProvider);
      await settle();
      await write('notification_log_events');
      await write('ledger_sync_outbox');
      await write('sync_cursors');
      await write('engagement_events');
      await settle();
      expect(ticks(), 0,
          reason: 'sync/notification bookkeeping must not rebuild the dashboard');
    });

    test('any financial write (transactions, goals, achievements) rebuilds once',
        () async {
      final ticks = ticksOf(financialRevisionProvider);
      await settle();
      await write('goals');
      await write('achievements'); // gamification DISPLAY aggregate
      await settle();
      expect(ticks(), 1, reason: 'financial writes refresh; burst coalesces to 1');
    });
  });
}
