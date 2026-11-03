import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/domain/entities/plan_entity.dart';
import 'package:money_companion/domain/entities/transaction_entity.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/domain/repositories/plan_repository.dart';
import 'package:money_companion/domain/repositories/transaction_repository.dart';
import 'package:money_companion/features/common/app_card.dart';
import 'package:money_companion/features/common/app_error_state.dart';
import 'package:money_companion/features/common/app_sheet_scaffold.dart';
import 'package:money_companion/features/plans/plans_providers.dart';
import 'package:money_companion/features/plans/plans_screen.dart';
import 'package:money_companion/l10n/app_localizations.dart';

class _ReadRepository implements TransactionRepository {
  _ReadRepository(this.results);
  final List<Future<List<TransactionEntity>> Function()> results;
  final limits = <int>[];
  final filters = <TransactionPageFilter>[];
  @override
  Future<List<TransactionEntity>> getTransactionPage({required int limit,
      TransactionPageCursor? after, TransactionPageFilter filter = const TransactionPageFilter()}) {
    limits.add(limit);
    filters.add(filter);
    return results[limits.length - 1]();
  }
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _LinkRepository implements PlanRepository {
  final calls = <(String, String)>[];
  final pending = Completer<void>();
  @override
  Future<void> linkTransactionToPlan({required String planId, required String transactionId}) {
    calls.add((planId, transactionId));
    return pending.future;
  }
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

TransactionEntity _tx(String id, {TransactionStatus status = TransactionStatus.confirmed}) =>
    TransactionEntity(id: id, amountMoney: Money.parse('12.34', 'EGP'), currency: 'EGP',
      type: TransactionTypeEntity.payment, source: TransactionSourceEntity.bank,
      occurredAt: DateTime(2026, 10, 20), rawMessage: 'synthetic', rawMerchant: 'Merchant $id',
      parseConfidence: 1, status: status, createdAt: DateTime(2026, 10, 20),
      updatedAt: DateTime(2026, 10, 20));

Future<AppL10n> _openPicker(WidgetTester tester, _ReadRepository transactions,
    _LinkRepository plans, {String language = 'en'}) async {
  tester.view.physicalSize = const Size(375, 667);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.runAsync(() async {
    final loader = FontLoader('Vazirmatn');
    for (final weight in ['Regular', 'Medium', 'SemiBold', 'Bold']) {
      loader.addFont(rootBundle.load('assets/fonts/Vazirmatn-$weight.ttf'));
    }
    await loader.load();
  });
  final plan = PlanEntity(id: 'plan', name: 'Synthetic trip',
    budgetAmountMoney: Money.parse('2000', 'EGP'), currency: 'EGP',
    startDate: DateTime(2026, 10, 1), endDate: DateTime(2027, 1, 1),
    accountIds: const [], cardLast4s: const [], status: PlanStatus.active,
    createdAt: DateTime(2026, 10, 1));
  final progress = PlanProgress(plan, Money.zero('EGP'));
  await tester.pumpWidget(ProviderScope(overrides: [
    plansWithSpentProvider.overrideWith((ref) async => [progress]),
    planProgressProvider('plan').overrideWith((ref) async => progress),
    planTransactionsProvider('plan').overrideWith((ref) async => [_tx('linked')]),
    transactionRepositoryProvider.overrideWithValue(transactions),
    planRepositoryProvider.overrideWithValue(plans),
  ], child: MaterialApp(theme: language == 'ar' ? AppTheme.dark : AppTheme.light,
    locale: Locale(language), supportedLocales: AppL10n.supportedLocales,
    localizationsDelegates: AppL10n.localizationsDelegates, home: const PlansScreen())));
  await tester.pumpAndSettle();
  final l10n = AppL10n.of(tester.element(find.byType(PlansScreen)));
  await tester.tap(find.text('Synthetic trip'));
  await tester.pumpAndSettle();
  final link = find.widgetWithText(FilledButton, l10n.plLinkTransaction);
  await tester.ensureVisible(link);
  await tester.tap(link);
  await tester.pump(const Duration(milliseconds: 400));
  return l10n;
}

void main() {
  for (final language in ['ar', 'en']) {
    for (final empty in [false, true]) {
      testWidgets('link picker read failure retries to ${empty ? 'empty' : 'bounded candidates'} without linking $language',
          (tester) async {
        final first = Completer<List<TransactionEntity>>();
        final retry = Completer<List<TransactionEntity>>();
        final read = _ReadRepository([
          () => first.future,
          () => retry.future,
        ]);
        final links = _LinkRepository();
        final l10n = await _openPicker(tester, read, links, language: language);
        expect(read.limits, [500]);
        expect(find.byType(CircularProgressIndicator), findsOneWidget);
        first.completeError(StateError('synthetic read failure'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.byType(AppErrorState), findsOneWidget);
        expect(find.text(l10n.txnError), findsOneWidget);
        expect(find.byType(CircularProgressIndicator), findsNothing);
        expect(find.text(l10n.plNoSuitableTx), findsNothing);
        await tester.tap(find.text(l10n.startRetry));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(read.limits, [500, 500]);
        expect(find.byType(CircularProgressIndicator), findsOneWidget);
        expect(find.text(l10n.startRetry), findsNothing,
            reason: 'a pending explicit retry must not leave an active retry button for the old error');
        retry.complete(empty ? [] : [_tx('linked'), _tx('pending', status: TransactionStatus.pending),
          for (var i = 0; i < 43; i++) _tx('eligible$i')]);
        await tester.pumpAndSettle();
        expect(read.filters.every((filter) => filter.kind == TransactionPageKind.expenses), isTrue);
        expect(find.byType(AppErrorState), findsNothing);
        if (empty) {
          expect(find.text(l10n.plNoSuitableTx), findsOneWidget);
        } else {
          final picker = find.ancestor(of: find.text(l10n.plLinkToPlan),
              matching: find.byType(AppSheetScaffold)).first;
          expect(find.text('Merchant eligible0'), findsOneWidget);
          expect(find.text('Merchant eligible39'), findsOneWidget);
          expect(find.text('Merchant eligible40'), findsNothing);
          expect(find.text('Merchant pending'), findsNothing);
          expect(find.descendant(of: picker, matching: find.text('Merchant linked')), findsNothing);
        }
        expect(links.calls, isEmpty);
        final navigator = tester.state<NavigatorState>(find.byType(Navigator).first);
        navigator.pop();
        await tester.pumpAndSettle();
        expect(links.calls, isEmpty);
        expect(read.limits, [500, 500]);
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('link progress rebuild keeps its read cached and links the exact selected transaction once',
      (tester) async {
    final read = _ReadRepository([() async => [_tx('chosen'), _tx('other')]]);
    final links = _LinkRepository();
    await _openPicker(tester, read, links);
    await tester.pumpAndSettle();
    expect(read.limits, [500]);
    await tester.tap(find.text('Merchant chosen'));
    await tester.pump();
    expect(links.calls, [('plan', 'chosen')]);
    expect(read.limits, [500], reason: 'linkingId rebuild must reuse the bounded read');
    final other = find.ancestor(of: find.text('Merchant other'), matching: find.byType(AppCard)).first;
    expect(tester.widget<AppCard>(other).onTap, isNull);
    links.pending.complete();
    await tester.pumpAndSettle();
    expect(links.calls, [('plan', 'chosen')]);
    expect(read.limits, [500]);
    expect(tester.takeException(), isNull);
  });
}
