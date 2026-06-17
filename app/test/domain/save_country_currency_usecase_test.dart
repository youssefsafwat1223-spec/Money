import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/domain/entities/supporting_entities.dart';
import 'package:money_companion/domain/repositories/user_settings_repository.dart';
import 'package:money_companion/domain/usecases/user_settings_usecases.dart';

const _defaults = UserSettingsEntity(
  id: 'default',
  country: 'sa',
  currency: 'SAR',
  language: 'ar',
  theme: 'system',
  inputMethod: 'sms',
  notificationsJson: '',
  dbEncryptionKeyRef: '',
  privacyModeEnabled: false,
);

class _FakeRepo implements UserSettingsRepository {
  UserSettingsEntity _stored = _defaults;

  @override
  Future<UserSettingsEntity> getSettings() async => _stored;

  @override
  Future<UserSettingsEntity> saveSettings(UserSettingsEntity settings) async {
    _stored = settings;
    return _stored;
  }
}

void main() {
  group('SaveCountryCurrencyUseCase', () {
    test('persists country and currency, leaves other fields unchanged', () async {
      final repo = _FakeRepo();
      final useCase = SaveCountryCurrencyUseCase(repo);

      await useCase('eg', 'EGP');

      final saved = await repo.getSettings();
      expect(saved.country, 'eg');
      expect(saved.currency, 'EGP');
      // Other fields untouched.
      expect(saved.language, _defaults.language);
      expect(saved.theme, _defaults.theme);
    });

    test('overwrites a previous selection', () async {
      final repo = _FakeRepo();
      final useCase = SaveCountryCurrencyUseCase(repo);

      await useCase('ae', 'AED');
      await useCase('kw', 'KWD');

      final saved = await repo.getSettings();
      expect(saved.country, 'kw');
      expect(saved.currency, 'KWD');
    });
  });
}
