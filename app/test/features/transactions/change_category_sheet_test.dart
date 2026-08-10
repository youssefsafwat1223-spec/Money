import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/domain/entities/category_entity.dart';
import 'package:money_companion/domain/entities/transaction_entity.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/features/common/category_catalog.dart';
import 'package:money_companion/features/transactions/widgets/change_category_sheet.dart';

void main() {
  testWidgets('category scope options paint on their own Material surface',
      (tester) async {
    final now = DateTime.utc(2026, 7, 18, 12);
    final transaction = TransactionEntity(
      id: 'tx-1',
      amountMoney: Money.fromLegacyReal(100, 'EGP'),
      currency: 'EGP',
      type: TransactionTypeEntity.payment,
      source: TransactionSourceEntity.bank,
      occurredAt: now,
      rawMessage: 'test',
      rawMerchant: 'Test merchant',
      categoryId: 'food',
      parseConfidence: 1,
      status: TransactionStatus.confirmed,
      createdAt: now,
      updatedAt: now,
    );
    final catalog = CategoryCatalog(const [
      CategoryEntity(
        id: 'food',
        key: 'food',
        nameAr: 'مطاعم',
        icon: 'utensils',
        color: '#22C55E',
        isIncome: false,
        sort: 1,
      ),
    ]);

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: AppTheme.light,
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showChangeCategorySheet(
                  context,
                  transaction,
                  catalog,
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('هذه العملية فقط'), findsOneWidget);
    expect(find.text('كل عمليات هذا المتجر'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
