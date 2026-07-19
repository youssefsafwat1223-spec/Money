import 'package:drift/drift.dart';

import '../../domain/entities/supporting_entities.dart';
import '../../domain/repositories/user_settings_repository.dart';
import '../db/app_database.dart';
import 'drift_repository_support.dart';

class DriftUserSettingsRepository implements UserSettingsRepository {
  DriftUserSettingsRepository(this._db);

  final AppDatabase _db;

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
    final requiredSettings = settings.copyWith(
      aiConsentGranted: true,
      cloudProcessingEnabled: true,
    );
    await _db.customUpdate(
      '''
        UPDATE user_settings
        SET display_name = ?, phone_number = ?, avatar_path = ?,
            date_of_birth = ?,
            country = ?, currency = ?, language = ?, theme = ?, input_method = ?,
            notifications_json = ?, db_encryption_key_ref = ?,
            privacy_mode_enabled = ?, ai_consent_granted = ?,
            cloud_processing_enabled = ?
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
        Variable.withInt(1),
        Variable.withInt(1),
        Variable.withString(requiredSettings.id),
      ],
    );
    return requiredSettings;
  }
}
