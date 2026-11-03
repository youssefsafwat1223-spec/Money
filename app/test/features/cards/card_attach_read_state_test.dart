import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/core/theme/widgets/qirsh_visuals.dart';
import 'package:money_companion/domain/entities/account_entity.dart';
import 'package:money_companion/domain/entities/card_entity.dart';
import 'package:money_companion/domain/entities/card_summary.dart';
import 'package:money_companion/domain/entities/transaction_entity.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/domain/repositories/transaction_repository.dart';
import 'package:money_companion/domain/services/card_account_grouper.dart';
import 'package:money_companion/engine/parser/card_network.dart';
import 'package:money_companion/features/cards/cards_providers.dart';
import 'package:money_companion/features/cards/my_cards_screen.dart';
import 'package:money_companion/features/common/app_empty_state.dart';
import 'package:money_companion/features/common/app_error_state.dart';
import 'package:money_companion/l10n/app_localizations.dart';

class _NoTransactionCalls implements TransactionRepository {
  final calls = <Symbol>[];
  @override
  dynamic noSuchMethod(Invocation invocation) {
    calls.add(invocation.memberName);
    throw StateError('Unexpected repository call ${invocation.memberName}');
  }
}

void main() {
  for (final language in ['ar', 'en']) {
    for (final theme in [AppTheme.light, AppTheme.dark]) {
      for (final width in [375.0, 402.0]) {
        for (final populated in width == 402 ? [false, true] : [false]) {
        testWidgets('actual card link picker $language ${theme.brightness.name} width$width populated$populated separates read outcomes without writes',
            (tester) async {
          tester.view.physicalSize = Size(width, 812);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          await tester.runAsync(() async {
            final fonts = FontLoader('Vazirmatn');
            for (final weight in ['Regular', 'Medium', 'SemiBold', 'Bold']) {
              fonts.addFont(rootBundle.load('assets/fonts/Vazirmatn-$weight.ttf'));
            }
            await fonts.load();
          });
          final now = DateTime(2026, 1, 1);
          final account = AccountEntity(id: 'synthetic-account', name: 'Demo account',
            currency: 'KWD', type: AccountType.bank, isDefault: true,
            sortOrder: 0, createdAt: now, updatedAt: now);
          final card = CardEntity(id: 'synthetic-card', accountId: account.id,
            last4: '1234', network: CardNetwork.visa, source: CardSource.manual,
            createdAt: now, updatedAt: now);
          final queries = <String>[];
          final reads = <Completer<List<TransactionEntity>>>[];
          final repo = _NoTransactionCalls();
          await tester.pumpWidget(ProviderScope(overrides: [
            baseCurrencyProvider.overrideWith((ref) async => 'KWD'),
            accountsProvider.overrideWith((ref) async => [account]),
            allCardsProvider.overrideWith((ref) async => [card]),
            accountCardGroupsProvider.overrideWith((ref) async =>
                const CardGrouping(byAccount: {}, unassigned: <CardSummary>[])),
            transactionRepositoryProvider.overrideWithValue(repo),
            pickTransactionsProvider.overrideWith((ref, query) {
              queries.add(query);
              final request = Completer<List<TransactionEntity>>();
              reads.add(request);
              return request.future;
            }),
          ], child: MaterialApp(theme: theme, locale: Locale(language),
            supportedLocales: AppL10n.supportedLocales,
            localizationsDelegates: AppL10n.localizationsDelegates,
            home: const MyCardsScreen(),
          )));
          await tester.pumpAndSettle();
          final l10n = AppL10n.of(tester.element(find.byType(MyCardsScreen)));
          final link = find.widgetWithText(TextButton, l10n.cardLinkExistingTx);
          await tester.scrollUntilVisible(link, 180,
              scrollable: find.byType(Scrollable).first);
          await tester.tap(link);
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 400));
          expect(queries, ['']);
          expect(find.text(l10n.cardLinkTxTo('1234')), findsOneWidget);
          expect(find.byType(CircularProgressIndicator), findsOneWidget);
          expect(find.byType(AppEmptyState), findsNothing);
          expect(find.text(l10n.cardNoTx), findsNothing);

          if (populated) {
            TransactionEntity candidate(String id, {String? last4}) => TransactionEntity(
              id: id, amountMoney: Money(12345, 'KWD'), currency: 'KWD',
              type: TransactionTypeEntity.payment, source: TransactionSourceEntity.bank,
              occurredAt: now, rawMessage: 'Synthetic read fixture', rawMerchant: id,
              categoryId: 'groceries', parseConfidence: 1,
              status: TransactionStatus.confirmed, createdAt: now, updatedAt: now,
              cardLast4: last4,
            );
            reads[0].complete([candidate('Already linked', last4: '1234'),
                candidate('Available candidate')]);
            await tester.pumpAndSettle();
            final available = find.widgetWithText(ListTile, 'Available candidate');
            final linked = find.widgetWithText(ListTile, 'Already linked');
            expect(available, findsOneWidget);
            expect(linked, findsOneWidget);
            expect(tester.getTopLeft(available).dy, lessThan(tester.getTopLeft(linked).dy));
            expect(tester.widget<ListTile>(available).onTap, isNotNull);
            expect(tester.widget<ListTile>(linked).onTap, isNull);
            expect(find.textContaining('12.345 KWD'), findsNWidgets(2));
            expect(repo.calls, isEmpty);
            expect(tester.takeException(), isNull,
                reason: 'Populated ListTiles must own visible Material above the colored surface.');
            Navigator.of(tester.element(find.text(l10n.cardLinkTxTo('1234')))).pop();
            await tester.pumpAndSettle();
            return;
          }

          reads[0].completeError(StateError('synthetic_candidate_read_failure'));
          await tester.pumpAndSettle();
          expect(repo.calls, isEmpty);
          expect(find.byType(AppErrorState), findsOneWidget);
          expect(find.text(l10n.txnError), findsOneWidget);
          expect(find.text(l10n.cardNoTx), findsNothing,
              reason: 'Failed reads must never claim the ledger is empty.');
          await tester.tap(find.text(l10n.startRetry));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 10));
          expect(queries, ['', '']);
          expect(find.byType(CircularProgressIndicator), findsOneWidget,
              reason: 'Retry admission must show loading before retained error.');
          expect(find.byType(AppErrorState), findsNothing);
          reads[1].complete(const []);
          await tester.pumpAndSettle();
          final empty = tester.widget<AppEmptyState>(find.byType(AppEmptyState));
          expect(empty.title, l10n.cardNoTx);
          expect(empty.subtitle, isEmpty);
          expect(empty.primaryLabel, isNull);
          expect(empty.secondaryLabel, isNull);
          expect(find.byWidgetPredicate((widget) => widget is QirshIllustration &&
              widget.name == 'emptyTx'), findsOneWidget);

          final search = find.byType(TextField);
          await tester.enterText(search, 'first draft');
          await tester.pump(const Duration(milliseconds: 100));
          await tester.enterText(search, 'no-match');
          await tester.pump(const Duration(milliseconds: 249));
          expect(queries, ['', ''], reason: 'Existing 250ms debounce must remain.');
          await tester.pump(const Duration(milliseconds: 1));
          await tester.pump();
          expect(queries, ['', '', 'no-match']);
          expect(find.byType(CircularProgressIndicator), findsOneWidget);
          reads[2].completeError(StateError('synthetic_query_read_failure'));
          await tester.pumpAndSettle();
          expect(find.byType(AppErrorState), findsOneWidget);
          expect(tester.widget<TextField>(search).controller!.text, 'no-match');
          await tester.tap(find.text(l10n.startRetry));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 10));
          expect(queries, ['', '', 'no-match', 'no-match'],
              reason: 'Retry invalidates exactly the currently searched family instance.');
          reads[3].complete(const []);
          await tester.pumpAndSettle();
          expect(find.byType(AppEmptyState), findsOneWidget);
          expect(find.text(l10n.cardNoTx), findsOneWidget);
          expect(tester.widget<TextField>(search).controller!.text, 'no-match');
          expect(repo.calls, isEmpty,
              reason: 'Read/Retry/search actions must not invoke transaction writes.');
          Navigator.of(tester.element(find.text(l10n.cardLinkTxTo('1234')))).pop();
          await tester.pumpAndSettle();
          expect(find.byType(MyCardsScreen), findsOneWidget);
          expect(tester.takeException(), isNull);
        });
        }
      }
    }
  }
}
