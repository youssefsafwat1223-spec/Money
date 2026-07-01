import 'dart:convert';

import '../entities/engagement_entities.dart';
import '../entities/supporting_entities.dart';
import '../repositories/account_repository.dart';
import '../repositories/transaction_repository.dart';
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
  SaveCountryCurrencyUseCase(
    this._repository,
    this._accountRepository,
    this._transactionRepository,
  );

  final UserSettingsRepository _repository;
  final AccountRepository _accountRepository;
  final TransactionRepository _transactionRepository;

  Future<UserSettingsEntity> call(String country, String currency) async {
    final settings = await _repository.getSettings();
    final saved = await _repository.saveSettings(
      settings.copyWith(country: country, currency: currency),
    );

    // The default account is created during first-run seeding with the seeded
    // currency (SAR), before the user picks their country/currency. Align it
    // here — but only while there are no transactions yet, so existing data is
    // never silently relabeled.
    final existing = await _transactionRepository.getRecent(limit: 1);
    if (existing.isEmpty) {
      final account = await _accountRepository.getDefault();
      if (account != null && account.currency != currency) {
        await _accountRepository.update(account.copyWith(currency: currency));
      }
    }
    return saved;
  }
}

class SaveDateOfBirthUseCase {
  SaveDateOfBirthUseCase(this._repository);

  final UserSettingsRepository _repository;

  Future<UserSettingsEntity> call(DateTime dateOfBirth) async {
    final settings = await _repository.getSettings();
    return _repository.saveSettings(
      settings.copyWith(dateOfBirth: dateOfBirth),
    );
  }
}

class SaveLanguageUseCase {
  SaveLanguageUseCase(this._repository);

  final UserSettingsRepository _repository;

  Future<UserSettingsEntity> call(String language) async {
    final settings = await _repository.getSettings();
    return _repository.saveSettings(settings.copyWith(language: language));
  }
}
