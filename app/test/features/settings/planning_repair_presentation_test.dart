import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/core/theme/widgets/qirsh_visuals.dart';
import 'package:money_companion/data/db/planning_currency_repair.dart';
import 'package:money_companion/features/planning_sync/services/planning_server_currency_repair.dart';
import 'package:money_companion/features/settings/planning_currency_repair_providers.dart';
import 'package:money_companion/features/settings/planning_currency_repair_screen.dart';
import 'package:money_companion/features/settings/planning_server_repair_providers.dart';
import 'package:money_companion/features/settings/planning_server_repair_section.dart';
import 'package:money_companion/l10n/app_localizations.dart';

class _ReadOnlyRepair extends PlanningCurrencyRepairController {
  _ReadOnlyRepair(this.confirmation, {this.status});
  final bool confirmation;
  final PlanningRepairStatus? status;
  @override
  Future<PlanningCurrencyRepairViewData> build() async =>
      PlanningCurrencyRepairViewData(status: status ?? (confirmation
          ? PlanningRepairStatus.needsConfirmation : PlanningRepairStatus.notRequired),
        proposedCurrency: 'EGP', manifest: null,
        budgets: const [LegacyPlanningRepairRow(id: 'b1', kind: LegacyPlanningRowKind.budget,
            title: 'Synthetic groceries', legacyAmount: 1250.50)],
        goals: const [LegacyPlanningRepairRow(id: 'g1', kind: LegacyPlanningRowKind.goal,
            title: 'Synthetic trip', legacyAmount: 5000.25)]);
}

PlanningRepairItem _item(int index) => PlanningRepairItem(
    entityType: 'goal', serverId: 's$index', firstSeenAt: 'synthetic',
    title: 'Synthetic goal $index', amountText: '12.345');

Future<AppL10n> _pump(WidgetTester tester, List<Override> overrides,
    {String language = 'en', Widget child = const PlanningCurrencyRepairScreen(),
    bool settle = true}) async {
  tester.view.physicalSize = const Size(375, 667);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.runAsync(() async {
    final fonts = FontLoader('Vazirmatn');
    for (final weight in ['Regular', 'Medium', 'SemiBold', 'Bold']) {
      fonts.addFont(rootBundle.load('assets/fonts/Vazirmatn-$weight.ttf'));
    }
    await fonts.load();
  });
  await tester.pumpWidget(ProviderScope(overrides: [
    planningCurrencyRepairProvider.overrideWith(() => _ReadOnlyRepair(false)),
    serverUnresolvedPlanningItemsProvider.overrideWith((ref) async => const []),
    planningCurrencyRepairServiceProvider.overrideWith((ref) =>
        throw StateError('a presentation test must not construct a repair service')),
    planningServerCurrencyRepairServiceProvider.overrideWith((ref) =>
        throw StateError('a presentation test must not construct a server repair service')),
    ...overrides,
  ], child: MaterialApp(theme: language == 'ar' ? AppTheme.dark : AppTheme.light,
    locale: Locale(language), supportedLocales: AppL10n.supportedLocales,
    localizationsDelegates: AppL10n.localizationsDelegates, home: child)));
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump(const Duration(milliseconds: 100));
  }
  return AppL10n.of(tester.element(find.byType(Scaffold).first));
}

void main() {
  for (final status in [PlanningRepairStatus.notRequired, PlanningRepairStatus.satisfied]) {
    for (final serverState in ['pending', 'error', 'loading']) {
      testWidgets('local ${status.name} never claims global success while server repair is $serverState',
          (tester) async {
        final loading = Completer<List<PlanningRepairItem>>();
        final l10n = await _pump(tester, [
          planningCurrencyRepairProvider.overrideWith(() => _ReadOnlyRepair(false, status: status)),
          serverUnresolvedPlanningItemsProvider.overrideWith((ref) async {
            if (serverState == 'loading') return loading.future;
            if (serverState == 'error') throw StateError('synthetic server read error');
            return [_item(0)];
          }),
        ], settle: serverState != 'loading');
        expect(find.text(l10n.pcrNothingToFix), findsNothing);
        expect(find.text(l10n.pcrConfirmed), findsNothing);
        expect(find.byType(QirshIllustration), findsNothing,
            reason: 'a local terminal state must not imply all server repair work is complete');
        if (serverState == 'pending') {
          expect(find.byKey(const ValueKey('server-repair-currency-goal-s0')), findsOneWidget);
        } else if (serverState == 'error') {
          expect(find.text(l10n.pcrReadFailed), findsOneWidget);
          expect(find.text(l10n.annRetry), findsOneWidget);
        } else {
          expect(find.byType(CircularProgressIndicator), findsOneWidget);
        }
        final back = find.text(l10n.pcrBackToSettings);
        await tester.ensureVisible(back);
        await tester.pump(const Duration(milliseconds: 100));
        expect(back.hitTestable(), findsOneWidget);
        if (serverState == 'loading') {
          loading.complete(const []);
          await tester.pumpAndSettle();
          expect(find.text(status == PlanningRepairStatus.notRequired
              ? l10n.pcrNothingToFix : l10n.pcrConfirmed), findsOneWidget);
          expect(find.byType(QirshIllustration), findsOneWidget);
        }
        expect(tester.takeException(), isNull);
      });
    }
  }

  for (final language in ['ar', 'en']) {
    testWidgets('many server repair items remain reachable without overflow in $language',
        (tester) async {
      final l10n = await _pump(tester, [
        serverUnresolvedPlanningItemsProvider.overrideWith((ref) async =>
            [for (var i = 0; i < 6; i++) _item(i)]),
      ], language: language);
      expect(tester.takeException(), isNull);
      final last = find.byKey(const ValueKey('server-repair-currency-goal-s5'));
      await tester.scrollUntilVisible(last, 140, scrollable: find.byType(Scrollable).first);
      await tester.pumpAndSettle();
      expect(last.hitTestable(), findsOneWidget);
      expect(tester.widget<TextField>(last).controller!.text, isEmpty);
      await tester.enterText(last, 'EGP');
      tester.view.viewInsets = const FakeViewPadding(bottom: 260);
      await tester.pumpAndSettle();
      await tester.ensureVisible(last);
      await tester.pumpAndSettle();
      expect(tester.getBottomRight(last).dy, lessThanOrEqualTo(667 - 260));
      tester.testTextInput.hide();
      tester.view.viewInsets = const FakeViewPadding();
      await tester.pumpAndSettle();
      final back = find.text(l10n.pcrBackToSettings);
      await tester.scrollUntilVisible(back, 150, scrollable: find.byType(Scrollable).first);
      await tester.pumpAndSettle();
      expect(back.hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('English per-row repair uses localized kinds',
      (tester) async {
    final l10n = await _pump(tester, [
      planningCurrencyRepairProvider.overrideWith(() => _ReadOnlyRepair(true)),
    ]);
    final mode = find.byKey(const ValueKey('repair-mode-per-row'));
    await tester.scrollUntilVisible(mode, 150, scrollable: find.byType(Scrollable).last);
    await tester.tap(mode);
    await tester.pumpAndSettle();
    final goal = find.text('${l10n.rprGoal} · Synthetic trip');
    await tester.scrollUntilVisible(goal, 150, scrollable: find.byType(Scrollable).last);
    await tester.pumpAndSettle();
    expect(goal, findsOneWidget);
    expect(find.text('${l10n.rprBudget} · Synthetic groceries'), findsOneWidget);
    expect(find.text('هدف · Synthetic trip'), findsNothing);
    expect(find.byKey(const ValueKey('repair-currency-g1')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('server worklist read error shows Retry and recovers without any repair service',
      (tester) async {
    var reads = 0;
    final l10n = await _pump(tester, [
      serverUnresolvedPlanningItemsProvider.overrideWith((ref) async {
        if (reads++ == 0) throw StateError('synthetic worklist read failure');
        return const [];
      }),
    ]);
    expect(find.text(l10n.pcrReadFailed), findsOneWidget);
    await tester.tap(find.text(l10n.annRetry));
    await tester.pumpAndSettle();
    expect(reads, 2);
    expect(find.text(l10n.pcrReadFailed), findsNothing);
    expect(find.text(l10n.pcrNothingToFix), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('server row drafts stay with their exact item when the worklist order changes',
      (tester) async {
    final rows = StateProvider<List<PlanningRepairItem>>((ref) => [_item(0), _item(1)]);
    await _pump(tester, [
      serverUnresolvedPlanningItemsProvider.overrideWith((ref) async => ref.watch(rows)),
    ], child: const Scaffold(body: SingleChildScrollView(child: PlanningServerRepairSection())));
    final first = find.byKey(const ValueKey('server-repair-currency-goal-s0'));
    final second = find.byKey(const ValueKey('server-repair-currency-goal-s1'));
    await tester.enterText(first, 'EGP');
    final container = ProviderScope.containerOf(tester.element(first));
    container.read(rows.notifier).state = [_item(1), _item(0)];
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(first).controller!.text, 'EGP');
    expect(tester.widget<TextField>(second).controller!.text, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('unsupported server currency shows the shared error notice without a repair service',
      (tester) async {
    final l10n = await _pump(tester, [
      serverUnresolvedPlanningItemsProvider.overrideWith((ref) async => [_item(0)]),
    ]);
    final field = find.byKey(const ValueKey('server-repair-currency-goal-s0'));
    await tester.enterText(field, 'XXX');
    tester.testTextInput.hide();
    await tester.tap(find.text(l10n.txnConfirm));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text(l10n.psrUnsupported), findsOneWidget);
    expect(tester.takeException(), isNull,
        reason: 'invalid input must be rejected before constructing the blocked repair service');
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
  });
}
