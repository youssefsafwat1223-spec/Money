import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/domain/entities/supporting_entities.dart';
import 'package:money_companion/domain/repositories/user_settings_repository.dart';
import 'package:money_companion/domain/usecases/user_settings_usecases.dart';
import 'package:money_companion/features/capture/services/capture_device_registration_service.dart';
import 'package:money_companion/features/settings/settings_providers.dart';
import 'package:money_companion/l10n/app_localizations.dart';

class FakeSettingsRepository implements UserSettingsRepository {
  UserSettingsEntity settings = const UserSettingsEntity(
    id: 's',
    country: 'SA',
    currency: 'SAR',
    language: 'en',
    theme: 'light',
    inputMethod: 'manual',
    notificationsJson: '{}',
    privacyModeEnabled: false,
  );
  int saveCalls = 0;
  bool failSave = false;

  @override
  Future<UserSettingsEntity> getSettings() async => settings;

  @override
  Future<UserSettingsEntity> saveSettings(UserSettingsEntity value) async {
    if (failSave) throw StateError('disk');
    saveCalls++;
    return settings = value;
  }
}

/// Registration service double: [retry] moves status to [outcome].
class FakeRegistrationService implements CaptureDeviceRegistrationService {
  FakeRegistrationService(
      {this.outcome = const CaptureRegistrationStatus(
          CaptureRegistrationPhase.connected)});

  CaptureRegistrationStatus outcome;
  int retryCalls = 0;
  final notifier = ValueNotifier(const CaptureRegistrationStatus(
      CaptureRegistrationPhase.notRequested));

  @override
  ValueListenable<CaptureRegistrationStatus> get status => notifier;

  @override
  Future<void> retry() async {
    retryCalls++;
    notifier.value = outcome;
  }

  @override
  Future<void> syncBackendState() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeSaveCountry implements SaveCountryCurrencyUseCase {
  @override
  Future<UserSettingsEntity> call(String country, String currency) async =>
      throw UnimplementedError();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

List<Override> consentOverrides(
  FakeSettingsRepository repo,
  FakeRegistrationService service,
) =>
    [
      userSettingsRepositoryProvider.overrideWithValue(repo),
      userSettingsProvider.overrideWith((_) => repo.getSettings()),
      captureDeviceRegistrationServiceProvider.overrideWithValue(service),
    ];

Widget consentApp({
  required List<Override> overrides,
  required Widget home,
  String locale = 'en',
}) =>
    ProviderScope(
      overrides: overrides,
      child: MaterialApp(
        theme: AppTheme.light,
        locale: Locale(locale),
        supportedLocales: AppL10n.supportedLocales,
        localizationsDelegates: const [
          ...AppL10n.localizationsDelegates,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: home,
      ),
    );
