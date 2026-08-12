import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/di/app_providers.dart';
import '../../core/session/app_session.dart';
import '../../data/db/app_database.dart';
import '../../data/db/planning_currency_repair.dart';
import '../../data/db/planning_cutover.dart';
import '../../data/db/planning_cutover_executor.dart';
import '../../domain/finance/currency_scale.dart';

enum LegacyPlanningRowKind { budget, goal }

/// A deliberately small, legacy-safe projection for the repair UI.
///
/// This is not, and must not become, a BudgetEntity/GoalEntity. It only reads
/// columns that exist before planning rows gain their canonical Money currency.
class LegacyPlanningRepairRow {
  const LegacyPlanningRepairRow({
    required this.id,
    required this.kind,
    required this.title,
    required this.legacyAmount,
  });

  final String id;
  final LegacyPlanningRowKind kind;
  final String title;

  /// The legacy REAL value, shown only to help the user identify the row. Its
  /// currency is intentionally unknown until the user confirms it.
  final double legacyAmount;
}

class PlanningCurrencyRepairViewData {
  const PlanningCurrencyRepairViewData({
    required this.status,
    required this.proposedCurrency,
    required this.budgets,
    required this.goals,
    required this.manifest,
  });

  final PlanningRepairStatus status;

  /// Display/default proposal only. The manifest service remains the authority.
  final String proposedCurrency;
  final List<LegacyPlanningRepairRow> budgets;
  final List<LegacyPlanningRepairRow> goals;
  final PlanningCurrencyRepairManifest? manifest;

  List<LegacyPlanningRepairRow> get rows => [...budgets, ...goals];
}

final planningCurrencyRepairStoreProvider = Provider<RepairKeyValueStore>(
  (ref) => const SecureRepairKeyValueStore(),
);

final planningCurrencyRepairServiceProvider =
    FutureProvider<PlanningCurrencyRepairService>((ref) async {
  // The database owner is the identity whose local planning rows are visible.
  // Watching the session revision rebuilds this binding after sign-in/out.
  ref.watch(appSessionRevisionProvider);
  final installId = await ref.watch(installIdProvider.future);
  final userId = await AppSession.instance.readLocalDataOwnerUid();
  return PlanningCurrencyRepairService(
    db: ref.watch(appDatabaseProvider),
    store: ref.watch(planningCurrencyRepairStoreProvider),
    installId: installId,
    userId: userId,
  );
});

final planningCurrencyRepairProvider = AutoDisposeAsyncNotifierProvider<
    PlanningCurrencyRepairController, PlanningCurrencyRepairViewData>(
  PlanningCurrencyRepairController.new,
);

class PlanningCurrencyRepairController
    extends AutoDisposeAsyncNotifier<PlanningCurrencyRepairViewData> {
  @override
  Future<PlanningCurrencyRepairViewData> build() async {
    // Re-read when planning rows change while this settings route is open.
    ref.watch(dbRevisionProvider);
    final service =
        await ref.watch(planningCurrencyRepairServiceProvider.future);
    final proposedCurrency =
        (await ref.watch(baseCurrencyProvider.future)).trim().toUpperCase();
    return _read(service, proposedCurrency);
  }

  Future<void> refresh() async {
    final previous = state.valueOrNull;
    state = const AsyncLoading();
    state = await AsyncValue.guard(() async {
      final service =
          await ref.read(planningCurrencyRepairServiceProvider.future);
      final proposedCurrency = previous?.proposedCurrency ??
          (await ref.read(baseCurrencyProvider.future)).trim().toUpperCase();
      return _read(service, proposedCurrency);
    });
  }

  Future<void> confirmGlobal(String currency) async {
    _validateCurrency(currency);
    await _save((service) => service.confirmGlobal(currency));
  }

  Future<void> confirmPerRow(Map<String, String> byId) async {
    for (final currency in byId.values) {
      _validateCurrency(currency);
    }
    await _save((service) => service.confirmPerRow(byId));
  }

  Future<void> _save(
    Future<void> Function(PlanningCurrencyRepairService service) action,
  ) async {
    final previous = state.valueOrNull;
    final service =
        await ref.read(planningCurrencyRepairServiceProvider.future);
    state = const AsyncLoading();
    try {
      await action(service);
      // §13 — the manifest is now satisfied: run the P2 cutover executor (one
      // atomic transaction) and INDEPENDENTLY recompute the coordinator from the
      // committed DB (P2 -> P3), so guard/nav/reads flip to canonical without a
      // restart.
      await PlanningCutoverExecutor(ref.read(appDatabaseProvider), service)
          .execute();
      final coord = ref.read(planningCutoverCoordinatorProvider);
      if (coord is DbBackedPlanningCutoverCoordinator) {
        await coord.refreshFromDatabase();
      }
      final proposedCurrency = previous?.proposedCurrency ??
          (await ref.read(baseCurrencyProvider.future)).trim().toUpperCase();
      state = AsyncData(await _read(service, proposedCurrency));
    } catch (error, stackTrace) {
      state = AsyncError(error, stackTrace);
      rethrow;
    }
  }

  Future<PlanningCurrencyRepairViewData> _read(
    PlanningCurrencyRepairService service,
    String proposedCurrency,
  ) async {
    final db = ref.read(appDatabaseProvider);
    final budgetRows = await _readLegacyBudgets(db);
    final goalRows = await _readLegacyGoals(db);
    final status = await service.evaluate();
    final manifest = status == PlanningRepairStatus.satisfied
        ? await service.currentValidManifest()
        : null;
    return PlanningCurrencyRepairViewData(
      status: status,
      proposedCurrency: proposedCurrency,
      budgets: budgetRows,
      goals: goalRows,
      manifest: manifest,
    );
  }

  static void _validateCurrency(String currency) {
    final code = currency.trim().toUpperCase();
    if (!isSupportedCurrency(code)) {
      throw UnsupportedCurrencyException(code);
    }
  }
}

/// Reads only the v29-era columns needed to identify budgets. In particular,
/// this query never selects or assumes a future `currency` / `_minor` value.
Future<List<LegacyPlanningRepairRow>> _readLegacyBudgets(
  AppDatabase db,
) async {
  final rows = await db.customSelect('''
    SELECT b.id AS id,
           COALESCE(c.name_ar, b.category_id) AS display_name,
           b.amount AS legacy_amount
      FROM budgets AS b
      LEFT JOIN categories AS c ON c.id = b.category_id
     ORDER BY display_name, b.id;
  ''').get();
  return [
    for (final row in rows)
      LegacyPlanningRepairRow(
        id: row.read<String>('id'),
        kind: LegacyPlanningRowKind.budget,
        title: row.read<String>('display_name'),
        legacyAmount: row.read<double>('legacy_amount'),
      ),
  ];
}

/// Reads only the v29-era columns needed to identify goals. Contributions are
/// deliberately absent: their repaired currency always comes from the goal.
Future<List<LegacyPlanningRepairRow>> _readLegacyGoals(AppDatabase db) async {
  final rows = await db.customSelect('''
    SELECT id, name AS display_name, target_amount AS legacy_amount
      FROM goals
     ORDER BY created_at, id;
  ''').get();
  return [
    for (final row in rows)
      LegacyPlanningRepairRow(
        id: row.read<String>('id'),
        kind: LegacyPlanningRowKind.goal,
        title: row.read<String>('display_name'),
        legacyAmount: row.read<double>('legacy_amount'),
      ),
  ];
}
