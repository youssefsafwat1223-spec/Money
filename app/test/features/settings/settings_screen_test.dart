import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/domain/entities/engagement_entities.dart';
import 'package:money_companion/domain/entities/supporting_entities.dart';
import 'package:money_companion/features/settings/settings_providers.dart';
import 'package:money_companion/features/settings/settings_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
  });

  testWidgets('settings shows all groups in one scroll (no tabs)',
      (tester) async {
    // Tall viewport so the whole single-scroll list builds (no tabs to reveal
    // lower groups any more).
    tester.view.physicalSize = const Size(390, 4200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    const settings = UserSettingsEntity(
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

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          userSettingsProvider.overrideWith((ref) async => settings),
          notificationPreferencesProvider.overrideWith(
            (ref) async => const NotificationPreferences(),
          ),
          captureHealthStatusProvider.overrideWith(
            (ref) async => CaptureHealthStatus(
              lastCaptureAt: null,
              now: DateTime.utc(2026, 7, 18),
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

    // No back button on the root tab, and no tab switcher any more.
    expect(find.byTooltip('رجوع'), findsNothing);
    expect(
      find.byKey(const ValueKey('settings-tab-notifications')),
      findsNothing,
    );

    // Every group renders together in one scroll (general + notifications +
    // data), instead of being hidden behind tabs.
    for (final label in const [
      'إدارة أموالك',
      'تأكيد عملة الميزانيات والأهداف',
      'رصد العمليات',
      'تنبيهاتك',
      'نقل البيانات',
    ]) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('pushed settings route pops without removing the root page',
      (tester) async {
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (context, state) => Scaffold(
            body: TextButton(
              onPressed: () => context.push('/settings'),
              child: const Text('open settings'),
            ),
          ),
        ),
        GoRoute(
          path: '/settings',
          builder: (context, state) => SettingsScreen(
            showBackButton: context.canPop(),
          ),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          userSettingsProvider.overrideWith((ref) async => _settings),
          notificationPreferencesProvider.overrideWith(
            (ref) async => const NotificationPreferences(),
          ),
          captureHealthStatusProvider.overrideWith(
            (ref) async => CaptureHealthStatus(
              lastCaptureAt: null,
              now: DateTime.utc(2026, 7, 18),
            ),
          ),
          supportedCountriesProvider.overrideWith((ref) async => const []),
          activeCurrenciesProvider.overrideWith((ref) async => const []),
        ],
        child: MaterialApp.router(
          theme: AppTheme.light,
          routerConfig: router,
        ),
      ),
    );

    await tester.tap(find.text('open settings'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('رجوع'), findsOneWidget);

    await tester.tap(find.byTooltip('رجوع'));
    await tester.pumpAndSettle();

    expect(find.text('open settings'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

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
