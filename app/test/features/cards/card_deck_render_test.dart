import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/domain/entities/account_entity.dart';
import 'package:money_companion/domain/entities/card_entity.dart';
import 'package:money_companion/domain/entities/card_summary.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/domain/repositories/card_repository.dart';
import 'package:money_companion/domain/services/card_account_grouper.dart';
import 'package:money_companion/engine/parser/card_network.dart';
import 'package:money_companion/features/cards/cards_providers.dart';
import 'package:money_companion/features/cards/mini_card_art.dart';
import 'package:money_companion/features/cards/my_cards_screen.dart';
import 'package:money_companion/l10n/app_localizations.dart';

class _ReadOnlyCards implements CardRepository {
  int writes = 0;
  @override
  Future<CardEntity> create(CardEntity card) async { writes++; return card; }
  @override
  Future<CardEntity> update(CardEntity card) async { writes++; return card; }
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected repository operation: ${invocation.memberName}');
}

void main() {
  for (final language in ['ar', 'en']) {
    for (final dark in [false, true]) {
      testWidgets('deck keeps account identities, exact activity and controls $language $dark',
          (tester) async {
        tester.view.physicalSize = const Size(375, 667);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final now = DateTime(2026, 10, 30);
        final accounts = [
          AccountEntity(id: 'kwd', name: 'KWD account', currency: 'KWD',
            type: AccountType.bank, isDefault: true, sortOrder: 0,
            createdAt: now, updatedAt: now),
          AccountEntity(id: 'egp', name: 'EGP account', currency: 'EGP',
            type: AccountType.bank, isDefault: false, sortOrder: 1,
            createdAt: now, updatedAt: now),
        ];
        final managed = CardEntity(id: 'managed', accountId: 'kwd',
          last4: '1234', network: CardNetwork.visa, source: CardSource.manual,
          nickname: 'Personal card', colorTheme: 'plum', accentHex: '#10B981',
          createdAt: now, updatedAt: now);
        final kwd = CardSummary(last4: '1234', currency: 'KWD',
          network: CardNetwork.visa, totalOut: Money(9007199254740993, 'KWD'),
          totalIn: Money(12345, 'KWD'), count: 1,
          colorTheme: 'plum', accentHex: '#10B981');
        final egp = CardSummary(last4: '1234', currency: 'EGP',
          network: CardNetwork.visa, totalOut: Money(25000, 'EGP'),
          totalIn: Money.zero('EGP'), count: 1);
        final unassigned = CardSummary(last4: '5678', currency: 'JPY',
          network: CardNetwork.unknown, totalOut: Money(123, 'JPY'),
          totalIn: Money.zero('JPY'), count: 1);
        final repo = _ReadOnlyCards();
        await tester.pumpWidget(ProviderScope(overrides: [
          baseCurrencyProvider.overrideWith((ref) async => 'KWD'),
          accountsProvider.overrideWith((ref) async => accounts),
          allCardsProvider.overrideWith((ref) async => [managed]),
          cardRepositoryProvider.overrideWithValue(repo),
          accountCardGroupsProvider.overrideWith((ref) async => CardGrouping(
            byAccount: {'kwd': [kwd], 'egp': [egp]},
            unassigned: [unassigned])),
          pickTransactionsProvider('').overrideWith((ref) async => const []),
        ], child: MaterialApp(
          theme: dark ? AppTheme.dark : AppTheme.light,
          locale: Locale(language), supportedLocales: AppL10n.supportedLocales,
          localizationsDelegates: AppL10n.localizationsDelegates,
          home: const MyCardsScreen(),
        )));
        await tester.pumpAndSettle();
        final l10n = AppL10n.of(tester.element(find.byType(MyCardsScreen)));
        for (final identity in ['kwd|1234', 'egp|1234', '|5678']) {
          expect(find.byKey(ValueKey('card-deck-$identity')), findsOneWidget);
          expect(find.byKey(ValueKey('card-deck-edit-$identity')).hitTestable(),
              findsOneWidget,
              reason: 'Every exposed card header retains its own edit action');
        }
        final first = tester.getTopLeft(find.byKey(const ValueKey('card-deck-kwd|1234')));
        final second = tester.getTopLeft(find.byKey(const ValueKey('card-deck-egp|1234')));
        expect(second.dy - first.dy, 56);
        final ownEdit = find.byKey(const ValueKey('card-deck-edit-kwd|1234'));
        await tester.tap(ownEdit);
        await tester.pumpAndSettle();
        expect(find.widgetWithText(TextField, 'Personal card'), findsOneWidget);
        Navigator.of(tester.element(find.widgetWithText(TextField, 'Personal card'))).pop();
        await tester.pumpAndSettle();

        final ownActivity = find.byKey(const ValueKey('card-activity-kwd|1234'));
        await tester.scrollUntilVisible(ownActivity, 180,
            scrollable: find.byType(Scrollable).first);
        await tester.ensureVisible(ownActivity);
        await tester.pumpAndSettle();
        expect(find.descendant(of: ownActivity,
          matching: find.textContaining('9,007,199,254,740.993')), findsOneWidget);
        expect(find.descendant(of: ownActivity,
          matching: find.textContaining('12.345')), findsOneWidget);
        final art = tester.widget<MiniCardArt>(find.descendant(of: ownActivity,
          matching: find.byType(MiniCardArt)));
        expect(art.themeKey, 'plum');
        expect(art.accentHex, '#10B981');
        final add = find.descendant(of: ownActivity,
          matching: find.widgetWithText(TextButton, l10n.cardAddTx));
        final link = find.descendant(of: ownActivity,
          matching: find.widgetWithText(TextButton, l10n.cardLinkExistingTx));
        expect(add.hitTestable(), findsOneWidget);
        expect(link.hitTestable(), findsOneWidget);
        expect(tester.widget<TextButton>(add).onPressed, isNotNull);
        await tester.tap(link);
        await tester.pumpAndSettle();
        expect(find.text(l10n.cardLinkTxTo('1234')), findsOneWidget);
        Navigator.of(tester.element(find.text(l10n.cardLinkTxTo('1234')))).pop();
        await tester.pumpAndSettle();

        for (final identity in ['egp|1234', '|5678']) {
          final activity = find.byKey(ValueKey('card-activity-$identity'));
          await tester.scrollUntilVisible(activity, 180,
              scrollable: find.byType(Scrollable).first);
          expect(activity, findsOneWidget);
          expect(find.descendant(of: activity,
            matching: find.textContaining(identity.startsWith('egp') ? '250.00' : '123')),
            findsWidgets);
        }
        expect(repo.writes, 0, reason: 'Rendering, editing then dismissing, and opening a link picker do not write card data');
        expect(tester.takeException(), isNull);
      });
    }
  }
}
