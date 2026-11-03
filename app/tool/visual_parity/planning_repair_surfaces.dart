// Offline read-only presentation states; never imported by lib/.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:money_companion/core/backend/supabase_config.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/data/db/planning_currency_repair.dart';
import 'package:money_companion/features/common/planning_repair_gate.dart';
import 'package:money_companion/features/planning_sync/services/planning_server_currency_repair.dart';
import 'package:money_companion/features/settings/planning_currency_repair_providers.dart';
import 'package:money_companion/features/settings/planning_currency_repair_screen.dart';
import 'package:money_companion/features/settings/planning_server_repair_providers.dart';

const visualParityPlanningRepairKeys = [
  'planningRepairGate', 'planningRepairSaveFailure',
  'planningRepairNone', 'planningRepairConfirm', 'planningRepairStale',
  'planningRepairDone', 'planningRepairLoading', 'planningRepairError',
  'planningRepairServer', 'planningRepairServerError',
];

final _events = <String, int>{};
Map<String, int> visualParityPlanningRepairEvents() => Map.unmodifiable(_events);
void _record(String key) => _events.update(key, (value) => value + 1, ifAbsent: () => 1);

class _PresentationRepair extends PlanningCurrencyRepairController {
  _PresentationRepair(this.mode);
  final String mode;

  PlanningCurrencyRepairViewData _data(PlanningRepairStatus status) =>
      PlanningCurrencyRepairViewData(status: status, proposedCurrency: 'EGP',
        budgets: const [LegacyPlanningRepairRow(id: 'synthetic-budget',
          kind: LegacyPlanningRowKind.budget, title: 'Synthetic groceries', legacyAmount: 1250.50)],
        goals: const [LegacyPlanningRepairRow(id: 'synthetic-goal',
          kind: LegacyPlanningRowKind.goal, title: 'Synthetic trip', legacyAmount: 5000.25)],
        manifest: null);

  @override
  Future<PlanningCurrencyRepairViewData> build() {
    if (mode == 'planningRepairLoading') {
      return Completer<PlanningCurrencyRepairViewData>().future;
    }
    if (mode == 'planningRepairError') {
      throw StateError('synthetic_planning_repair_read_failure');
    }
    return Future.value(_data(switch (mode) {
      'planningRepairConfirm' || 'planningRepairSaveFailure' => PlanningRepairStatus.needsConfirmation,
      'planningRepairStale' => PlanningRepairStatus.stale,
      'planningRepairDone' => PlanningRepairStatus.satisfied,
      _ => PlanningRepairStatus.notRequired,
    }));
  }

  @override
  Future<void> refresh() async {
    _record('planningRepairReadRetry');
    state = AsyncData(_data(PlanningRepairStatus.notRequired));
  }

  // The presentation fixture must never reach the repair service, cutover
  // executor or a manifest writer. It provides no repair authority.
  @override
  Future<void> confirmGlobal(String currency) async {
    _record('planningRepairApplyBlocked');
    if (mode == 'planningRepairSaveFailure') {
      await Future<void>.delayed(const Duration(seconds: 5));
    }
    throw StateError('visual_presentation_cannot_apply_repair');
  }
  @override
  Future<void> confirmPerRow(Map<String, String> byId) => confirmGlobal('');
}

Future<bool> openVisualParityPlanningRepair(
    BuildContext context, WidgetRef ref, String key) async {
  if (!visualParityPlanningRepairKeys.contains(key)) return false;
  if (!kDebugMode || SupabaseConfig.isConfigured) {
    throw StateError('planning_repair_visual_requires_offline_debug');
  }
  final rows = await ref.read(appDatabaseProvider)
      .customSelect('PRAGMA database_list').get();
  if (!rows.any((row) => row.read<String>('name') == 'main' &&
      row.read<String>('file').isEmpty)) {
    throw StateError('planning_repair_visual_requires_memory_database');
  }
  if (!context.mounted) return false;
  if (key == 'planningRepairGate') {
    // The public interstitial only: no coordinator override or cutover state
    // is created. Existing CTA navigation remains the production behavior.
    unawaited(Navigator.of(context).push<void>(MaterialPageRoute<void>(
      builder: (_) => const PlanningRepairRequiredView(),
    )).then<void>((_) {}, onError: (Object error, StackTrace stack) {
      FlutterError.reportError(FlutterErrorDetails(exception: error, stack: stack,
          library: 'Qirsh offline planning gate presentation'));
    }));
    return true;
  }
  var serverReads = 0;
  unawaited(Navigator.of(context).push<void>(MaterialPageRoute<void>(builder: (_) =>
    ProviderScope(overrides: [
      planningCurrencyRepairProvider.overrideWith(() => _PresentationRepair(key)),
      serverUnresolvedPlanningItemsProvider.overrideWith((ref) async {
        if (key == 'planningRepairServerError' && serverReads++ == 0) {
          throw StateError('synthetic_server_repair_worklist_read_failure');
        }
        return key == 'planningRepairServer' ? [
          for (var i = 0; i < 6; i++) PlanningRepairItem(
            entityType: i.isEven ? 'goal' : 'budget', serverId: 'synthetic-$i',
            firstSeenAt: '2026-01-15', title: 'Synthetic item ${i + 1}', amountText: '12.345'),
        ] : const [];
      }),
      planningCurrencyRepairServiceProvider.overrideWith((ref) =>
          throw StateError('visual_presentation_cannot_construct_repair_service')),
      planningServerCurrencyRepairServiceProvider.overrideWith((ref) =>
          throw StateError('visual_presentation_cannot_construct_server_repair_service')),
    ], child: const PlanningCurrencyRepairScreen()))).then<void>((_) {},
      onError: (Object error, StackTrace stack) {
        FlutterError.reportError(FlutterErrorDetails(exception: error, stack: stack,
            library: 'Qirsh offline planning repair presentation'));
      }));
  return true;
}
