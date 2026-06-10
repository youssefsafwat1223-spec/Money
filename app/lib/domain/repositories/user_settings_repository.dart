import '../entities/supporting_entities.dart';

abstract class UserSettingsRepository {
  Future<UserSettingsEntity> getSettings();
  Future<UserSettingsEntity> saveSettings(UserSettingsEntity settings);
}
