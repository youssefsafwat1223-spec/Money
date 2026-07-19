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

  testWidgets('settings groups general, notification, and data views',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
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

    expect(find.byTooltip('رجوع'), findsNothing);
    expect(find.text('إدارة أموالك'), findsOneWidget);
    expect(find.text('رصد العمليات'), findsNothing);

    await tester.tap(
      find.byKey(const ValueKey('settings-tab-notifications')),
    );
    await tester.pumpAndSettle();

    expect(find.text('رصد العمليات'), findsOneWidget);
    expect(find.text('تنبيهاتك'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('settings-tab-data')));
    await tester.pumpAndSettle();

    expect(find.text('نقل البيانات'), findsOneWidget);
    expect(find.text('الأمان والخصوصية'), findsOneWidget);
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
