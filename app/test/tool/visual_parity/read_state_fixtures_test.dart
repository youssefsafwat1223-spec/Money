import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/domain/repositories/transaction_repository.dart';
import 'package:money_companion/features/cards/cards_providers.dart';
import 'package:money_companion/features/settings/settings_providers.dart';

import '../../../tool/visual_parity/read_state_fixtures.dart';

class _MemoryKeys implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'memory-read-presentation';
  @override
  Future<String?> readStoredKey() async => 'memory-read-presentation';
}

void main() {
  for (final target in ['settings', 'settingsCountries', 'settingsCurrencies', 'settingsNotifications']) {
    for (final mode in ['loading', 'error']) {
      test('selected $target $mode leaves all writers and raw SQL unchanged', () async {
        final db = await AppDatabase.open(executor: NativeDatabase.memory(), keyStore: _MemoryKeys());
        addTearDown(db.close);
        Future<Map<String, Object>> snapshot() async {
          final rows = await db.customSelect("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name").get();
          return {for (final row in rows) row.read<String>('name'):
            (await db.customSelect('SELECT * FROM "${row.read<String>('name')}" ORDER BY rowid').get())
                .map((r) => r.data).toList()};
        }
        final before = await snapshot();
        final overrides = await visualParityReadStateOverrides(database: db, mode: mode, outcomeTarget: target);
        expect(overrides, hasLength(1));
        final container = ProviderContainer(overrides: [appDatabaseProvider.overrideWithValue(db), ...overrides]);
        addTearDown(container.dispose);
        final provider = target == 'settings' ? userSettingsProvider
            : target == 'settingsCountries' ? supportedCountriesProvider
                : target == 'settingsNotifications' ? notificationPreferencesProvider : activeCurrenciesProvider;
        final subscription = container.listen(provider, (_, __) {}, fireImmediately: true);
        addTearDown(subscription.close);
        if (mode == 'error') {
          final future = target == 'settings' ? container.read(userSettingsProvider.future)
              : target == 'settingsNotifications' ? container.read(notificationPreferencesProvider.future)
                  : target == 'settingsCountries' ? container.read(supportedCountriesProvider.future)
                  : container.read(activeCurrenciesProvider.future);
          await expectLater(future, throwsStateError);
          container.invalidate(provider);
          final retry = target == 'settings' ? container.read(userSettingsProvider.future)
              : target == 'settingsNotifications' ? container.read(notificationPreferencesProvider.future)
                  : target == 'settingsCountries' ? container.read(supportedCountriesProvider.future)
                  : container.read(activeCurrenciesProvider.future);
          await expectLater(retry, throwsStateError);
          expect((visualParityReadStateManifest['readCounts'] as Map)[target], 2);
        } else {
          await Future<void>.delayed(Duration.zero);
          expect(container.read(provider).isLoading, isTrue);
          expect((visualParityReadStateManifest['readCounts'] as Map)[target], 1);
        }
        final settings = await container.read(userSettingsRepositoryProvider).getSettings();
        expect(settings.country, isNotEmpty);
        expect(await snapshot(), before);
        expect(await visualParityReadStateOverrides(database: db, mode: 'data', outcomeTarget: target), isEmpty);
      });
    }
  }
  for (final mode in ['error', 'loading']) {
    test('guarded planningConflicts $mode reads no resolver and changes no ledger', () async {
      final db = await AppDatabase.open(executor: NativeDatabase.memory(), keyStore: _MemoryKeys());
      addTearDown(db.close);
      final overrides = await visualParityReadStateOverrides(
          database: db, mode: mode, outcomeTarget: 'planningConflicts');
      var resolverReads = 0;
      final container = ProviderContainer(overrides: [
        appDatabaseProvider.overrideWithValue(db), ...overrides,
        conflictResolverProvider.overrideWith((ref) {
          resolverReads++;
          throw StateError('No resolution authority in read fixture');
        }),
      ]);
      addTearDown(container.dispose);
      expect(overrides, hasLength(1));
      int count() => (visualParityReadStateManifest['readCounts'] as Map)['planningConflicts'] as int;
      expect(count(), 0);
      final subscription = container.listen(conflictsProvider, (_, __) {}, fireImmediately: true);
      addTearDown(subscription.close);
      if (mode == 'error') {
        await expectLater(container.read(conflictsProvider.future), throwsA(isA<StateError>()));
      } else {
        await Future<void>.delayed(Duration.zero);
        expect(container.read(conflictsProvider).isLoading, isTrue);
      }
      expect(count(), 1);
      expect(resolverReads, 0);
      expect(await db.customSelect('SELECT COUNT(*) AS n FROM transactions')
          .getSingle().then((row) => row.read<int>('n')), 0);
    });
  }
  test('planningConflicts data mode preserves actual local provider', () async {
    final db = await AppDatabase.open(executor: NativeDatabase.memory(), keyStore: _MemoryKeys());
    addTearDown(db.close);
    expect(await visualParityReadStateOverrides(database: db, mode: 'data',
        outcomeTarget: 'planningConflicts'), isEmpty);
  });
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final mode in ['error', 'loading']) {
    test('guarded planLink $mode replaces only its initial bounded expense read', () async {
      final db = await AppDatabase.open(executor: NativeDatabase.memory(), keyStore: _MemoryKeys());
      addTearDown(db.close);
      final overrides = await visualParityReadStateOverrides(
          database: db, mode: mode, outcomeTarget: 'planLink');
      final container = ProviderContainer(overrides: [
        appDatabaseProvider.overrideWithValue(db), ...overrides,
      ]);
      addTearDown(container.dispose);
      final repository = container.read(transactionRepositoryProvider);
      expect(await repository.getTransactionPage(limit: 1), isEmpty);
      expect(await repository.getTransactionPage(limit: 500), isEmpty);
      expect((visualParityReadStateManifest['readCounts'] as Map)['planLink'], 0);
      const expenses = TransactionPageFilter(kind: TransactionPageKind.expenses);
      if (mode == 'error') {
        await expectLater(repository.getTransactionPage(limit: 500, filter: expenses),
            throwsA(isA<StateError>()));
        await expectLater(repository.getTransactionPage(limit: 500, filter: expenses),
            throwsA(isA<StateError>()));
        expect((visualParityReadStateManifest['readCounts'] as Map)['planLink'], 2);
      } else {
        var completed = false;
        repository.getTransactionPage(limit: 500, filter: expenses).then((_) => completed = true);
        await Future<void>.delayed(Duration.zero);
        expect(completed, isFalse);
        expect((visualParityReadStateManifest['readCounts'] as Map)['planLink'], 1);
      }
      expect(await repository.getTransactionPage(limit: 20, filter: expenses), isEmpty);
      expect(await db.customSelect('SELECT COUNT(*) AS n FROM transactions').getSingle()
          .then((row) => row.read<int>('n')), 0);
    });
  }
  for (final mode in ['error', 'loading']) {
    test('guarded cardAttach $mode changes only candidate reads and counts current-query Retry', () async {
      final db = await AppDatabase.open(executor: NativeDatabase.memory(), keyStore: _MemoryKeys());
      addTearDown(db.close);
      final overrides = await visualParityReadStateOverrides(
          database: db, mode: mode, outcomeTarget: 'cardAttach');
      final container = ProviderContainer(overrides: [
        appDatabaseProvider.overrideWithValue(db), ...overrides,
      ]);
      addTearDown(container.dispose);
      expect(overrides, hasLength(1));
      expect(visualParityReadStateTargets['cardAttach'], contains('pickTransactionsProvider'));
      // Parent surfaces and the repository remain real, empty memory reads.
      expect((await container.read(accountCardGroupsProvider.future)).byAccount, isEmpty);
      expect(await container.read(allCardsProvider.future), isEmpty);
      expect(await container.read(transactionRepositoryProvider)
          .getTransactionPage(limit: 500), isEmpty);
      int count() => (visualParityReadStateManifest['readCounts'] as Map)['cardAttach'] as int;
      expect(count(), 0);
      final provider = pickTransactionsProvider('actual-query');
      final sub = container.listen(provider, (_, __) {}, fireImmediately: true);
      addTearDown(sub.close);
      if (mode == 'error') {
        await expectLater(container.read(provider.future), throwsA(isA<StateError>()));
        expect(count(), 1);
        container.invalidate(provider);
        await expectLater(container.read(provider.future), throwsA(isA<StateError>()));
        expect(count(), 2);
      } else {
        await Future<void>.delayed(Duration.zero);
        expect(container.read(provider).isLoading, isTrue);
        expect(count(), 1);
      }
      expect(await db.customSelect('SELECT COUNT(*) AS n FROM transactions')
          .getSingle().then((row) => row.read<int>('n')), 0);
    });
  }

  test('cardAttach data mode keeps actual candidate provider and unknown error target is rejected', () async {
    final db = await AppDatabase.open(executor: NativeDatabase.memory(), keyStore: _MemoryKeys());
    addTearDown(db.close);
    final overrides = await visualParityReadStateOverrides(
        database: db, mode: 'data', outcomeTarget: 'cardAttach');
    expect(overrides, isEmpty);
    final container = ProviderContainer(overrides: [
      appDatabaseProvider.overrideWithValue(db), ...overrides,
    ]);
    addTearDown(container.dispose);
    expect(await container.read(pickTransactionsProvider('actual-query').future), isEmpty);
    expect((visualParityReadStateManifest['readCounts'] as Map)['cardAttach'], 0);
    await expectLater(visualParityReadStateOverrides(
        database: db, mode: 'error', outcomeTarget: 'unknown-card-target'),
        throwsArgumentError);
  });

}
