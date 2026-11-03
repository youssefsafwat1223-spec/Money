import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/core/utils/app_lucide_icons.dart';
import 'package:money_companion/domain/entities/category_entity.dart';
import 'package:money_companion/domain/entities/transaction_entity.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/domain/repositories/transaction_repository.dart';
import 'package:money_companion/domain/usecases/confirm_transaction_usecase.dart';
import 'package:money_companion/features/common/app_error_state.dart';
import 'package:money_companion/features/common/category_catalog.dart';
import 'package:money_companion/features/transactions/manual_transaction_sheet.dart';
import 'package:money_companion/l10n/app_localizations.dart';

final _transaction = TransactionEntity(
  id: 'synthetic-edit', amountMoney: Money.parse('59.95', 'EGP'), currency: 'EGP',
  type: TransactionTypeEntity.payment, source: TransactionSourceEntity.bank,
  occurredAt: DateTime.utc(2026, 10, 1), rawMessage: 'synthetic', parseConfidence: 1,
  status: TransactionStatus.pending, createdAt: DateTime.utc(2026, 10, 1),
  updatedAt: DateTime.utc(2026, 10, 1), categoryId: 'category',
  rawMerchant: 'Existing merchant', note: 'Existing note', accountId: 'synthetic-account',
);

class _Transactions implements TransactionRepository {
  _Transactions({this.failConfirm = false});
  final bool failConfirm;
  var updateCalls = 0;
  var confirmCalls = 0;
  Map<String, Object?>? lastUpdate;
  @override
  Future<TransactionEntity> updateTransaction({required String transactionId,
      required Money amount, required String currency, required TransactionTypeEntity type,
      required DateTime occurredAt, required String? rawMerchant, required String? categoryId,
      required String? note, String? accountId}) async {
    updateCalls++;
    lastUpdate = {'id': transactionId, 'amount': amount, 'currency': currency,
      'merchant': rawMerchant, 'note': note, 'accountId': accountId, 'categoryId': categoryId};
    throw StateError('synthetic_write_refused');
  }
  @override
  Future<TransactionEntity> confirm(String id) async {
    confirmCalls++;
    if (failConfirm) throw StateError('synthetic_confirm_refused');
    return _transaction.copyWith(status: TransactionStatus.confirmed);
  }
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

CategoryCatalog _catalog(String language) => CategoryCatalog(const [
  CategoryEntity(id: 'category', key: 'groceries', nameAr: 'بقالة',
    icon: 'shopping-cart', color: '#16A37F', isIncome: false, sort: 0),
], languageCode: language);

Future<AppL10n> _open(WidgetTester tester, String language, _Transactions repository,
    {Future<CategoryCatalog> Function()? loadCatalog}) async {
  tester.view.physicalSize = const Size(375, 667);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(ProviderScope(overrides: [
    categoryCatalogProvider.overrideWith((ref) =>
      loadCatalog?.call() ?? Future.value(_catalog(language))),
    accountsProvider.overrideWith((ref) async => const []),
    transactionRepositoryProvider.overrideWithValue(repository),
    confirmTransactionUseCaseProvider.overrideWithValue(ConfirmTransactionUseCase(repository)),
  ], child: MaterialApp(theme: language == 'ar' ? AppTheme.dark : AppTheme.light,
    locale: Locale(language), supportedLocales: AppL10n.supportedLocales,
    localizationsDelegates: AppL10n.localizationsDelegates,
    home: Scaffold(body: Builder(builder: (context) => TextButton(
      onPressed: () => ManualTransactionSheet.show(context, transaction: _transaction),
      child: const Text('Open manual'),
    ))),
  )));
  await tester.tap(find.text('Open manual'));
  await tester.pumpAndSettle();
  return AppL10n.of(tester.element(find.byType(ManualTransactionSheet)));
}

Future<void> _tap(WidgetTester tester, String label) async {
  final button = find.widgetWithText(FilledButton, label);
  await tester.ensureVisible(button);
  await tester.tap(button);
  await tester.pumpAndSettle();
}

Future<void> _expire(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 4));
  await tester.pumpAndSettle();
}

void main() {
  for (final language in ['ar', 'en']) {
    testWidgets('manual localized input reaches canonical parser without separator loss in $language', (tester) async {
      final repository = _Transactions();
      final l10n = await _open(tester, language, repository);
      final inputs = <(String, int)>[
        ('١٢٫٣٤', 1234),
        ('١٬٢٣٤٫٥٦', 123456),
        ('1,234.56', 123456),
        ('1 234.56', 123456),
        ('1\u00a0234.56', 123456),
        ('1،234.56', 123456),
      ];
      for (final spec in inputs) {
        await tester.ensureVisible(find.byType(TextField).first);
        await tester.enterText(find.byType(TextField).first, spec.$1);
        tester.testTextInput.hide();
        await _tap(tester, l10n.mtSaveEdits);
        expect(repository.lastUpdate!['amount'], Money(spec.$2, 'EGP'));
        expect(repository.lastUpdate!['currency'], 'EGP');
        expect(tester.widget<TextField>(find.byType(TextField).first).controller!.text, spec.$1);
        expect(find.text(l10n.mtSaveFailed), findsOneWidget);
        await _expire(tester);
      }
      expect(repository.updateCalls, inputs.length);
      expect(tester.takeException(), isNull);
    });

    testWidgets('manual rejects negative and ambiguous input intact before any write in $language', (tester) async {
      final repository = _Transactions();
      final l10n = await _open(tester, language, repository);
      for (final input in ['-1', '1٬23', '12٬50', '1.234,50', '12.345', 'abc12']) {
        await tester.ensureVisible(find.byType(TextField).first);
        await tester.enterText(find.byType(TextField).first, input);
        tester.testTextInput.hide();
        await _tap(tester, l10n.mtSaveEdits);
        expect(repository.updateCalls, 0);
        expect(repository.confirmCalls, 0);
        expect(tester.widget<TextField>(find.byType(TextField).first).controller!.text, input);
        expect(find.text(l10n.mtEnterValidAmount), findsOneWidget);
        expect(find.byIcon(AppLucideIcons.alertCircle), findsOneWidget);
        expect(find.byType(ManualTransactionSheet), findsOneWidget);
        await _expire(tester);
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets('manual save refusal retains exact draft and shows error in $language', (tester) async {
      final repository = _Transactions();
      final l10n = await _open(tester, language, repository);
      await tester.enterText(find.byType(TextField).at(0), '12.34');
      await tester.enterText(find.byType(TextField).at(1), 'Updated merchant');
      await tester.ensureVisible(find.byType(TextField).at(2));
      await tester.enterText(find.byType(TextField).at(2), 'Updated note');
      tester.testTextInput.hide();
      await _tap(tester, l10n.mtSaveEdits);
      expect(repository.updateCalls, 1);
      expect(repository.lastUpdate, {'id': _transaction.id, 'amount': Money(1234, 'EGP'),
        'currency': 'EGP', 'merchant': 'Updated merchant', 'note': 'Updated note',
        'accountId': 'synthetic-account', 'categoryId': 'category'});
      expect(find.text(l10n.mtSaveFailed), findsOneWidget);
      expect(find.byIcon(AppLucideIcons.alertCircle), findsOneWidget);
      expect(find.byIcon(AppLucideIcons.checkCircle), findsNothing);
      expect(find.byType(ManualTransactionSheet), findsOneWidget);
      final controllers = tester.widgetList<TextField>(find.byType(TextField)).map((w) => w.controller!.text).toList();
      expect(controllers, ['12.34', 'Updated merchant', 'Updated note']);
      expect(tester.takeException(), isNull);
      await _expire(tester);
    });

    for (final fail in [false, true]) {
      testWidgets('manual confirm preserves notice semantics fail=$fail in $language', (tester) async {
        final repository = _Transactions(failConfirm: fail);
        final l10n = await _open(tester, language, repository);
        await _tap(tester, l10n.txdConfirmTx);
        expect(repository.confirmCalls, 1);
        expect(repository.updateCalls, 0);
        expect(find.text(fail ? l10n.mtConfirmFailed : l10n.txdConfirmedToast), findsOneWidget);
        expect(find.byIcon(fail ? AppLucideIcons.alertCircle : AppLucideIcons.checkCircle), findsOneWidget);
        expect(find.byIcon(fail ? AppLucideIcons.checkCircle : AppLucideIcons.alertCircle), findsNothing);
        expect(find.byType(ManualTransactionSheet), findsOneWidget);
        expect(tester.takeException(), isNull);
        await _expire(tester);
      });
    }

    testWidgets('manual catalog error offers real scoped Retry and preserves editing draft in $language', (tester) async {
      var reads = 0;
      final repository = _Transactions();
      final l10n = await _open(tester, language, repository, loadCatalog: () async {
        reads++;
        if (reads == 1) throw StateError('synthetic_catalog_read_failure');
        return _catalog(language);
      });
      expect(find.byType(AppErrorState), findsOneWidget);
      expect(find.text(l10n.mtCategoriesFailed), findsOneWidget);
      expect(reads, 1);
      expect(repository.updateCalls + repository.confirmCalls, 0);
      await tester.tap(find.text(l10n.startRetry));
      await tester.pumpAndSettle();
      expect(reads, 2);
      expect(find.byType(AppErrorState), findsNothing);
      final controllers = tester.widgetList<TextField>(find.byType(TextField)).map((w) => w.controller!.text).toList();
      expect(controllers, ['59.95', 'Existing merchant', 'Existing note']);
      expect(repository.updateCalls + repository.confirmCalls, 0);
      expect(tester.takeException(), isNull);
    });
  }
}
