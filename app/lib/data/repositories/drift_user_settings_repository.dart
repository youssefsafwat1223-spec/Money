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
    final row = await _db.customSelect(
      'SELECT * FROM user_settings LIMIT 1;',
    ).getSingle();
    return userSettingsFromRow(row);
  }

  @override
  Future<UserSettingsEntity> saveSettings(UserSettingsEntity settings) async {
    await _db.customUpdate(
      '''
        UPDATE user_settings
        SET country = ?, currency = ?, language = ?, theme = ?, input_method = ?,
            notifications_json = ?, db_encryption_key_ref = ?
        WHERE id = ?;
      ''',
      variables: [
        Variable.withString(settings.country),
        Variable.withString(settings.currency),
        Variable.withString(settings.language),
        Variable.withString(settings.theme),
        Variable.withString(settings.inputMethod),
        Variable.withString(settings.notificationsJson),
        Variable.withString(settings.dbEncryptionKeyRef),
        Variable.withString(settings.id),
      ],
    );
    return settings;
  }
}
