import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/domain/entities/transaction_entity.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/features/cards/brand_mark.dart';
import 'package:money_companion/features/common/widgets.dart';
import 'package:money_companion/l10n/app_localizations.dart';

TransactionEntity transaction(Money amount, String merchant) => TransactionEntity(
  id: 'visual-row', amountMoney: amount, currency: amount.currency,
  type: TransactionTypeEntity.payment, source: TransactionSourceEntity.card,
  occurredAt: DateTime(2026, 10, 29), rawMessage: 'synthetic fixture',
  rawMerchant: merchant, parseConfidence: 1, status: TransactionStatus.confirmed,
  createdAt: DateTime(2026, 10, 29), updatedAt: DateTime(2026, 10, 29),
);

Future<void> showRow(WidgetTester tester, Money amount, String merchant) async {
  await tester.pumpWidget(ProviderScope(overrides: [
    remoteMerchantLogosAllowedProvider.overrideWithValue(false),
  ], child: MaterialApp(theme: AppTheme.light,
    locale: const Locale('ar'), supportedLocales: AppL10n.supportedLocales,
    localizationsDelegates: AppL10n.localizationsDelegates,
    home: Scaffold(body: TransactionRow(transaction: transaction(amount, merchant), category: null)))));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('legacy account/card rows use bundled merchant logos offline', (tester) async {
    await showRow(tester, Money(1234, 'KWD'), 'Netflix');
    expect(find.byType(BrandMark), findsOneWidget);
    expect(find.byType(SvgPicture), findsOneWidget);
    expect(find.text('−1.234 KWD'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an unknown merchant keeps a safe fallback and zero has no minus', (tester) async {
    await showRow(tester, Money(0, 'EGP'), 'Unknown local shop');
    expect(find.byType(BrandMark), findsNothing);
    expect(find.text('Unknown local shop'), findsOneWidget);
    expect(find.text('0.00 EGP'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
