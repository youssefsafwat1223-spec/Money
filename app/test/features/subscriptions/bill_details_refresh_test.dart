import 'dart:async';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/repositories/drift_transaction_repository.dart';
import 'package:money_companion/domain/entities/bill_entity.dart';
import 'package:money_companion/domain/entities/transaction_entity.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/domain/repositories/transaction_repository.dart';
import 'package:money_companion/features/subscriptions/bill_details_sheet.dart';
import 'package:money_companion/features/subscriptions/subscriptions_providers.dart';
import 'package:money_companion/l10n/app_localizations.dart';

class _Keys implements DatabaseKeyStore {
  @override Future<String> readOrCreateKey() async => 'sheet-refresh-test';
  @override Future<String?> readStoredKey() async => 'sheet-refresh-test';
}
class _Transactions extends DriftTransactionRepository {
  _Transactions(super.db);
  int reads = 0;
  Completer<List<TransactionEntity>>? pending;
  @override
  Future<List<TransactionEntity>> getTransactionPage({required int limit,
      TransactionPageCursor? after,
      TransactionPageFilter filter = const TransactionPageFilter()}) async {
    reads++;
    if (pending != null) return pending!.future;
    return [TransactionEntity(id: 'tx', amountMoney: Money(12000, 'EGP'),
      currency: 'EGP', type: TransactionTypeEntity.payment,
      source: TransactionSourceEntity.card, occurredAt: DateTime(2026, 11, 1),
      rawMessage: '', rawMerchant: 'Netflix purchase', parseConfidence: 1,
      status: TransactionStatus.confirmed, createdAt: DateTime(2026, 11, 1),
      updatedAt: DateTime(2026, 11, 1))];
  }
}
void main() {
  late AppDatabase db;
  setUp(() async {
    db = await AppDatabase.open(executor: NativeDatabase.memory(), keyStore: _Keys());
  });
  tearDown(() async => db.close());
  testWidgets('bill sheet keeps its content during parent rebuild and transaction reload', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final transactions = _Transactions(db);
    final revision = StreamController<int>.broadcast();
    final reload = StateProvider<int>((ref) => 0);
    final bill = BillEntity(id: 'bill', name: 'Netflix', amountMoney: Money(12000, 'EGP'),
      currency: 'EGP', type: BillType.subscription, frequency: BillFrequency.monthly,
      status: BillStatus.active, nextDueDate: DateTime(2026, 12, 1),
      reminderOn: false, isConfirmed: true, createdAt: DateTime(2026, 11, 1));
    final container = ProviderContainer(overrides: [
      appDatabaseProvider.overrideWithValue(db),
      transactionRepositoryProvider.overrideWithValue(transactions),
      scopedRevisionProvider('transactions').overrideWith((ref) => revision.stream),
      savedBillsProvider.overrideWith((ref) async { ref.watch(reload); return [bill]; }),
      billPaymentsProvider('bill').overrideWith((ref) async => []),
      accountsProvider.overrideWith((ref) async => []),
    ]);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      container.dispose();
      await tester.pump();
      await revision.close();
    });
    await tester.pumpWidget(UncontrolledProviderScope(container: container,
      child: MaterialApp(theme: AppTheme.light, locale: const Locale('en'),
        supportedLocales: AppL10n.supportedLocales,
        localizationsDelegates: AppL10n.localizationsDelegates,
        home: Scaffold(body: BillDetailsSheet(bill: bill)))));
    await tester.pumpAndSettle();
    expect(transactions.reads, 1);
    expect(find.text('Netflix purchase'), findsOneWidget);
    final l10n = AppL10n.of(tester.element(find.byType(BillDetailsSheet)));
    final payment = find.text(l10n.bdsRecordPayment);
    final position = tester.getTopLeft(payment);
    container.read(reload.notifier).state++;
    await tester.pumpAndSettle();
    expect(transactions.reads, 1, reason: 'unrelated parent rebuild reuses the query');
    final pending = transactions.pending = Completer<List<TransactionEntity>>();
    revision.add(1);
    await tester.pump();
    await tester.pump();
    expect(transactions.reads, 2);
    expect(find.text('Netflix purchase'), findsOneWidget,
        reason: 'keep previous suggestions while the replacement query is pending');
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(tester.getTopLeft(payment), position);
    pending.complete([]);
    await tester.pumpAndSettle();
    expect(find.text('Netflix purchase'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
