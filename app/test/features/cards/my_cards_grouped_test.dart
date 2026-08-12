import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/domain/entities/account_entity.dart';
import 'package:money_companion/domain/entities/card_summary.dart';
import 'package:money_companion/domain/services/card_account_grouper.dart';
import 'package:money_companion/engine/parser/card_network.dart';
import 'package:money_companion/features/cards/cards_providers.dart';
import 'package:money_companion/features/cards/my_cards_screen.dart';
import 'package:money_companion/domain/finance/money.dart';

AccountEntity _account(String id, String name) => AccountEntity(
      id: id,
      name: name,
      currency: 'SAR',
      type: AccountType.bank,
      isDefault: false,
      sortOrder: 0,
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
    );

CardSummary _card(String last4) => CardSummary(
      last4: last4,
      currency: 'SAR',
      network: CardNetwork.visa,
      totalOut: Money(10000, 'SAR'),
      totalIn: Money(0, 'SAR'),
      count: 1,
    );

Widget _app(CardGrouping grouping, List<AccountEntity> accounts) {
  return ProviderScope(
    overrides: [
      accountsProvider.overrideWith((_) async => accounts),
      accountCardGroupsProvider.overrideWith((_) async => grouping),
    ],
    child: MaterialApp(
      theme: AppTheme.light,
      home: const Directionality(
        textDirection: TextDirection.rtl,
        child: MyCardsScreen(),
      ),
    ),
  );
}

void main() {
  testWidgets(
      'cards are grouped under their account with an unassigned section',
      (tester) async {
    final grouping = CardGrouping(
      byAccount: {
        'acc-a': [_card('1234')],
      },
      unassigned: [_card('9999')],
    );
    await tester.pumpWidget(_app(grouping, [_account('acc-a', 'بنك الراجحي')]));
    await tester.pumpAndSettle();

    expect(find.text('بنك الراجحي'), findsOneWidget);
    expect(find.text('غير مخصّصة'), findsOneWidget);
    expect(find.text('•••• 1234'), findsOneWidget);
    expect(find.text('•••• 9999'), findsOneWidget);
  });

  testWidgets('no unassigned section when every card is confidently assigned',
      (tester) async {
    final grouping = CardGrouping(
      byAccount: {
        'acc-a': [_card('1234')],
      },
      unassigned: const [],
    );
    await tester.pumpWidget(_app(grouping, [_account('acc-a', 'بنك الراجحي')]));
    await tester.pumpAndSettle();

    expect(find.text('بنك الراجحي'), findsOneWidget);
    expect(find.text('غير مخصّصة'), findsNothing);
  });

  testWidgets('empty state when there are no cards at all', (tester) async {
    await tester.pumpWidget(_app(
      const CardGrouping(byAccount: {}, unassigned: []),
      const [],
    ));
    await tester.pumpAndSettle();

    expect(find.text('مفيش بطاقات لسه'), findsOneWidget);
  });
}
