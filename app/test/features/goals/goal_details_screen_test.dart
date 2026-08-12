import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/domain/entities/engagement_entities.dart';
import 'package:money_companion/domain/entities/goal_entity.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/domain/repositories/goal_repository.dart';
import 'package:money_companion/domain/usecases/save_goal_usecase.dart';
import 'package:money_companion/features/goals/goal_details_screen.dart';
import 'package:money_companion/features/goals/goals_providers.dart';

class _GoalRepository implements GoalRepository {
  _GoalRepository({this.addGate, this.throwOnAdd = false});

  final Completer<void>? addGate;
  final bool throwOnAdd;
  var addCalls = 0;

  @override
  Future<GoalContributionEntity> addContribution(
    GoalContributionEntity contribution,
  ) async {
    addCalls += 1;
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
  Future<GoalEntity?> getById(String id) async => _goal;

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

GoalDetailsEntity _details() => GoalDetailsEntity(
      goal: _goal,
      contributions: const [],
      progress: 0.1,
      remainingAmount: Money(90000, 'SAR'),
      recommendedDailyAmount: Money(3000, 'SAR'),
      recommendedWeeklyAmount: Money(21000, 'SAR'),
      daysRemaining: 30,
    );

Widget _app(_GoalRepository repository) {
  return ProviderScope(
    overrides: [
      goalRepositoryProvider.overrideWithValue(repository),
      addGoalContributionUseCaseProvider.overrideWithValue(
        AddGoalContributionUseCase(repository),
      ),
      baseCurrencyProvider.overrideWith((_) async => 'SAR'),
      goalDetailsProvider('goal-1').overrideWith((_) async => _details()),
    ],
    child: MaterialApp(
      theme: AppTheme.light,
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

  testWidgets('failed contribution save re-enables button and shows SnackBar',
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
  });
}
