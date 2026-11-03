import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/core/utils/app_lucide_icons.dart';
import 'package:money_companion/domain/entities/engagement_entities.dart';
import 'package:money_companion/domain/entities/goal_entity.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/domain/repositories/goal_repository.dart';
import 'package:money_companion/domain/usecases/save_goal_usecase.dart';
import 'package:money_companion/features/goals/goal_details_screen.dart';
import 'package:money_companion/features/goals/goals_providers.dart';
import 'package:money_companion/l10n/app_localizations.dart';

class _GoalRepository implements GoalRepository {
  _GoalRepository({this.addGate, this.throwOnAdd = false, GoalEntity? goal})
      : goal = goal ?? _goal;

  final Completer<void>? addGate;
  final bool throwOnAdd;
  var addCalls = 0;
  final GoalEntity goal;
  GoalContributionEntity? lastContribution;

  @override
  Future<GoalContributionEntity> addContribution(
    GoalContributionEntity contribution,
  ) async {
    addCalls += 1;
    lastContribution = contribution;
    final gate = addGate;
    if (gate != null) {
      await gate.future;
    }
    if (throwOnAdd) {
      throw Exception('boom');
    }
    return contribution;
  }

  @override
  Future<GoalEntity?> getById(String id) async => goal;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final _goal = GoalEntity(
  id: 'goal-1',
  name: 'Emergency fund',
  currency: 'SAR',
  targetMoney: Money.parse('1000', 'SAR'),
  savedMoney: Money.parse('100', 'SAR'),
  lastNotifiedSavedMoney: Money(0, 'SAR'),
  vaultSkin: 'default_vault',
  status: 'active',
  createdAt: DateTime.utc(2026, 7, 1),
);

GoalDetailsEntity _details(GoalEntity goal) => GoalDetailsEntity(
      goal: goal,
      contributions: const [],
      progress: 0.1,
      remainingAmount: goal.targetMoney - goal.savedMoney,
      recommendedDailyAmount: Money.parse('30', goal.currency),
      recommendedWeeklyAmount: Money.parse('210', goal.currency),
      daysRemaining: 30,
    );

Widget _app(_GoalRepository repository, {String language = 'ar', bool dark = false}) {
  return ProviderScope(
    overrides: [
      goalRepositoryProvider.overrideWithValue(repository),
      addGoalContributionUseCaseProvider.overrideWithValue(
        AddGoalContributionUseCase(repository),
      ),
      baseCurrencyProvider.overrideWith((_) async => 'SAR'),
      goalDetailsProvider('goal-1').overrideWith((_) async => _details(repository.goal)),
    ],
    child: MaterialApp(
      localizationsDelegates: AppL10n.localizationsDelegates,
      supportedLocales: AppL10n.supportedLocales,
      locale: Locale(language),
      theme: dark ? AppTheme.dark : AppTheme.light,
      home: const GoalDetailsScreen(goalId: 'goal-1'),
    ),
  );
}

Future<void> _openContributionSheet(
  WidgetTester tester,
  _GoalRepository repository,
) async {
  await tester.binding.setSurfaceSize(const Size(800, 1600));
  await tester.pumpWidget(_app(repository));
  await tester.pump(const Duration(milliseconds: 300));
  await tester.tap(find.text('أضف للهدف').first);
  await tester.pump(const Duration(milliseconds: 300));
  await tester.enterText(find.byType(TextField).first, '50');
  tester.testTextInput.hide();
  await tester.pump();
}

void main() {
  for (final language in ['ar', 'en']) {
    for (final dark in [false, true]) {
      testWidgets('long goal sheet title leaves Close reachable on compact $language dark=$dark', (tester) async {
        tester.view.physicalSize = const Size(375, 667);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final name = language == 'ar'
            ? 'الادخار لشراء منزل جديد وتجهيزه بالكامل للأسرة في المستقبل'
            : 'Saving for a new family home and all the furniture we need';
        final repository = _GoalRepository(goal: _goal.copyWith(name: name));
        await tester.pumpWidget(_app(repository, language: language, dark: dark));
        await tester.pumpAndSettle();
        final context = tester.element(find.byType(GoalDetailsScreen));
        unawaited(GoalDetailsScreen.showSheet(context, 'goal-1'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final title = find.text(name).last;
        final close = find.widgetWithIcon(IconButton, AppLucideIcons.x);
        expect(close.hitTestable(), findsOneWidget);
        expect(tester.getRect(title).overlaps(tester.getRect(close)), isFalse);
        await tester.tap(close);
        await tester.pumpAndSettle();
        expect(find.widgetWithIcon(IconButton, AppLucideIcons.x), findsNothing);
        expect(find.byType(GoalDetailsScreen), findsOneWidget);
        expect(repository.addCalls, 0);
        expect(tester.takeException(), isNull);
      });

      testWidgets('goal Delete and Add controls stay separate on compact $language dark=$dark', (tester) async {
        tester.view.physicalSize = const Size(375, 667);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(_app(_GoalRepository(), language: language, dark: dark));
        await tester.pumpAndSettle();
        final l10n = AppL10n.of(tester.element(find.byType(GoalDetailsScreen)));
        final add = find.widgetWithText(FilledButton, l10n.gdAddToGoal);
        final delete = find.text(l10n.gdDeleteGoal);
        await tester.scrollUntilVisible(delete, 300,
            scrollable: find.byType(Scrollable).first);
        await tester.pumpAndSettle();
        expect(delete.hitTestable(), findsOneWidget);
        expect(add.hitTestable(), findsOneWidget);
        expect(tester.getRect(delete).overlaps(tester.getRect(add)), isFalse);
        expect(tester.getBottomRight(delete).dy,
            lessThan(tester.getTopLeft(add).dy));
        await tester.tap(add);
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('goal-contribution-preset-250')), findsOneWidget);
        expect(tester.takeException(), isNull);
      });

      testWidgets('contribution presets and Save remain reachable above keyboard: $language dark=$dark', (tester) async {
        tester.view.physicalSize = const Size(375, 667);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final goal = _goal.copyWith(currency: 'KWD',
            targetMoney: Money.parse('1000', 'KWD'),
            savedMoney: Money.parse('100', 'KWD'),
            lastNotifiedSavedMoney: Money.zero('KWD'));
        final repository = _GoalRepository(goal: goal);
        await tester.pumpWidget(_app(repository, language: language, dark: dark));
        await tester.pumpAndSettle();
        final l10n = AppL10n.of(tester.element(find.byType(GoalDetailsScreen)));
        await tester.tap(find.text(l10n.gdAddToGoal).first);
        await tester.pumpAndSettle();
        for (final amount in [250, 500, 1000, 2000]) {
          final chip = find.byKey(ValueKey('goal-contribution-preset-$amount'));
          await tester.ensureVisible(chip);
          await tester.tap(chip);
          await tester.pumpAndSettle();
          expect(tester.widget<TextField>(find.byType(TextField).first)
              .controller!.text, '$amount.000');
          expect(tester.widget<ChoiceChip>(chip).selected, isTrue);
        }
        tester.view.viewInsets = const FakeViewPadding(bottom: 300);
        await tester.pumpAndSettle();
        final note = find.byType(TextField).last;
        await tester.ensureVisible(note);
        await tester.enterText(note, 'A synthetic contribution');
        await tester.pumpAndSettle();
        final save = find.widgetWithText(FilledButton, l10n.gdSaveContribution);
        expect(save.hitTestable(), findsOneWidget);
        expect(tester.getBottomRight(save).dy, lessThanOrEqualTo(367));
        await tester.tap(save);
        await tester.pumpAndSettle();
        expect(repository.addCalls, 1);
        expect(repository.lastContribution?.amountMoney, Money.parse('2000', 'KWD'));
        expect(repository.lastContribution?.note, 'A synthetic contribution');
        expect(repository.lastContribution?.goalId, 'goal-1');
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('contribution presets keep zero-decimal goal currency', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final repository = _GoalRepository(goal: _goal.copyWith(currency: 'JPY',
        targetMoney: Money.parse('1000', 'JPY'), savedMoney: Money.parse('100', 'JPY'),
        lastNotifiedSavedMoney: Money.zero('JPY')));
    await tester.pumpWidget(_app(repository));
    await tester.pumpAndSettle();
    final l10n = AppL10n.of(tester.element(find.byType(GoalDetailsScreen)));
    await tester.tap(find.text(l10n.gdAddToGoal).first);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('goal-contribution-preset-250')));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(find.byType(TextField).first).controller!.text, '250');
    await tester.tap(find.widgetWithText(FilledButton, l10n.gdSaveContribution));
    await tester.pumpAndSettle();
    expect(repository.lastContribution?.amountMoney, Money.parse('250', 'JPY'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('KWD goal details preserve full target and remaining precision', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final repository = _GoalRepository(goal: _goal.copyWith(currency: 'KWD',
        targetMoney: Money.parse('50.001', 'KWD'), savedMoney: Money.parse('12.345', 'KWD'),
        lastNotifiedSavedMoney: Money.zero('KWD')));
    await tester.pumpWidget(_app(repository, language: 'en'));
    await tester.pumpAndSettle();
    expect(find.text('/ 50.001 KWD'), findsOneWidget);
    expect(find.text('37.656 KWD'), findsOneWidget);
    expect(tester.widget<Text>(find.text('/ 50.001 KWD')).textDirection, TextDirection.ltr);
    expect(tester.takeException(), isNull);
  });

  for (final input in ['١٢٫٣٤٥', '12,345.678']) {
    testWidgets('contribution accepts exact localized KWD input $input', (tester) async {
      final repository = _GoalRepository(goal: _goal.copyWith(currency: 'KWD',
          targetMoney: Money.parse('20000', 'KWD'), savedMoney: Money.zero('KWD'),
          lastNotifiedSavedMoney: Money.zero('KWD')));
      await _openContributionSheet(tester, repository);
      await tester.enterText(find.byType(TextField).first, input);
      tester.testTextInput.hide();
      await tester.pump();
      tester.widget<FilledButton>(find.byType(FilledButton).last).onPressed!();
      await tester.pumpAndSettle();
      expect(repository.addCalls, 1);
      expect(repository.lastContribution?.amountMoney,
          Money.parse(input == '١٢٫٣٤٥' ? '12.345' : '12345.678', 'KWD'));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('invalid contribution retains input and never calls repository', (tester) async {
    final repository = _GoalRepository();
    await _openContributionSheet(tester, repository);
    for (final input in ['abc', '0', '-1', '12.345']) {
      await tester.enterText(find.byType(TextField).first, input);
      tester.testTextInput.hide();
      await tester.pump();
      tester.widget<FilledButton>(find.byType(FilledButton).last).onPressed!();
      await tester.pump(const Duration(milliseconds: 500));
      expect(repository.addCalls, 0);
      expect(tester.widget<TextField>(find.byType(TextField).first).controller!.text, input);
      final l10n = AppL10n.of(tester.element(find.byType(GoalDetailsScreen)));
      expect(find.text(l10n.bfInvalidAmount), findsOneWidget);
      await tester.pump(const Duration(seconds: 4));
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('rapid contribution saves invoke repository once',
      (tester) async {
    final gate = Completer<void>();
    final repository = _GoalRepository(addGate: gate);
    await _openContributionSheet(tester, repository);

    final save = tester.widget<FilledButton>(find.byType(FilledButton).last);
    save.onPressed!();
    save.onPressed!();
    await tester.pump();
    await tester.pump();

    expect(repository.addCalls, 1);
    final saveButton = find.byType(FilledButton).last;
    expect(
      find.descendant(
        of: saveButton,
        matching: find.byType(CircularProgressIndicator),
      ),
      findsOneWidget,
    );
    expect(tester.widget<FilledButton>(saveButton).onPressed, isNull);

    gate.complete();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('حفظ المساهمة'), findsNothing);
  });

  testWidgets('failed contribution save re-enables button and shows error notice',
      (tester) async {
    final repository = _GoalRepository(throwOnAdd: true);
    await _openContributionSheet(tester, repository);

    tester.widget<FilledButton>(find.byType(FilledButton).last).onPressed!();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(repository.addCalls, 1);
    expect(find.text('تعذّر حفظ المساهمة الآن.'), findsOneWidget);
    expect(find.text('حفظ المساهمة'), findsOneWidget);
    expect(
        tester.widget<FilledButton>(find.byType(FilledButton).last).onPressed,
        isNotNull);
    await tester.pump(const Duration(seconds: 4));
  });
}
