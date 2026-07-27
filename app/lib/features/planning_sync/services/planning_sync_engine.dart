import 'package:flutter/foundation.dart';

import 'accounts_pull_service.dart';
import 'accounts_push_service.dart';
import 'planning_pull_service.dart';
import 'planning_push_service.dart';
import 'planning_child_sync_service.dart';
import 'planning_startup_registration_service.dart';

class PlanningSyncEngine {
  const PlanningSyncEngine({
    required AccountsPushService accountsPushService,
    required AccountsPullService accountsPullService,
    required PlanningPushService planningPushService,
    required PlanningPullService planningPullService,
    required PlanningChildSyncService planningChildSyncService,
    required PlanningStartupRegistrationService startupRegistrationService,
  })  : _accountsPush = accountsPushService,
        _accountsPull = accountsPullService,
        _planningPush = planningPushService,
        _planningPull = planningPullService,
        _planningChildren = planningChildSyncService,
        _startupRegistration = startupRegistrationService;

  final AccountsPushService _accountsPush;
  final AccountsPullService _accountsPull;
  final PlanningPushService _planningPush;
  final PlanningPullService _planningPull;
  final PlanningChildSyncService _planningChildren;
  final PlanningStartupRegistrationService _startupRegistration;

  Future<void> sync() async {
    await syncParents();
    await syncChildren();
  }

  /// Accounts and planning parents must sync before ledger rows so foreign
  /// key/server-ID correlation is available on a fresh second device.
  Future<void> syncParents() async {
    try {
      await _accountsPush.push();
    } catch (e) {
      if (kDebugMode) debugPrint('[PlanningSync] accounts push error: $e');
    }
    try {
      await _accountsPull.pull();
    } catch (e) {
      if (kDebugMode) debugPrint('[PlanningSync] accounts pull error: $e');
    }
    try {
      await _planningPush.push();
    } catch (e) {
      if (kDebugMode) debugPrint('[PlanningSync] planning push error: $e');
    }
    try {
      await _planningPull.pull();
    } catch (e) {
      if (kDebugMode) debugPrint('[PlanningSync] planning pull error: $e');
    }
    // Pull first so an existing remote singleton wins over freshly seeded
    // defaults. Only genuinely missing settings/custom categories are queued.
    try {
      await _startupRegistration.registerMissingRows();
      await _planningPush.push();
    } catch (e) {
      if (kDebugMode) debugPrint('[PlanningSync] registration error: $e');
    }
  }

  /// Called after ledger sync so bill-payment transaction references and plan
  /// links can resolve both sides on their first pass.
  Future<void> syncChildren() async {
    try {
      await _planningChildren.sync();
    } catch (e) {
      if (kDebugMode) debugPrint('[PlanningSync] children error: $e');
    }
  }
}
