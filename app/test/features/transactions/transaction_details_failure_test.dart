import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/repositories/drift_account_repository.dart';
import 'package:money_companion/data/repositories/drift_transaction_repository.dart';
import 'package:money_companion/domain/entities/account_entity.dart';
import 'package:money_companion/domain/entities/transaction_entity.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/features/transactions/transaction_details_screen.dart';
import 'package:money_companion/l10n/app_localizations.dart';
import '../../../tool/visual_parity/transaction_details_failure_surfaces.dart';

class _Keys implements DatabaseKeyStore {
  @override Future<String> readOrCreateKey() async => 'transaction-failure-memory';
  @override Future<String?> readStoredKey() async => 'transaction-failure-memory';
}
Future<Map<String, List<Map<String, Object?>>>> _sql(AppDatabase db) async {
  final names = await db.customSelect("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name").get();
  return {for (final n in names) n.read<String>('name'): [for (final row in await db.customSelect('SELECT * FROM "${n.read<String>('name')}"').get()) row.data]};
}
Future<void> _flush(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 15)));
    await tester.pump(const Duration(milliseconds: 100));
  }
}
void main() {
  for (final lang in ['ar', 'en']) {
    for (final dark in [false, true]) {
      for (final delete in [false, true]) {
        for (final network in [false, true]) {
          testWidgets('actual transaction ${delete ? 'delete' : 'confirm'} held/failure/retry $lang dark$dark network$network', (tester) async {
            tester.view.physicalSize = const Size(375, 667); tester.view.devicePixelRatio = 1; addTearDown(tester.view.reset);
            final db = (await tester.runAsync(() async {
              final db = await AppDatabase.open(executor: NativeDatabase.memory(), keyStore: _Keys());
              final now = DateTime(2026, 1, 15);
              await DriftAccountRepository(db).create(AccountEntity(id: 'own', name: 'QA account', currency: 'KWD', type: AccountType.bank, isDefault: true, sortOrder: 0, createdAt: now, updatedAt: now));
              await DriftTransactionRepository(db).saveTransaction(transaction: TransactionEntity(id: 'pending', amountMoney: Money(12345, 'KWD'), currency: 'KWD', accountId: 'own', type: TransactionTypeEntity.payment, source: TransactionSourceEntity.bank, occurredAt: now, rawMerchant: 'QA merchant', rawMessage: 'Synthetic SMS', parseConfidence: 1, status: TransactionStatus.pending, createdAt: now, updatedAt: now), categoryKey: 'groceries');
              return db;
            }))!;
            final before = await tester.runAsync(() => _sql(db));
            final repository = FailureOnlyTransactionRepository(db, id: 'pending', delete: delete, network: network);
            await tester.pumpWidget(ProviderScope(overrides: [appDatabaseProvider.overrideWithValue(db), transactionRepositoryProvider.overrideWithValue(repository)], child: MaterialApp(theme: dark ? AppTheme.dark : AppTheme.light, locale: Locale(lang), supportedLocales: AppL10n.supportedLocales, localizationsDelegates: AppL10n.localizationsDelegates, home: const TransactionDetailsScreen(transactionId: 'pending'))));
            await _flush(tester); await tester.pumpAndSettle();
            final l = AppL10n.of(tester.element(find.byType(TransactionDetailsScreen)));
            final confirm = find.widgetWithText(FilledButton, l.txdConfirmTx);
            final remove = find.widgetWithText(TextButton, l.txdDeleteTx);
            final action = delete ? remove : confirm;
            await tester.ensureVisible(action); await tester.tap(action); if (delete) { await tester.pumpAndSettle(); } else { await _flush(tester); }
            if (delete) {
              await tester.tap(find.text(l.commonCancel)); await tester.pumpAndSettle(); expect(repository.calls, 0);
              await tester.ensureVisible(remove); await tester.tap(remove); await tester.pumpAndSettle(); await tester.tap(find.text(l.setDelete));
            }
            await _flush(tester);
            final confirmDisabled = tester.widget<FilledButton>(confirm).onPressed == null;
            final deleteDisabled = tester.widget<TextButton>(remove).onPressed == null;
            await tester.tap(action, warnIfMissed: false); await _flush(tester); final admitted = repository.calls;
            repository.release(); await _flush(tester); await tester.pumpAndSettle();
            final escaped = tester.takeException();
            final feedback = find.text(network ? l.repoErrNetwork : l.repoErrUnknown).evaluate().isNotEmpty;
            final privateVisible = find.textContaining('private_synthetic').evaluate().isNotEmpty;
            final retryEnabled = delete ? tester.widget<TextButton>(remove).onPressed != null : tester.widget<FilledButton>(confirm).onPressed != null;
            await tester.ensureVisible(action); await tester.tap(action); if (delete) { await tester.pumpAndSettle(); } else { await _flush(tester); }
            if (delete) { await tester.tap(find.text(l.setDelete)); }
            await _flush(tester); await tester.pumpAndSettle(); final retryError = tester.takeException();
            final after = await tester.runAsync(() => _sql(db));
            final calls = repository.calls;
            await tester.pump(const Duration(seconds: 4)); await tester.pumpAndSettle();
            await tester.pumpWidget(const SizedBox.shrink()); await tester.pumpAndSettle(); await tester.runAsync(db.close);
            expect(confirmDisabled, isTrue); expect(deleteDisabled, isTrue); expect(admitted, 1);
            expect(escaped, isNull); expect(retryError, isNull); expect(feedback, isTrue); expect(privateVisible, isFalse); expect(retryEnabled, isTrue); expect(calls, 2); expect(after, before);
          });
        }
      }
    }
  }
}
