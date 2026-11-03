import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/test/test_flutter_secure_storage_platform.dart';
// ignore: depend_on_referenced_packages
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:money_companion/core/session/app_session.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/features/onboarding/brand_screen.dart';
import 'package:money_companion/l10n/app_localizations.dart';

// Actual storage API, failure before any durable mutation. No fake AppSession,
// auth identity, successful welcome marker, account or financial repository.
class _FailWelcomeWrite extends TestFlutterSecureStoragePlatform {
  _FailWelcomeWrite() : super({'qa_unrelated': 'retained'});
  final attempts = <Completer<void>>[];

  @override
  Future<void> write(
      {required String key,
      required String value,
      required Map<String, String> options}) async {
    if (key != 'welcome_manifesto_seen' || value != '1') {
      throw StateError('unexpected_storage_mutation');
    }
    final gate = Completer<void>();
    attempts.add(gate);
    await gate.future;
    throw PlatformException(
        code: 'storage_unavailable',
        message: 'private_transport_failure_do_not_surface');
  }

  void release() {
    for (final gate in attempts) {
      if (!gate.isCompleted) gate.complete();
    }
  }
}

void main() {
  for (final language in ['ar', 'en']) {
    for (final dark in [false, true]) {
      testWidgets(
          'real Brand welcome write failure permits Retry $language dark=$dark',
          (tester) async {
        tester.view.physicalSize = const Size(375, 667);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final originalStorage = FlutterSecureStoragePlatform.instance;
        final storage = _FailWelcomeWrite();
        FlutterSecureStoragePlatform.instance = storage;
        await AppSession.instance.load();
        final sessionStatus = AppSession.instance.value;
        final before = await storage.readAll(options: {});
        expect(AppSession.instance.hasSeenWelcomeManifesto, isFalse);
        final router = GoRouter(routes: [
          GoRoute(path: '/', builder: (_, __) => const OnboardingBrandScreen()),
          // Destination must not be visited by any failed write; no fabricated
          // auth widget/result is provided to make the test succeed.
        ]);
        addTearDown(() async {
          storage.release();
          await tester.pump(const Duration(seconds: 4));
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump();
          router.dispose();
          FlutterSecureStoragePlatform.instance = originalStorage;
        });
        final font = FontLoader('Vazirmatn');
        for (final weight in ['Regular', 'Medium', 'SemiBold', 'Bold']) {
          font.addFont(rootBundle.load('assets/fonts/Vazirmatn-$weight.ttf'));
        }
        await font.load();
        await tester.pumpWidget(ProviderScope(
            child: MaterialApp.router(
          routerConfig: router,
          theme: dark ? AppTheme.dark : AppTheme.light,
          locale: Locale(language),
          supportedLocales: AppL10n.supportedLocales,
          localizationsDelegates: AppL10n.localizationsDelegates,
          builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(disableAnimations: true),
              child: child!),
        )));
        await tester.pumpAndSettle();
        final l10n =
            AppL10n.of(tester.element(find.byType(OnboardingBrandScreen)));
        final continueButton = find.byType(FilledButton);
        expect(continueButton.hitTestable(), findsOneWidget);
        await tester.tap(continueButton);
        await tester.pump();
        expect(storage.attempts, hasLength(1));
        final busyDisabled =
            tester.widget<FilledButton>(continueButton).onPressed == null;
        await tester.tap(continueButton, warnIfMissed: false);
        await tester.pump();
        expect(storage.attempts, hasLength(1),
            reason: 'No duplicate write while busy');
        storage.release();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 450));
        final escaped = tester.takeException();
        final retryEnabled =
            tester.widget<FilledButton>(continueButton).onPressed != null;
        final honestError =
            find.text(l10n.setupSaveFailed).evaluate().isNotEmpty;
        expect(find.textContaining('private_transport_failure'), findsNothing);
        expect(AppSession.instance.hasSeenWelcomeManifesto, isFalse);
        expect(await storage.readAll(options: {}), before);
        expect(AppSession.instance.value, sessionStatus);
        expect(router.routeInformationProvider.value.uri.path, '/');
        await tester.tap(continueButton);
        await tester.pump();
        final actualRetries = storage.attempts.length;
        storage.release();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 450));
        final retryEscaped = tester.takeException();
        expect(await storage.readAll(options: {}), before);
        expect(AppSession.instance.hasSeenWelcomeManifesto, isFalse);
        expect(AppSession.instance.value, sessionStatus);
        expect(router.routeInformationProvider.value.uri.path, '/');
        await tester.pump(const Duration(seconds: 4));
        expect(escaped, isNull,
            reason: 'Real preference failure must be handled');
        expect(retryEscaped, isNull);
        expect(busyDisabled, isTrue);
        expect(retryEnabled, isTrue);
        expect(honestError, isTrue);
        expect(actualRetries, 2,
            reason: 'Retry must reach the actual storage write again');
        expect(
            tester.widget<FilledButton>(continueButton).onPressed, isNotNull);
      });
    }
  }
}
