import 'package:drift/drift.dart';

import '../../domain/entities/supporting_entities.dart';
import '../../domain/repositories/user_settings_repository.dart';
import '../../features/planning_sync/services/planning_outbox_queue.dart';
import '../db/app_database.dart';
import '../db/sql_value_codec.dart';
import 'drift_repository_support.dart';

class DriftUserSettingsRepository implements UserSettingsRepository {
  DriftUserSettingsRepository(this._db, {PlanningOutboxQueue? outboxQueue})
      : _outboxQueue = outboxQueue;

  final AppDatabase _db;
  final PlanningOutboxQueue? _outboxQueue;

  @override
  Future<UserSettingsEntity> getSettings() async {
    final row = await _db
        .customSelect(
          'SELECT * FROM user_settings LIMIT 1;',
        )
        .getSingle();
    return userSettingsFromRow(row);
  }

  @override
  Future<UserSettingsEntity> saveSettings(UserSettingsEntity settings) async {
    return _db.transaction(() async {
      // Cloud/AI consent persists exactly as the user chose (MALI-001) — the
      // former forced-true clamp made the privacy toggles meaningless.
      final requiredSettings = settings;
      await _db.customUpdate(
        '''
        UPDATE user_settings
        SET display_name = ?, phone_number = ?, avatar_path = ?,
            date_of_birth = ?,
            country = ?, currency = ?, language = ?, theme = ?, input_method = ?,
            notifications_json = ?, db_encryption_key_ref = ?,
            privacy_mode_enabled = ?, ai_consent_granted = ?,
            cloud_processing_enabled = ?,
            updated_at = ${sqlString(dateTimeToSql(DateTime.now().toUtc()))}
        WHERE id = ?;
      ''',
        variables: [
          requiredSettings.displayName == null
              ? const Variable<String>(null)
              : Variable.withString(requiredSettings.displayName!),
          requiredSettings.phoneNumber == null
              ? const Variable<String>(null)
              : Variable.withString(requiredSettings.phoneNumber!),
          requiredSettings.avatarPath == null
              ? const Variable<String>(null)
              : Variable.withString(requiredSettings.avatarPath!),
          requiredSettings.dateOfBirth == null
              ? const Variable<String>(null)
              : Variable.withString(
                  requiredSettings.dateOfBirth!.toUtc().toIso8601String()),
          Variable.withString(requiredSettings.country),
          Variable.withString(requiredSettings.currency),
          Variable.withString(requiredSettings.language),
          Variable.withString(requiredSettings.theme),
          Variable.withString(requiredSettings.inputMethod),
          Variable.withString(requiredSettings.notificationsJson),
          Variable.withString(requiredSettings.dbEncryptionKeyRef),
          Variable.withInt(requiredSettings.privacyModeEnabled ? 1 : 0),
          Variable.withInt(requiredSettings.aiConsentGranted ? 1 : 0),
          Variable.withInt(requiredSettings.cloudProcessingEnabled ? 1 : 0),
          Variable.withString(requiredSettings.id),
        ],
      );
      // S2: أدرج التفضيلات السحابية للمزامنة في الخلفية (الأعمدة السحابية فقط).
      await _outboxQueue?.enqueueSettings(
        PlanningSyncOperation.update,
        requiredSettings,
      );
      return requiredSettings;
    });
  }
}
