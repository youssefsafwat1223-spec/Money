import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/di/account_access_mode.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/session/account_scope.dart';
import 'package:money_companion/core/i18n/locale_provider.dart';
import 'package:money_companion/core/security/lock_prompt_language.dart';
import 'package:money_companion/domain/entities/supporting_entities.dart';
import 'package:money_companion/domain/repositories/user_settings_repository.dart';
import 'package:money_companion/domain/usecases/user_settings_usecases.dart';
import 'package:money_companion/features/onboarding/widgets/onboarding_language_button.dart';
import 'package:money_companion/features/settings/settings_providers.dart';
import 'package:money_companion/l10n/app_localizations.dart';
import 'package:money_companion/l10n/app_localizations_en.dart';

class _Settings implements UserSettingsRepository {
  UserSettingsEntity value = const UserSettingsEntity(
    id: 'settings',
    country: 'EG',
    currency: 'EGP',
    language: 'en',
    theme: 'system',
    inputMethod: 'manual',
    notificationsJson: '{}',
    privacyModeEnabled: false,
  );
  @override
  Future<UserSettingsEntity> getSettings() async => value;
  @override
  Future<UserSettingsEntity> saveSettings(UserSettingsEntity settings) async =>
      value = settings;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  testWidgets(
      'onboarding changes persisted language and lock prompt before sign-in',
      (tester) async {
    final settings = _Settings();
    await tester.pumpWidget(ProviderScope(
      overrides: [
        userSettingsProvider.overrideWith((ref) => settings.getSettings()),
        saveLanguageUseCaseProvider
            .overrideWithValue(SaveLanguageUseCase(settings)),
      ],
      child: Consumer(
          builder: (context, ref, _) => MaterialApp(
                locale: ref.watch(localeProvider),
                supportedLocales: AppL10n.supportedLocales,
                localizationsDelegates: AppL10n.localizationsDelegates,
                home: const Scaffold(
                    backgroundColor: Colors.blue,
                    body: OnboardingLanguageButton()),
              )),
    ));
    await tester.pumpAndSettle();
    expect(find.text('English'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('onboarding-language')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('العربية'));
    await tester.pumpAndSettle();
    expect(settings.value.language, 'ar');
    expect(await LockPromptLanguage.read(), 'ar');
    expect(find.text('العربية'), findsOneWidget);
    final context = tester.element(find.byType(OnboardingLanguageButton));
    expect(Directionality.of(context), TextDirection.rtl);
    await tester.tap(find.byKey(const ValueKey('onboarding-language')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('English'));
    await tester.pumpAndSettle();
    expect(settings.value.language, 'en');
    expect(await LockPromptLanguage.read(), 'en');
  });

  testWidgets(
      'signed out read-only scope: the choice still applies and is mirrored',
      (tester) async {
    final settings = _Settings();
    await tester.pumpWidget(ProviderScope(
      overrides: [
        // No settings writer exists under a local-read scope.
        accountAccessModeProvider
            .overrideWithValue(AccountAccessMode.localRead),
        userSettingsProvider.overrideWith((ref) => settings.getSettings()),
      ],
      child: Consumer(
          builder: (context, ref, _) => MaterialApp(
                locale: ref.watch(localeProvider),
                supportedLocales: AppL10n.supportedLocales,
                localizationsDelegates: AppL10n.localizationsDelegates,
                home: const Scaffold(
                    backgroundColor: Colors.blue,
                    body: OnboardingLanguageButton()),
              )),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('onboarding-language')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('العربية'));
    await tester.pumpAndSettle();

    expect(settings.value.language, 'en', reason: 'nothing was written');
    expect(await LockPromptLanguage.read(), 'ar');
    final context = tester.element(find.byType(OnboardingLanguageButton));
    expect(Directionality.of(context), TextDirection.rtl);
    expect(find.text(AppL10nEn().setupSaveFailed), findsNothing);
  });
}
