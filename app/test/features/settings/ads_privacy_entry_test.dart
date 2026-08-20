import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/domain/entities/engagement_entities.dart';
import 'package:money_companion/domain/entities/supporting_entities.dart';
import 'package:money_companion/features/report_ads/ad_consent_service.dart';
import 'package:money_companion/features/report_ads/report_ads_providers.dart';
import 'package:money_companion/features/settings/settings_providers.dart';
import 'package:money_companion/features/settings/settings_screen.dart';

/// UMP consent fake that records privacy-options invocations (E/F/G).
class _FakeConsent implements AdConsentService {
  _FakeConsent({required this.privacyRequired});
  final bool privacyRequired;
  int showPrivacyCalls = 0;

  @override
  Future<void> gatherConsent() async {}
  @override
  Future<bool> canRequestAds() async => false;
  @override
  Future<bool> isPrivacyOptionsRequired() async => privacyRequired;
  @override
  Future<void> showPrivacyOptions() async {
    showPrivacyCalls++;
  }
}

const _adsPrivacyTitle = 'خيارات خصوصية الإعلانات';

const _settings = UserSettingsEntity(
  id: 'settings',
  displayName: 'يوسف',
  country: 'EG',
  currency: 'EGP',
  language: 'ar',
  theme: 'light',
  inputMethod: 'manual',
  notificationsJson: '{}',
  dbEncryptionKeyRef: 'test',
  privacyModeEnabled: false,
);

Future<void> _pumpSettings(WidgetTester tester, _FakeConsent consent) async {
  // Tall viewport so the whole single-scroll settings list builds.
  tester.view.physicalSize = const Size(390, 4200);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        // The provider-under-test path: real adPrivacyOptionsRequiredProvider
        // resolving through an overridden UMP consent service.
        adConsentServiceProvider.overrideWithValue(consent),
        userSettingsProvider.overrideWith((ref) async => _settings),
        notificationPreferencesProvider.overrideWith(
          (ref) async => const NotificationPreferences(),
        ),
        captureHealthStatusProvider.overrideWith(
          (ref) async => CaptureHealthStatus(
            lastCaptureAt: null,
            now: DateTime.utc(2026, 8, 20),
          ),
        ),
        supportedCountriesProvider.overrideWith((ref) async => const []),
        activeCurrenciesProvider.overrideWith((ref) async => const []),
      ],
      child: MaterialApp(
        theme: AppTheme.light,
        home: const Directionality(
          textDirection: TextDirection.rtl,
          child: SettingsScreen(),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  // E — UMP reports REQUIRED → Settings shows the Ads Privacy entry.
  testWidgets('E: privacy-options required → entry visible', (tester) async {
    await _pumpSettings(tester, _FakeConsent(privacyRequired: true));
    expect(find.text(_adsPrivacyTitle), findsOneWidget);
  });

  // F — UMP reports NOT required → the entry stays hidden.
  testWidgets('F: privacy-options not required → entry hidden', (tester) async {
    await _pumpSettings(tester, _FakeConsent(privacyRequired: false));
    expect(find.text(_adsPrivacyTitle), findsNothing);
  });

  // G — tapping the entry invokes the UMP privacy-options form.
  testWidgets('G: tapping the entry invokes UMP', (tester) async {
    final consent = _FakeConsent(privacyRequired: true);
    await _pumpSettings(tester, consent);

    await tester.ensureVisible(find.text(_adsPrivacyTitle));
    await tester.tap(find.text(_adsPrivacyTitle));
    await tester.pump();

    expect(consent.showPrivacyCalls, 1);
  });
}
