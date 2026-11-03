// Guarded visual QA only; never imported by production lib/.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:money_companion/core/backend/supabase_config.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/data/repositories/drift_account_repository.dart';
import 'package:money_companion/data/repositories/drift_bill_repository.dart';
import 'package:money_companion/data/repositories/drift_card_repository.dart';
import 'package:money_companion/data/repositories/drift_goal_repository.dart';
import 'package:money_companion/data/repositories/drift_plan_repository.dart';
import 'package:money_companion/domain/entities/account_entity.dart';
import 'package:money_companion/domain/entities/bill_entity.dart';
import 'package:money_companion/domain/entities/card_entity.dart';
import 'package:money_companion/domain/entities/goal_entity.dart';
import 'package:money_companion/domain/entities/plan_entity.dart';
import 'package:money_companion/domain/usecases/save_goal_usecase.dart';
import 'package:money_companion/features/accounts/account_form_sheet.dart';
import 'package:money_companion/features/cards/card_form_sheet.dart';
import 'package:money_companion/features/goals/goal_form_screen.dart';
import 'package:money_companion/features/plans/plan_form_sheet.dart';
import 'package:money_companion/features/subscriptions/bill_form_sheet.dart';

const visualParityFormOutcomeKeys = <String>[
  'accountFormSaving', 'accountFormError',
  'cardFormSaving', 'cardFormError',
  'billFormSaving', 'billFormError',
  'goalFormSaving', 'goalFormError',
  'planFormSaving', 'planFormError',
];

final _events = <String, int>{};
Map<String, int> visualParityFormOutcomeEvents() => Map.unmodifiable(_events);

class _WriteOutcome {
  _WriteOutcome(this.key, this.id);
  final String key;
  final String id;

  Future<T> stop<T>(String submittedId) {
    if (submittedId != id) throw StateError('form_outcome_write_identity_mismatch');
    _events.update(key, (value) => value + 1, ifAbsent: () => 1);
    if (key.endsWith('Saving')) return Completer<T>().future;
    return Future<T>.error(StateError('private_synthetic_form_write_failure'));
  }
}

class _AccountWriteOutcome extends DriftAccountRepository {
  _AccountWriteOutcome(super.db, this.outcome);
  final _WriteOutcome outcome;
  @override
  Future<AccountEntity> update(AccountEntity account) => outcome.stop(account.id);
}

class _CardWriteOutcome extends DriftCardRepository {
  _CardWriteOutcome(super.db, this.outcome);
  final _WriteOutcome outcome;
  @override
  Future<CardEntity> update(CardEntity card) => outcome.stop(card.id);
}

class _BillWriteOutcome extends DriftBillRepository {
  _BillWriteOutcome(super.db, this.outcome);
  final _WriteOutcome outcome;
  @override
  Future<BillEntity> save(BillEntity bill) => outcome.stop(bill.id);
}

class _GoalWriteOutcome extends DriftGoalRepository {
  _GoalWriteOutcome(super.db, this.outcome);
  final _WriteOutcome outcome;
  @override
  Future<GoalEntity> save(GoalEntity goal) => outcome.stop(goal.id);
}

class _PlanWriteOutcome extends DriftPlanRepository {
  _PlanWriteOutcome(super.db, this.outcome);
  final _WriteOutcome outcome;
  @override
  Future<PlanEntity> save(PlanEntity plan) => outcome.stop(plan.id);
}

Future<bool> openVisualParityFormOutcome(
    BuildContext context, WidgetRef ref, String key) async {
  if (!visualParityFormOutcomeKeys.contains(key)) return false;
  if (!kDebugMode || SupabaseConfig.isConfigured) {
    throw StateError('form_outcome_requires_offline_debug');
  }
  final db = ref.read(appDatabaseProvider);
  final databases = await db.customSelect('PRAGMA database_list').get();
  if (!databases.any((row) => row.read<String>('name') == 'main' &&
      row.read<String>('file').isEmpty)) {
    throw StateError('form_outcome_requires_memory_database');
  }
  final family = key.substring(0, key.indexOf('Form'));
  final Object? entity = switch (family) {
    'account' => await DriftAccountRepository(db).getById('p-acc-1'),
    'card' => await DriftCardRepository(db).getById('qa-deck-gold'),
    'bill' => await DriftBillRepository(db).getById('p-bill-0'),
    'goal' => await DriftGoalRepository(db).getById('p-goal-0'),
    'plan' => await DriftPlanRepository(db).getById('p-plan-active'),
    _ => null,
  };
  if (entity == null) throw StateError('form_outcome_requires_existing_fixture_row');
  final id = switch (entity) {
    final AccountEntity value => value.id,
    final CardEntity value => value.id,
    final BillEntity value => value.id,
    final GoalEntity value => value.id,
    final PlanEntity value => value.id,
    _ => throw StateError('form_outcome_unexpected_entity'),
  };
  final outcome = _WriteOutcome(key, id);
  final overrides = <Override>[
    if (family == 'account')
      accountRepositoryProvider.overrideWithValue(_AccountWriteOutcome(db, outcome)),
    if (family == 'card')
      cardRepositoryProvider.overrideWithValue(_CardWriteOutcome(db, outcome)),
    if (family == 'bill')
      billRepositoryProvider.overrideWithValue(_BillWriteOutcome(db, outcome)),
    if (family == 'goal') ...[
      goalRepositoryProvider.overrideWithValue(_GoalWriteOutcome(db, outcome)),
      // Normal actual usecase; this verified existing goal cannot reach the
      // optional goal-created engagement branch. No writer authority granted.
      saveGoalUseCaseProvider.overrideWith((ref) =>
        SaveGoalUseCase(ref.watch(goalRepositoryProvider))),
    ],
    if (family == 'plan')
      planRepositoryProvider.overrideWithValue(_PlanWriteOutcome(db, outcome)),
  ];
  if (!context.mounted) return false;
  unawaited(Navigator.of(context).push<void>(MaterialPageRoute<void>(
    builder: (_) => ProviderScope(overrides: overrides,
      // Public modal widgets resolve their own WidgetRef on this Navigator's
      // overlay; the parent application's repository stays untouched.
      child: Navigator(onGenerateRoute: (_) => MaterialPageRoute<void>(
        builder: (_) => _FormHost(entity: entity))),
    ),
  )));
  return true;
}

class _FormHost extends ConsumerStatefulWidget {
  const _FormHost({required this.entity});
  final Object entity;
  @override
  ConsumerState<_FormHost> createState() => _FormHostState();
}

class _FormHostState extends ConsumerState<_FormHost> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      await switch (widget.entity) {
        final AccountEntity value => showAccountForm(context, ref, account: value),
        final CardEntity value => showCardForm(context, ref, card: value),
        final BillEntity value => BillFormSheet.show(context, bill: value),
        final GoalEntity value => GoalFormScreen.showSheet(context, goal: value),
        final PlanEntity value => PlanFormSheet.show(context, existing: value),
        _ => throw StateError('form_outcome_unexpected_entity'),
      };
      if (mounted) Navigator.of(context, rootNavigator: true).pop();
    });
  }

  @override
  Widget build(BuildContext context) => const Scaffold(
    body: Center(child: Text('Synthetic form outcome host')),
  );
}
