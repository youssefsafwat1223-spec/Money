import 'dart:convert';

import '../entities/account_entity.dart';
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
    final existing = await _transactionRepository.getRecent(limit: 1);
    final account = await _accountRepository.getDefault();
    if (account == null) {
      // Supabase-primary users do not inherit the device's seeded Drift account.
      // Create their first server account during setup before allowing the
      // onboarding step to complete.
      final now = DateTime.now().toUtc();
      await _accountRepository.create(
        AccountEntity(
          id: '',
          name: 'الحساب الرئيسي',
          currency: currency,
          type: AccountType.bank,
          isDefault: true,
          sortOrder: 0,
          createdAt: now,
          updatedAt: now,
        ),
      );
    } else if (existing.isEmpty && account.currency != currency) {
      // Existing installs may still have the seeded currency (SAR). Relabel it
      // only before the first transaction so historical money never changes
      // meaning silently.
      await _accountRepository.update(account.copyWith(currency: currency));
    }
    // Persist the device preference after the server-backed account operation.
    // A network failure must not leave the UI currency ahead of the account.
    return _repository.saveSettings(
      settings.copyWith(country: country, currency: currency),
    );
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
