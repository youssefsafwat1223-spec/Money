import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/domain/entities/card_summary.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/domain/finance/money_format.dart';
import 'package:money_companion/domain/services/card_account_grouper.dart';
import 'package:money_companion/engine/parser/card_network.dart';
import 'package:money_companion/features/cards/card_details_screen.dart';
import 'package:money_companion/features/cards/cards_providers.dart';
import 'package:money_companion/features/cards/my_cards_screen.dart';
import 'package:money_companion/features/common/category_catalog.dart';
import 'package:money_companion/l10n/app_localizations.dart';

void main() {
  for (final detail in [false, true]) {
    for (final language in ['ar', 'en']) {
      testWidgets('${detail ? 'card details' : 'cards'} preserves exact minor units in $language',
          (tester) async {
        tester.view.physicalSize = const Size(375, 667);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final amount = Money(9007199254740993, 'KWD');
        final summary = CardSummary(last4: '1234', currency: 'KWD',
          network: CardNetwork.visa, totalOut: amount,
          totalIn: Money(12345, 'KWD'), count: 1);
        await tester.pumpWidget(ProviderScope(overrides: [
          baseCurrencyProvider.overrideWith((ref) async => 'KWD'),
          accountsProvider.overrideWith((ref) async => const []),
          allCardsProvider.overrideWith((ref) async => const []),
          accountCardGroupsProvider.overrideWith((ref) async =>
            CardGrouping(byAccount: const {}, unassigned: [summary])),
          cardSummariesProvider.overrideWith((ref) async => [summary]),
          cardTransactionsProvider('1234').overrideWith((ref) async => const []),
          categoryCatalogProvider.overrideWith((ref) async => CategoryCatalog(const [])),
        ], child: MaterialApp(
          theme: language == 'ar' ? AppTheme.dark : AppTheme.light,
          locale: Locale(language), supportedLocales: AppL10n.supportedLocales,
          localizationsDelegates: AppL10n.localizationsDelegates,
          home: detail ? const CardDetailsScreen(last4: '1234') : const MyCardsScreen(),
        )));
        await tester.pumpAndSettle();
        final exact = find.textContaining(formatMoney(amount));
        expect(exact, findsOneWidget);
        expect(find.textContaining('12.345'), findsOneWidget);
        expect(tester.widget<Text>(exact).textDirection ??
            Directionality.of(tester.element(exact)), TextDirection.ltr);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
