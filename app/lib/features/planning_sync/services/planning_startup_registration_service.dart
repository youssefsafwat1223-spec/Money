import 'package:flutter/foundation.dart';

import '../../../data/db/app_database.dart';
import '../../../data/repositories/drift_repository_support.dart';
import '../../../domain/entities/category_entity.dart';
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
  Future<void> registerMissingRows({
    required bool settingsPullCompleted,
  }) async {
    final settings = settingsPullCompleted ? await _registerSettings() : 0;
    final categories = await _registerCustomCategories();
    if (kDebugMode) {
      debugPrint(
        '[PlanningRegistration] done: settings=$settings '
        'categories=$categories '
        'settingsAuthority=${settingsPullCompleted ? 'confirmed' : 'unknown'}',
      );
    }
  }

  Future<int> _registerSettings() async {
    if (!_isEnabled(PlanningOutboxQueue.settingsEntityType)) return 0;
    final row = await _db.customSelect('''
      SELECT * FROM user_settings
      WHERE server_id IS NULL
        AND COALESCE(sync_status, '') != 'pending'
        AND NOT EXISTS (
          SELECT 1 FROM planning_sync_outbox
          WHERE entity_type = '${PlanningOutboxQueue.settingsEntityType}'
        )
      LIMIT 1;
    ''').getSingleOrNull();
    if (row == null) return 0;
    final queued = await _queue.enqueueSettings(
      PlanningSyncOperation.create,
      userSettingsFromRow(row),
    );
    return queued ? 1 : 0;
  }

  Future<int> _registerCustomCategories() async {
    if (!_isEnabled(PlanningOutboxQueue.categoriesEntityType)) return 0;
    final rows = await _db.customSelect('''
      SELECT * FROM categories c
      WHERE c.deleted_at IS NULL
        AND c.key LIKE 'custom_%'
        AND c.server_id IS NULL
        AND COALESCE(c.sync_status, '') != 'pending'
        AND NOT EXISTS (
          SELECT 1 FROM planning_sync_outbox o
          WHERE o.entity_type = '${PlanningOutboxQueue.categoriesEntityType}'
            AND o.entity_id = c.id
        );
    ''').get();
    var queued = 0;
    for (final row in rows) {
      final didQueue = await _queue.enqueueCategory(
        PlanningSyncOperation.create,
        CategoryEntity(
          id: row.read<String>('id'),
          key: row.read<String>('key'),
          nameAr: row.read<String>('name_ar'),
          icon: row.read<String>('icon'),
          color: row.read<String>('color'),
          isIncome: row.read<int>('is_income') == 1,
          sort: row.read<int>('sort_order'),
        ),
      );
      if (didQueue) queued++;
    }
    return queued;
  }
}
