import 'package:drift/drift.dart';

import '../../domain/entities/supporting_entities.dart';
import '../../domain/repositories/user_settings_repository.dart';
import '../../features/planning_sync/services/planning_outbox_queue.dart';
import '../db/app_database.dart';
import '../db/sql_value_codec.dart';
import 'drift_repository_support.dart';

/// MALI-059n: the versioned tri-state consent → nullable TEXT column
/// (unset ⇒ NULL). Read back by `_consentStateFromRow` in the support layer.
Variable _consentStateVariable(ConsentState state) {
  switch (state) {
    case ConsentState.accepted:
      return Variable.withString('accepted');
    case ConsentState.declined:
      return Variable.withString('declined');
    case ConsentState.unset:
      return const Variable<String>(null);
  }
}

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
      final previousSettings = await getSettings();
      final consentChanged =
          previousSettings.aiConsentState != requiredSettings.aiConsentState ||
              previousSettings.cloudConsentState !=
                  requiredSettings.cloudConsentState;
      await _db.customUpdate(
        '''
        UPDATE user_settings
        SET display_name = ?, phone_number = ?, avatar_path = ?,
            date_of_birth = ?,
            country = ?, currency = ?, language = ?, theme = ?, input_method = ?,
            notifications_json = ?, db_encryption_key_ref = ?,
            privacy_mode_enabled = ?, ai_consent_granted = ?,
            cloud_processing_enabled = ?, ai_consent_state = ?,
            cloud_consent_state = ?, merchant_personalization_enabled = ?,
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
          // MALI-058n — never persist key material: this deprecated column is
          // always written empty, regardless of the entity value.
          const Variable<String>(''),
          Variable.withInt(requiredSettings.privacyModeEnabled ? 1 : 0),
          // MALI-059n: the effective grant is DERIVED from the versioned state,
          // so the boolean and the state can never drift apart on disk.
          Variable.withInt(requiredSettings.aiConsentGranted ? 1 : 0),
          Variable.withInt(requiredSettings.cloudProcessingEnabled ? 1 : 0),
          _consentStateVariable(requiredSettings.aiConsentState),
          _consentStateVariable(requiredSettings.cloudConsentState),
          // COUPONS Phase 1 — persisted locally and DELIBERATELY absent from
          // the settings sync payload below. See UserSettingsEntity.
          Variable.withInt(
              requiredSettings.merchantPersonalizationEnabled ? 1 : 0),
          Variable.withString(requiredSettings.id),
        ],
      );
      // S2: أدرج التفضيلات السحابية للمزامنة في الخلفية (الأعمدة السحابية فقط).
      await _outboxQueue?.enqueueSettings(
        PlanningSyncOperation.update,
        requiredSettings,
        consentChanged: consentChanged,
      );
      return requiredSettings;
    });
  }
}
