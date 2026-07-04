import 'package:flutter/foundation.dart';

import 'accounts_pull_service.dart';
import 'accounts_push_service.dart';
import 'planning_pull_service.dart';
import 'planning_push_service.dart';

class PlanningSyncEngine {
  const PlanningSyncEngine({
    required AccountsPushService accountsPushService,
    required AccountsPullService accountsPullService,
    required PlanningPushService planningPushService,
    required PlanningPullService planningPullService,
  })  : _accountsPush = accountsPushService,
        _accountsPull = accountsPullService,
        _planningPush = planningPushService,
        _planningPull = planningPullService;

  final AccountsPushService _accountsPush;
  final AccountsPullService _accountsPull;
  final PlanningPushService _planningPush;
  final PlanningPullService _planningPull;

  Future<void> sync() async {
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
  }
}
