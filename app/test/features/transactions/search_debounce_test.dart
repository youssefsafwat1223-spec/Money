// Phase-7 B2-C — search debounce production/widget lifecycle (the real
// TransactionSearchField widget + the real list notifier, not a helper in
// isolation).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/domain/entities/account_entity.dart';
import 'package:money_companion/domain/entities/transaction_entity.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/domain/repositories/account_repository.dart';
import 'package:money_companion/domain/repositories/transaction_repository.dart';
import 'package:money_companion/features/common/category_catalog.dart';
import 'package:money_companion/features/transactions/transactions_providers.dart';
import 'package:money_companion/features/transactions/transactions_screen.dart';

Widget _host(ProviderContainer c) => UncontrolledProviderScope(
      container: c,
      child: MaterialApp(
        theme: AppTheme.light, // provides the AppColors theme extension
        home: const Scaffold(body: TransactionSearchField()),
      ),
    );

void main() {
  group('TransactionSearchField widget debounce', () {
    testWidgets('rapid typing writes only the final settled term once',
        (tester) async {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final writes = <String>[];
      c.listen(transactionSearchQueryProvider, (_, n) => writes.add(n));

      await tester.pumpWidget(_host(c));
      final field = find.byType(TextField);
      await tester.enterText(field, 'a');
      await tester.pump(const Duration(milliseconds: 50));
      await tester.enterText(field, 'ab');
      await tester.pump(const Duration(milliseconds: 50));
      await tester.enterText(field, 'abc');
      expect(writes, isEmpty, reason: 'nothing settled yet');
      await tester.pump(const Duration(milliseconds: 250));

      expect(c.read(transactionSearchQueryProvider), 'abc');
      expect(writes, ['abc'], reason: 'one trigger, not one per keystroke');
    });

    testWidgets('slow typing produces each settled term', (tester) async {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final writes = <String>[];
      c.listen(transactionSearchQueryProvider, (_, n) => writes.add(n));
      await tester.pumpWidget(_host(c));
      final field = find.byType(TextField);
      await tester.enterText(field, 'a');
      await tester.pump(const Duration(milliseconds: 300));
      await tester.enterText(field, 'ab');
      await tester.pump(const Duration(milliseconds: 300));
      expect(writes, ['a', 'ab']);
    });

    testWidgets('clear cancels any pending search', (tester) async {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      await tester.pumpWidget(_host(c));
      final field = find.byType(TextField);
      await tester.enterText(field, 'foo');
      await tester.pump(const Duration(milliseconds: 300));
      expect(c.read(transactionSearchQueryProvider), 'foo');
      await tester.enterText(field, 'foobar');
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.byIcon(Icons.close_rounded));
      await tester.pump(const Duration(milliseconds: 300));
      expect(c.read(transactionSearchQueryProvider), '');
    });

    testWidgets('dispose before the debounce fires writes nothing',
        (tester) async {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      await tester.pumpWidget(_host(c));
      await tester.enterText(find.byType(TextField), 'xyz');
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pumpWidget(UncontrolledProviderScope(
        container: c,
        child: const MaterialApp(home: Scaffold(body: SizedBox())),
      ));
      await tester.pump(const Duration(milliseconds: 300));
      expect(c.read(transactionSearchQueryProvider), '',
          reason: 'no setState-after-dispose / no write after dispose');
    });
  });

  group('list notifier stale-result guard', () {
    test('a loadMore page for the old filter is dropped after a rebuild',
        () async {
      final repo = _GatedRepo();
      final c = ProviderContainer(overrides: [
        transactionRepositoryProvider.overrideWithValue(repo),
        accountRepositoryProvider.overrideWithValue(_NoAccounts()),
        categoryCatalogProvider.overrideWith((ref) async => CategoryCatalog(const [])),
        scopedRevisionProvider(kTransactionsRevisionTables)
            .overrideWith((ref) => Stream.value(0)),
      ]);
      addTearDown(c.dispose);
      c.listen(transactionsListProvider, (_, __) {}); // keep alive

      // First build: a FULL page → hasMore=true so loadMore is allowed.
      repo.nextPage(List.generate(transactionsPageSize, (i) => _tx('p1-$i')));
      await c.read(transactionsListProvider.future);

      // Start a loadMore whose page we hold in flight.
      repo.holdNext();
      final loadMoreFuture = c.read(transactionsListProvider.notifier).loadMore();

      // A filter change forces a rebuild (new generation) with a small fresh page.
      c.read(transactionSearchQueryProvider.notifier).state = 'changed';
      repo.nextPage([_tx('fresh')]);
      await c.read(transactionsListProvider.future);
      final afterRebuild =
          c.read(transactionsListProvider).value!.transactions.map((t) => t.id).toList();
      expect(afterRebuild, ['fresh']);

      // Release the stale loadMore page — the guard must drop it.
      repo.releaseHeld([_tx('stale')]);
      await loadMoreFuture;
      final finalRows =
          c.read(transactionsListProvider).value!.transactions.map((t) => t.id).toList();
      expect(finalRows, ['fresh'], reason: 'stale page dropped, newer untouched');
    });
  });
}

TransactionEntity _tx(String id) {
  final now = DateTime.utc(2026, 6, 1);
  return TransactionEntity(
    id: id,
    amountMoney: Money.fromLegacyReal(1, 'SAR'),
    currency: 'SAR',
    type: TransactionTypeEntity.payment,
    source: TransactionSourceEntity.bank,
    occurredAt: now,
    rawMessage: '',
    parseConfidence: 1,
    status: TransactionStatus.confirmed,
    createdAt: now,
    updatedAt: now,
  );
}

/// getTransactionPage returns queued pages; one page can be HELD in flight to
/// exercise the notifier's generation guard deterministically.
class _GatedRepo implements TransactionRepository {
  final _queued = <List<TransactionEntity>>[];
  Completer<List<TransactionEntity>>? _held;
  var _heldConsumed = false;

  void nextPage(List<TransactionEntity> page) => _queued.add(page);
  void holdNext() {
    _held = Completer<List<TransactionEntity>>();
    _heldConsumed = false;
  }

  void releaseHeld(List<TransactionEntity> page) => _held!.complete(page);

  @override
  Future<List<TransactionEntity>> getTransactionPage({
    required int limit,
    TransactionPageCursor? after,
    TransactionPageFilter filter = const TransactionPageFilter(),
  }) {
    // The FIRST call after holdNext() is held in flight (kept so releaseHeld can
    // complete it); later calls (the rebuild's page) fall through to the queue.
    if (_held != null && !_heldConsumed) {
      _heldConsumed = true;
      return _held!.future;
    }
    return Future.value(_queued.isEmpty ? const [] : _queued.removeAt(0));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _NoAccounts implements AccountRepository {
  @override
  Future<AccountEntity?> getById(String id) async => null;
  @override
  Future<AccountEntity?> getDefault() async => null;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
