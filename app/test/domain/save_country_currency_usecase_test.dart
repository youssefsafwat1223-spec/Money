import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/domain/entities/account_entity.dart';
import 'package:money_companion/domain/entities/supporting_entities.dart';
import 'package:money_companion/domain/entities/transaction_entity.dart';
import 'package:money_companion/domain/repositories/account_repository.dart';
import 'package:money_companion/domain/repositories/transaction_repository.dart';
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

AccountEntity _account(String currency) => AccountEntity(
      id: 'acc-1',
      name: 'الحساب الرئيسي',
      currency: currency,
      type: AccountType.bank,
      isDefault: true,
      sortOrder: 0,
      createdAt: DateTime.utc(2026, 1, 1),
      updatedAt: DateTime.utc(2026, 1, 1),
    );

class _FakeAccountRepo implements AccountRepository {
  _FakeAccountRepo(this._default);
  AccountEntity? _default;
  AccountEntity? lastCreated;
  AccountEntity? lastUpdated;

  @override
  Future<AccountEntity?> getDefault() async => _default;

  @override
  Future<AccountEntity> create(AccountEntity account) async {
    lastCreated = account.copyWith(id: 'created-account');
    _default = lastCreated;
    return lastCreated!;
  }

  @override
  Future<AccountEntity> update(AccountEntity account) async {
    lastUpdated = account;
    _default = account;
    return account;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeTxnRepo implements TransactionRepository {
  _FakeTxnRepo(this._recent);
  final List<TransactionEntity> _recent;

  @override
  Future<List<TransactionEntity>> getRecent(
          {int limit = 5, String? accountId}) async =>
      _recent;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  group('SaveCountryCurrencyUseCase', () {
    test('persists country and currency, leaves other fields unchanged',
        () async {
      final repo = _FakeRepo();
      final useCase = SaveCountryCurrencyUseCase(
        repo,
        _FakeAccountRepo(_account('SAR')),
        _FakeTxnRepo(const []),
      );

      await useCase('eg', 'EGP');

      final saved = await repo.getSettings();
      expect(saved.country, 'eg');
      expect(saved.currency, 'EGP');
      expect(saved.language, _defaults.language);
      expect(saved.theme, _defaults.theme);
    });

    test('overwrites a previous selection', () async {
      final repo = _FakeRepo();
      final useCase = SaveCountryCurrencyUseCase(
        repo,
        _FakeAccountRepo(_account('SAR')),
        _FakeTxnRepo(const []),
      );

      await useCase('ae', 'AED');
      await useCase('kw', 'KWD');

      final saved = await repo.getSettings();
      expect(saved.country, 'kw');
      expect(saved.currency, 'KWD');
    });

    test('aligns the default account currency on a fresh setup (no txns)',
        () async {
      final accountRepo = _FakeAccountRepo(_account('SAR'));
      final useCase = SaveCountryCurrencyUseCase(
        _FakeRepo(),
        accountRepo,
        _FakeTxnRepo(const []),
      );

      await useCase('eg', 'EGP');

      expect(accountRepo.lastUpdated, isNotNull);
      expect(accountRepo.lastUpdated!.currency, 'EGP');
    });

    test('creates the first account for a new Supabase-primary user', () async {
      final accountRepo = _FakeAccountRepo(null);
      final settingsRepo = _FakeRepo();
      final useCase = SaveCountryCurrencyUseCase(
        settingsRepo,
        accountRepo,
        _FakeTxnRepo(const []),
      );

      await useCase('eg', 'EGP');

      expect(accountRepo.lastCreated, isNotNull);
      expect(accountRepo.lastCreated!.currency, 'EGP');
      expect(accountRepo.lastCreated!.isDefault, isTrue);
      expect((await settingsRepo.getSettings()).currency, 'EGP');
    });

    test('does NOT touch the account currency once transactions exist',
        () async {
      final accountRepo = _FakeAccountRepo(_account('SAR'));
      final useCase = SaveCountryCurrencyUseCase(
        _FakeRepo(),
        accountRepo,
        _FakeTxnRepo([
          TransactionEntity(
            id: 't1',
            amount: 10,
            currency: 'SAR',
            type: TransactionTypeEntity.payment,
            source: TransactionSourceEntity.bank,
            occurredAt: DateTime.utc(2026, 1, 2),
            rawMessage: 'x',
            parseConfidence: 1.0,
            status: TransactionStatus.confirmed,
            createdAt: DateTime.utc(2026, 1, 2),
            updatedAt: DateTime.utc(2026, 1, 2),
          ),
        ]),
      );

      await useCase('eg', 'EGP');

      expect(accountRepo.lastUpdated, isNull);
    });
  });

  group('SaveDateOfBirthUseCase', () {
    test('persists date of birth and leaves existing settings unchanged',
        () async {
      final repo = _FakeRepo();
      final useCase = SaveDateOfBirthUseCase(repo);
      final dateOfBirth = DateTime.utc(1998, 4, 12);

      await useCase(dateOfBirth);

      final saved = await repo.getSettings();
      expect(saved.dateOfBirth, dateOfBirth);
      expect(saved.country, _defaults.country);
      expect(saved.currency, _defaults.currency);
      expect(saved.language, _defaults.language);
    });
  });
}
