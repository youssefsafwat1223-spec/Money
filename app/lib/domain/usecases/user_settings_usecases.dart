import 'dart:convert';

import '../../core/security/lock_prompt_language.dart';
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
          // The first account's name is DATA: it is written once and the user
          // can rename it. Naming it in the language they are setting the app
          // up in is the honest behaviour — rendering it through the ARB would
          // silently overwrite a name they chose. `settings` is already loaded
          // three lines up, so the language costs nothing to read.
          name: settings.language == 'en' ? 'Main account' : 'الحساب الرئيسي',
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
    final saved =
        await _repository.saveSettings(settings.copyWith(language: language));
    // The OS unlock prompt is composed on the first frame of a cold start,
    // before the encrypted database can be opened, so it cannot read this row.
    // Mirroring here — in the same await chain as the write, not from a
    // provider that may or may not have run — is what makes the prompt's
    // language deterministic rather than one launch behind. See
    // core/security/lock_prompt_language.dart.
    await LockPromptLanguage.set(saved.language);
    return saved;
  }
}
