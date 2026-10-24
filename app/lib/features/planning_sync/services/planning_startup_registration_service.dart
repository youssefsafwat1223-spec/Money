import '../../../core/session/account_fence_authority.dart';
import '../../../core/session/app_session.dart';
import '../../../core/session/admission_authority.dart';
import '../../../core/sync/sync_health.dart';
import '../../../core/sync/outbox_failure.dart';

import '../../../data/db/app_database.dart';
import 'planning_outbox_queue.dart';

/// Registers local singleton/custom rows only after the first remote pull.
/// This prevents fresh defaults from overwriting an existing remote profile,
/// while still creating server rows for a genuinely new user.
class PlanningStartupRegistrationService {
  const PlanningStartupRegistrationService({
    required AppDatabase db,
    required PlanningOutboxQueue queue,
    required bool Function(String entityType) isEnabled,
  })  : _db = db,
        _queue = queue,
        _isEnabled = isEnabled;

  final AppDatabase _db;
  final PlanningOutboxQueue _queue;
  final bool Function(String entityType) _isEnabled;

  /// Audit NEW-H-4 — [settingsPullCompleted] is the POSITIVE remote authority
  /// for the settings singleton, and it is required so no call site can forget
  /// it. A failed/errored/cancelled pull means remote existence is UNKNOWN —
  /// and UNKNOWN is not ABSENT: queuing the full-row settings CREATE from an
  /// unbound local row would push this device's fresh defaults/null profile
  /// over the user's real cloud row in the very same sync cycle (the engine
  /// pushes right after registration). The tri-state collapses safely:
  ///   * REMOTE_SETTINGS_FOUND            → the completed pull bound server_id,
  ///     so the unbound query below matches nothing;
  ///   * REMOTE_SETTINGS_CONFIRMED_ABSENT → pull completed AND the row is still
  ///     unbound — only then may the initial full row be created;
  ///   * REMOTE_SETTINGS_UNKNOWN          → registration stays pending and is
  ///     retried on the next cycle whose pull completes.
  /// Custom categories stay ungated: they are keyed by freshly generated local
  /// UUIDs, so their CREATE can only insert a new remote row — it cannot
  /// merge-overwrite an existing one the way the fixed-`local_id` settings
  /// singleton can.
  Future<void> registerMissingRows({required bool settingsPullCompleted}) =>
      registerMissingRowsWithPhase(settingsPullCompleted: settingsPullCompleted,
          phase: SyncPhaseBinding());

  Future<void> registerMissingRowsWithPhase({required bool settingsPullCompleted,
      required SyncPhaseBinding phase}) async {
    void supplied() {
      if (phase.isBound && (!phase.isCurrent || !identical(phase.database, _db))) {
        throw const PlanningDeliveryStopped(PlanningDeliveryStopReason.stale);
      }
    }
    supplied();
    final authority = AccountFenceAuthority.shared;
    final handle = await authority.captureForDatabase(AppSession.instance, _db);
    supplied();
    if (handle == null) throw const PlanningDeliveryStopped(PlanningDeliveryStopReason.unbound);
    void check() {
      supplied(); authority.requireCurrentForDatabase(handle, _db);
    }
    try {
      check();
      if (settingsPullCompleted && _isEnabled(PlanningOutboxQueue.settingsEntityType)) {
        final settings = await authority.runCurrentLocal(handle, _db, () =>
            _db.customSelect('SELECT id FROM user_settings LIMIT 1;').getSingleOrNull());
        check();
        if (settings != null) {
          await _queue.enqueueRegisteredParent(authority, handle,
              entityType: PlanningOutboxQueue.settingsEntityType,
              entityId: settings.read<String>('id'), settingsPullCompleted: true, phase: phase);
          check();
        }
      }
      if (!_isEnabled(PlanningOutboxQueue.categoriesEntityType)) return;
      final categories = await authority.runCurrentLocal(handle, _db, () => _db.customSelect(
          "SELECT id FROM categories WHERE deleted_at IS NULL AND key LIKE 'custom_%';").get());
      check();
      for (final category in categories) {
        check();
        await _queue.enqueueRegisteredParent(authority, handle,
            entityType: PlanningOutboxQueue.categoriesEntityType,
            entityId: category.read<String>('id'), settingsPullCompleted: false, phase: phase);
        check();
      }
    } on StaleAdmissionException {
      throw const PlanningDeliveryStopped(PlanningDeliveryStopReason.stale);
    }
  }
}
