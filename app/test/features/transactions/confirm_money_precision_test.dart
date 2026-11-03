import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/core/utils/app_lucide_icons.dart';
import 'package:money_companion/domain/entities/transaction_entity.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/domain/finance/money_format.dart';
import 'package:money_companion/domain/errors/repo_exceptions.dart';
import 'package:money_companion/domain/repositories/transaction_repository.dart';
import 'package:money_companion/domain/usecases/confirm_transaction_usecase.dart';
import 'package:money_companion/domain/usecases/add_transaction_usecase.dart';
import 'package:money_companion/engine/parser/parse_result.dart';
import 'package:money_companion/features/common/category_catalog.dart';
import 'package:money_companion/features/transactions/transactions_providers.dart';
import 'package:money_companion/features/transactions/widgets/confirm_transaction_sheet.dart';
import 'package:money_companion/l10n/app_localizations.dart';

class _RefusingConfirmRepository implements TransactionRepository {
  _RefusingConfirmRepository(this.error);
  final Object error;
  var calls = 0;
  @override
  Future<TransactionEntity> confirm(String transactionId) async {
    calls++;
    throw error;
  }
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  for (final language in ['ar', 'en']) {
    for (final typedError in [false, true]) {
      testWidgets('confirmation refusal shows error and keeps transaction in $language typed=$typedError', (tester) async {
        tester.view.physicalSize = const Size(375, 667);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final now = DateTime.utc(2026, 1, 1);
        final tx = TransactionEntity(id: 'refused', amountMoney: Money(12345, 'KWD'),
          currency: 'KWD', type: TransactionTypeEntity.payment,
          source: TransactionSourceEntity.bank, occurredAt: now,
          rawMessage: 'Synthetic unchanged bank message', parseConfidence: 1,
          status: TransactionStatus.pending, createdAt: now, updatedAt: now);
        final repository = _RefusingConfirmRepository(typedError
            ? const NetworkRepoException() : StateError('synthetic_confirm_failure'));
        await tester.pumpWidget(ProviderScope(overrides: [
          transactionByIdProvider(tx.id).overrideWith((ref) async => tx),
          categoryCatalogProvider.overrideWith((ref) async => CategoryCatalog(const [])),
          accountsProvider.overrideWith((ref) async => const []),
          transactionRepositoryProvider.overrideWithValue(repository),
          confirmTransactionUseCaseProvider.overrideWithValue(ConfirmTransactionUseCase(repository)),
        ], child: MaterialApp(theme: language == 'ar' ? AppTheme.dark : AppTheme.light,
          locale: Locale(language), supportedLocales: AppL10n.supportedLocales,
          localizationsDelegates: AppL10n.localizationsDelegates,
          home: Builder(builder: (context) => Scaffold(body: TextButton(
            onPressed: () => showConfirmTransactionSheet(context, tx.id),
            child: const Text('Open refused')))),
        )));
        await tester.tap(find.text('Open refused'));
        await tester.pumpAndSettle();
        final l10n = AppL10n.of(tester.element(find.text('Open refused')));
        final confirm = find.text(l10n.txdConfirmTx);
        await tester.ensureVisible(confirm);
        await tester.tap(confirm);
        await tester.pumpAndSettle();
        expect(repository.calls, 1);
        expect(find.byIcon(AppLucideIcons.alertCircle), findsOneWidget);
        expect(find.byIcon(AppLucideIcons.checkCircle), findsNothing);
        if (!typedError) expect(find.text(l10n.ctsConfirmFailed), findsOneWidget);
        expect(find.byKey(const Key('confirmation-original-message')), findsOneWidget);
        expect(find.text('12.345 KWD'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pump(const Duration(seconds: 4));
        await tester.pumpAndSettle();
      });
    }
  }
  for (final foreign in [false, true]) {
    for (final language in ['ar', 'en']) {
      testWidgets('confirmation preserves ${foreign ? 'foreign' : 'local'} exact Money in $language',
          (tester) async {
        tester.view.physicalSize = const Size(375, 667);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final amount = Money(foreign ? 12345 : 9007199254740993, 'KWD');
        final now = DateTime(2026, 1, 1);
        const rawMessage = '  Bank SMS\nPaid KWD 12.345 at Test Merchant\nCard ending 1234  ';
        final tx = TransactionEntity(id: 'test',
          amountMoney: foreign ? Money.zero('SAR') : amount,
          currency: foreign ? 'SAR' : 'KWD',
          foreignMoney: foreign ? amount : null,
          foreignCurrency: foreign ? 'KWD' : null,
          type: TransactionTypeEntity.payment, source: TransactionSourceEntity.bank,
          occurredAt: now, rawMessage: rawMessage, parseConfidence: 1,
          status: TransactionStatus.pending, createdAt: now, updatedAt: now);
        await tester.pumpWidget(ProviderScope(overrides: [
          transactionByIdProvider('test').overrideWith((ref) async => tx),
          categoryCatalogProvider.overrideWith((ref) async => CategoryCatalog(const [])),
          accountsProvider.overrideWith((ref) async => const []),
        ], child: MaterialApp(
          theme: language == 'ar' ? AppTheme.dark : AppTheme.light,
          locale: Locale(language), supportedLocales: AppL10n.supportedLocales,
          localizationsDelegates: AppL10n.localizationsDelegates,
          home: Builder(builder: (context) => Scaffold(body: TextButton(
            onPressed: () => showConfirmTransactionSheet(context, 'test'),
            child: const Text('Open')))),
        )));
        if (!foreign) {
          final context = tester.element(find.text('Open'));
          expect(feeNoticeFor(context,
              AddTransactionResult.added(tx, ParseResult.notTransaction())),
              AppL10n.of(context).ctsFeeAlsoAdded(formatMoney(amount), 'KWD'));
        }
        await tester.tap(find.text('Open'));
        await tester.pumpAndSettle();
        final exact = find.text('${formatMoney(amount)} KWD');
        expect(exact, findsOneWidget);
        expect(tester.widget<Text>(exact).textDirection, TextDirection.ltr);
        final original = find.descendant(
            of: find.byKey(const Key('confirmation-original-message')),
            matching: find.byType(SelectableText));
        expect(original, findsOneWidget);
        expect(tester.widget<SelectableText>(original).data, rawMessage);
        if (foreign) expect(find.byType(TextField), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
