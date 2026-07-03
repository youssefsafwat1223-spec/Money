import 'package:flutter/foundation.dart';

import 'ledger_push_service.dart';
import 'ledger_sync_service.dart';

/// Thin interfaces so the engine can be tested without Supabase / Drift.
abstract class LedgerPushAdapter {
  Future<LedgerPushResult> push();
}

abstract class LedgerPullAdapter {
  Future<LedgerSyncResult> pull();
}

/// Coordinates push → pull in a single call.
///
/// Order matters: push local edits first so the pull doesn't see a stale
/// server state and mark a locally-edited row as 'synced' before our change
/// reaches the server.
class LedgerSyncEngine {
  LedgerSyncEngine({
    required LedgerPushAdapter pushService,
    required LedgerPullAdapter pullService,
  })  : _push = pushService,
        _pull = pullService;

  final LedgerPushAdapter _push;
  final LedgerPullAdapter _pull;

  Future<void> sync() async {
    try {
      await _push.push();
    } catch (e) {
      if (kDebugMode) debugPrint('[LedgerEngine] push error: $e');
    }
    try {
      await _pull.pull();
    } catch (e) {
      if (kDebugMode) debugPrint('[LedgerEngine] pull error: $e');
    }
  }
}
