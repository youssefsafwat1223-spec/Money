// Offline QA only. Actual public GoalDetails contribution UI before writes.
import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:money_companion/core/backend/supabase_config.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/i18n/locale_provider.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/repositories/drift_goal_repository.dart';
import 'package:money_companion/domain/entities/account_entity.dart';
import 'package:money_companion/domain/entities/goal_entity.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/domain/usecases/goal_details_usecase.dart';
import 'package:money_companion/domain/usecases/save_goal_usecase.dart';
import 'package:money_companion/features/goals/goal_details_screen.dart';

const visualParityGoalContributionOutcomeKeys = <String>[
  'goalContributionSaving',
  'goalContributionError',
  'goalContributionInvalid',
];
final _events = <String, int>{};
Map<String, int> visualParityGoalContributionOutcomeEvents() =>
    Map.unmodifiable(_events);
void _event(String key) => _events.update(key, (n) => n + 1, ifAbsent: () => 1);
const _goalId = 'qa-contribution-goal';

class _Keys implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'goal-contribution-owned-memory';
  @override
  Future<String?> readStoredKey() async => 'goal-contribution-owned-memory';
}

class _ContributionOutcome extends DriftGoalRepository {
  _ContributionOutcome(super.database, this.key);
  final String key;
  @override
  Future<GoalContributionEntity> addContribution(GoalContributionEntity value) {
    if (value.goalId != _goalId ||
        value.amountMoney != Money(1250, 'KWD') ||
        key.endsWith('Invalid')) {
      _event('goalContributionForbiddenInput');
      throw StateError('goal_contribution_visual_unexpected_input');
    }
    _event(key);
    return key.endsWith('Saving')
        ? Completer<GoalContributionEntity>().future
        : Future<GoalContributionEntity>.error(
            StateError('private_goal_contribution_failure'));
  }

  @override
  Future<GoalEntity> save(GoalEntity goal) {
    _event('goalContributionForbiddenWrite');
    throw StateError('goal_contribution_visual_save_forbidden');
  }

  @override
  Future<void> delete(String id) {
    _event('goalContributionForbiddenWrite');
    throw StateError('goal_contribution_visual_delete_forbidden');
  }
}

Future<bool> openVisualParityGoalContributionOutcome(
    BuildContext context, WidgetRef ref, String key) async {
  if (!visualParityGoalContributionOutcomeKeys.contains(key)) return false;
  if (!kDebugMode || SupabaseConfig.isConfigured) {
    throw StateError('goal_contribution_visual_requires_offline_debug');
  }
  final rows = await ref
      .read(appDatabaseProvider)
      .customSelect('PRAGMA database_list')
      .get();
  if (!rows.any((r) =>
      r.read<String>('name') == 'main' && r.read<String>('file').isEmpty)) {
    throw StateError('goal_contribution_visual_requires_memory_parent');
  }
  if (!context.mounted) return false;
  final locale = Localizations.localeOf(context);
  final db = await AppDatabase.open(
      executor: NativeDatabase.memory(),
      keyStore: _Keys(),
      initialLanguage: 'en');
  ProviderContainer? child;
  try {
    final setup = ProviderContainer(
        overrides: [appDatabaseProvider.overrideWithValue(db)]);
    try {
      final at = DateTime.utc(2026, 11, 1);
      final account = await setup.read(accountRepositoryProvider).create(
          AccountEntity(
              id: 'qa-contribution-account',
              name: 'QA contribution account',
              currency: 'KWD',
              type: AccountType.bank,
              isDefault: true,
              sortOrder: 0,
              createdAt: at,
              updatedAt: at,
              initialBalanceMoney: Money.zero('KWD'),
              currentBalanceMoney: Money.zero('KWD')));
      await setup.read(goalRepositoryProvider).save(GoalEntity(
          id: _goalId,
          name: 'QA KWD contribution goal',
          currency: 'KWD',
          accountId: account.id,
          targetMoney: Money(50000, 'KWD'),
          savedMoney: Money(12345, 'KWD'),
          lastNotifiedSavedMoney: Money.zero('KWD'),
          vaultSkin: 'default_vault',
          status: 'active',
          createdAt: at));
    } finally {
      setup.dispose();
    }
    final repository = _ContributionOutcome(db, key);
    child = ProviderContainer(overrides: [
      appDatabaseProvider.overrideWithValue(db),
      localeProvider.overrideWithValue(locale),
      goalRepositoryProvider.overrideWithValue(repository),
      goalDetailsUseCaseProvider
          .overrideWithValue(GoalDetailsUseCase(repository)),
      addGoalContributionUseCaseProvider
          .overrideWithValue(AddGoalContributionUseCase(repository)),
    ]);
    if (!context.mounted) {
      child.dispose();
      await db.close();
      return false;
    }
    final owned = child;
    _event('${key}Opened');
    unawaited(Navigator.of(context).push<void>(MaterialPageRoute<void>(
        builder: (_) =>
            _ContributionHost(container: owned, database: db, keyName: key))));
    return true;
  } catch (_) {
    child?.dispose();
    await db.close();
    rethrow;
  }
}

class _ContributionHost extends StatefulWidget {
  const _ContributionHost(
      {required this.container, required this.database, required this.keyName});
  final ProviderContainer container;
  final AppDatabase database;
  final String keyName;
  @override
  State<_ContributionHost> createState() => _ContributionHostState();
}

class _ContributionHostState extends State<_ContributionHost> {
  @override
  void dispose() {
    widget.container.dispose();
    unawaited(
        widget.database.close().then((_) => _event('${widget.keyName}Closed')));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => UncontrolledProviderScope(
      container: widget.container,
      child: Navigator(
          onGenerateRoute: (_) => MaterialPageRoute<void>(
              builder: (_) => const GoalDetailsScreen(goalId: _goalId))));
}
