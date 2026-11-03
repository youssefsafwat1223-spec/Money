// Offline QA only: sibling-owned Navigator and actual public PlansScreen.
import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:money_companion/core/backend/supabase_config.dart';
import 'package:money_companion/core/di/account_access_mode.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/i18n/locale_provider.dart';
import 'package:money_companion/core/session/account_scope.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/repositories/drift_account_repository.dart';
import 'package:money_companion/data/repositories/drift_plan_repository.dart';
import 'package:money_companion/domain/entities/account_entity.dart';
import 'package:money_companion/domain/entities/plan_entity.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/features/plans/plans_screen.dart';

const visualParityPlanDeleteOutcomeKeys = [
  'planDeleteProgress',
  'planDeleteError'
];
final visualParityPlanDeleteOutcomeOverlay = ValueNotifier<Widget?>(null);
final _events = <String, int>{};
Map<String, int> visualParityPlanDeleteOutcomeEvents() =>
    Map.unmodifiable(_events);
void _event(String key) => _events.update(key, (n) => n + 1, ifAbsent: () => 1);
_PlanFixture? _active;
BuildContext? get visualParityPlanDeleteOutcomeInspectionContext =>
    _active?.navigator.currentContext;
const _planId = 'qa-plan-delete-plan';

class _Keys implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'plan-delete-owned-memory';
  @override
  Future<String?> readStoredKey() async => 'plan-delete-owned-memory';
}

Future<String> _snapshot(AppDatabase db) async {
  final tables = await db
      .customSelect(
          "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name")
      .get();
  return jsonEncode({
    for (final table in tables)
      table.read<String>('name'): (await db
              .customSelect(
                  'SELECT * FROM "${table.read<String>('name')}" ORDER BY rowid')
              .get())
          .map((row) => row.data)
          .toList()
  });
}

class _PlanOutcomeRepository extends DriftPlanRepository {
  _PlanOutcomeRepository(super.db, this.key);
  final String key;
  Completer<void>? _held;
  Future<void>? _activeWrite;

  Never _forbidden() {
    _event('planDeleteForbiddenWrite');
    throw StateError('plan_delete_unexpected_write');
  }

  @override
  Future<void> delete(String id) {
    if (id != _planId) return _forbidden();
    _event(key);
    if (key == 'planDeleteProgress') {
      if (_held != null) return _forbidden();
      _held = Completer<void>();
      _activeWrite = _held!.future.whenComplete(() => _event('${key}Settled'));
      return _activeWrite!;
    }
    return Future<void>.error(StateError('private_plan_delete_failure'));
  }

  @override
  Future<PlanEntity> save(PlanEntity plan) => _forbidden();
  @override
  Future<void> linkTransactionToPlan(
          {required String planId, required String transactionId}) =>
      _forbidden();
  @override
  Future<void> unlinkTransactionFromPlan(
          {required String planId, required String transactionId}) =>
      _forbidden();

  Future<void> cancelAndSettle() async {
    if (_held case final pending? when !pending.isCompleted) {
      _event('${key}Cancelled');
      pending.completeError(StateError('plan_delete_fixture_closed'));
    }
    try {
      await _activeWrite;
    } catch (_) {/* Actual public handler owns error. */}
  }
}

Future<bool> openVisualParityPlanDeleteOutcome(
    BuildContext context, WidgetRef ref, String key) async {
  if (!visualParityPlanDeleteOutcomeKeys.contains(key)) return false;
  if (!kDebugMode || SupabaseConfig.isConfigured) {
    throw StateError('plan_delete_requires_offline_debug');
  }
  if (ref.read(accountAccessModeProvider) != AccountAccessMode.writable) {
    throw StateError('plan_delete_requires_writable_memory_parent');
  }
  final databases = await ref
      .read(appDatabaseProvider)
      .customSelect('PRAGMA database_list')
      .get();
  if (!databases.any((row) =>
      row.read<String>('name') == 'main' && row.read<String>('file').isEmpty)) {
    throw StateError('plan_delete_requires_memory_parent');
  }
  if (!context.mounted) return false;
  if (_active != null) throw StateError('plan_delete_already_open');
  final locale = Localizations.localeOf(context);
  final db = await AppDatabase.open(
      executor: NativeDatabase.memory(),
      keyStore: _Keys(),
      initialLanguage: 'en');
  ProviderContainer? child;
  try {
    final at = DateTime.utc(2026, 11, 1);
    final account = await DriftAccountRepository(db).create(AccountEntity(
        id: 'qa-plan-delete-account',
        name: 'QA plan account',
        currency: 'KWD',
        type: AccountType.bank,
        isDefault: true,
        sortOrder: 0,
        createdAt: at,
        updatedAt: at,
        initialBalanceMoney: Money.zero('KWD'),
        currentBalanceMoney: Money.zero('KWD')));
    await DriftPlanRepository(db).save(PlanEntity(
        id: _planId,
        name: 'QA KWD delete plan',
        budgetAmountMoney: Money(123450, 'KWD'),
        currency: 'KWD',
        startDate: at,
        endDate: DateTime.utc(2027, 1, 1),
        accountIds: [account.id],
        cardLast4s: const [],
        status: PlanStatus.active,
        createdAt: at));
    final repository = _PlanOutcomeRepository(db, key);
    child = ProviderContainer(overrides: [
      appDatabaseProvider.overrideWithValue(db),
      localeProvider.overrideWithValue(locale),
      planRepositoryProvider.overrideWithValue(repository),
    ]);
    final baseline = await _snapshot(db);
    if (!context.mounted) {
      child.dispose();
      await db.close();
      return false;
    }
    final fixture = _PlanFixture(db, child, repository, baseline, key);
    _active = fixture;
    _event('${key}Opened');
    visualParityPlanDeleteOutcomeOverlay.value = _PlanHost(fixture);
    return true;
  } catch (_) {
    child?.dispose();
    await db.close();
    rethrow;
  }
}

Future<void> closeVisualParityPlanDeleteOutcome() {
  final fixture = _active;
  if (fixture == null) return Future<void>.value();
  // Removing this sibling unmounts all actual public dialogs and the list.
  // Do not pop progress while its awaiting public handler is still mounted.
  visualParityPlanDeleteOutcomeOverlay.value = null;
  if (!fixture.mounted) unawaited(fixture.disposeOnce());
  return fixture.closed.future;
}

class _PlanFixture {
  _PlanFixture(
      this.db, this.container, this.repository, this.baseline, this.key);
  final AppDatabase db;
  final ProviderContainer container;
  final _PlanOutcomeRepository repository;
  final String baseline;
  final String key;
  final navigator = GlobalKey<NavigatorState>();
  final closed = Completer<void>();
  bool mounted = false;
  bool disposing = false;
  Future<void> disposeOnce() async {
    if (disposing) return;
    disposing = true;
    // Allow the complete owned subtree to unmount before rejecting the await.
    await Future<void>.delayed(Duration.zero);
    _event('${key}UnmountedBeforeCancel');
    try {
      await repository.cancelAndSettle();
      await db.customSelect('SELECT 1').get();
      if (await _snapshot(db) != baseline) {
        throw StateError('plan_delete_child_sql_changed');
      }
      _event('${key}AllSqlUnchanged');
    } finally {
      container.dispose();
      await db.close();
      if (identical(_active, this)) {
        _active = null;
        visualParityPlanDeleteOutcomeOverlay.value = null;
      }
      _event('${key}Closed');
      closed.complete();
    }
  }
}

class _PlanHost extends StatefulWidget {
  const _PlanHost(this.fixture);
  final _PlanFixture fixture;
  @override
  State<_PlanHost> createState() => _PlanHostState();
}

class _PlanHostState extends State<_PlanHost> {
  @override
  void initState() {
    super.initState();
    widget.fixture.mounted = true;
  }

  @override
  void dispose() {
    widget.fixture.mounted = false;
    unawaited(widget.fixture.disposeOnce());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => UncontrolledProviderScope(
      container: widget.fixture.container,
      child: HeroControllerScope.none(
          child: Navigator(
              key: widget.fixture.navigator,
              onGenerateRoute: (_) => MaterialPageRoute<void>(
                  builder: (_) => const PlansScreen()))));
}
