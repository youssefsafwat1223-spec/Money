import 'dart:convert';

import '../entities/engagement_entities.dart';
import '../entities/supporting_entities.dart';
import '../repositories/user_settings_repository.dart';

class LoadNotificationPreferencesUseCase {
  LoadNotificationPreferencesUseCase(this._repository);

  final UserSettingsRepository _repository;

  Future<NotificationPreferences> call() async {
    final settings = await _repository.getSettings();
    final json = settings.notificationsJson.isEmpty
        ? null
        : jsonDecode(settings.notificationsJson) as Map<String, dynamic>?;
    return NotificationPreferences.fromJson(json);
  }
}

class SaveNotificationPreferencesUseCase {
  SaveNotificationPreferencesUseCase(this._repository);

  final UserSettingsRepository _repository;

  Future<UserSettingsEntity> call(NotificationPreferences preferences) async {
    final settings = await _repository.getSettings();
    return _repository.saveSettings(
      settings.copyWith(
        notificationsJson: jsonEncode(preferences.toJson()),
      ),
    );
  }
}

class LoadUserSettingsUseCase {
  LoadUserSettingsUseCase(this._repository);

  final UserSettingsRepository _repository;

  Future<UserSettingsEntity> call() => _repository.getSettings();
}

class SaveThemeModeUseCase {
  SaveThemeModeUseCase(this._repository);

  final UserSettingsRepository _repository;

  Future<UserSettingsEntity> call(String theme) async {
    final settings = await _repository.getSettings();
    return _repository.saveSettings(settings.copyWith(theme: theme));
  }
}

class SaveCountryCurrencyUseCase {
  SaveCountryCurrencyUseCase(this._repository);

  final UserSettingsRepository _repository;

  Future<UserSettingsEntity> call(String country, String currency) async {
    final settings = await _repository.getSettings();
    return _repository.saveSettings(
      settings.copyWith(country: country, currency: currency),
    );
  }
}
