import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/domain/entities/account_entity.dart';
import 'package:money_companion/domain/entities/goal_entity.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/domain/repositories/account_repository.dart';
import 'package:money_companion/domain/repositories/goal_repository.dart';
import 'package:money_companion/domain/usecases/save_goal_usecase.dart';
import 'package:money_companion/features/goals/goal_form_screen.dart';

class _GoalRepository implements GoalRepository {
  _GoalRepository({this.saveGate, this.throwOnSave = false});

  final Completer<void>? saveGate;
  final bool throwOnSave;
  var saveCalls = 0;

  @override
  Future<GoalEntity> save(GoalEntity goal) async {
    saveCalls += 1;
    final gate = saveGate;
    if (gate != null) {
      await gate.future;
    }
    if (throwOnSave) {
      throw Exception('boom');
    }
    return goal;
  }

  @override
  Future<GoalEntity?> getById(String id) async => null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _AccountRepository implements AccountRepository {
  @override
  Future<AccountEntity?> getDefault() async => AccountEntity(
        id: 'account-1',
        name: 'Main',
        currency: 'SAR',
        type: AccountType.bank,
        isDefault: true,
        sortOrder: 0,
        createdAt: DateTime.utc(2026),
        updatedAt: DateTime.utc(2026),
      );

  @override
  Future<AccountEntity?> getById(String id) async => getDefault();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Widget _app(_GoalRepository repository, {GoalEntity? goal}) {
  return ProviderScope(
    overrides: [
      goalRepositoryProvider.overrideWithValue(repository),
      saveGoalUseCaseProvider.overrideWithValue(SaveGoalUseCase(repository)),
      accountRepositoryProvider.overrideWithValue(_AccountRepository()),
      activeAccountIdProvider.overrideWith((_) => null),
      baseCurrencyProvider.overrideWith((_) async => 'SAR'),
    ],
    child: MaterialApp(
      theme: AppTheme.light,
      home: GoalFormScreen(goal: goal),
    ),
  );
}

final _editableGoal = GoalEntity(
  id: 'goal-1',
  name: 'Existing',
  currency: 'SAR',
  targetMoney: Money.parse('1000', 'SAR'),
  savedMoney: Money.parse('100', 'SAR'),
  lastNotifiedSavedMoney: Money(0, 'SAR'),
  vaultSkin: 'default_vault',
  status: 'active',
  createdAt: DateTime.utc(2026, 7, 1),
);

Future<void> _tapSubmit(WidgetTester tester, String label) async {
  final submit = find.widgetWithText(
    ElevatedButton,
    label,
    skipOffstage: false,
  );
  await tester.ensureVisible(submit);
  await tester.pump();
  tester.widget<ElevatedButton>(submit).onPressed!();
}

void main() {
  testWidgets('rapid goal submits invoke repository once', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1000));
    final gate = Completer<void>();
    final repository = _GoalRepository(saveGate: gate);
    await tester.pumpWidget(_app(repository, goal: _editableGoal));
    await tester.pump(const Duration(milliseconds: 300));

    await _tapSubmit(tester, 'حفظ التعديل');
    tester.widget<ElevatedButton>(find.byType(ElevatedButton)).onPressed!();
    await tester.pump();
    await tester.pump();

    expect(repository.saveCalls, 1);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(tester.widget<ElevatedButton>(find.byType(ElevatedButton)).onPressed,
        isNull);

    gate.complete();
    await tester.pump(const Duration(milliseconds: 300));
  });

  testWidgets('failed goal save resets loading state and shows SnackBar',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1000));
    final repository = _GoalRepository(throwOnSave: true);
    await tester.pumpWidget(_app(repository, goal: _editableGoal));
    await tester.pump(const Duration(milliseconds: 300));

    await _tapSubmit(tester, 'حفظ التعديل');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(repository.saveCalls, 1);
    expect(find.textContaining('حدث خطأ غير متوقع'), findsOneWidget);
    expect(find.text('حفظ التعديل'), findsOneWidget);
    expect(tester.widget<ElevatedButton>(find.byType(ElevatedButton)).onPressed,
        isNotNull);

    // AppToast schedules a static 3-second auto-dismiss Timer (app_toast.dart)
    // that outlives this test's widget tree unless drained here.
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('deadline is revalidated at submit time', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1000));
    final yesterday = DateTime.now().subtract(const Duration(days: 1));
    final repository = _GoalRepository();
    final staleGoal = GoalEntity(
      id: 'goal-1',
      name: 'Existing',
      currency: 'SAR',
      targetMoney: Money.parse('1000', 'SAR'),
      savedMoney: Money.parse('100', 'SAR'),
      lastNotifiedSavedMoney: Money(0, 'SAR'),
      deadline: yesterday,
      vaultSkin: 'default_vault',
      status: 'active',
      createdAt: DateTime.utc(2026, 7, 1),
    );
    await tester.pumpWidget(_app(repository, goal: staleGoal));
    await tester.pump(const Duration(milliseconds: 300));

    await _tapSubmit(tester, 'حفظ التعديل');
    await tester.pump(const Duration(milliseconds: 300));

    expect(repository.saveCalls, 0);
    expect(find.text('اختار موعدًا نهائيًا قادمًا أو اليوم.'), findsOneWidget);
  });
}
