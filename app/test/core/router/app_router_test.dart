import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/router/app_router.dart';
import 'package:money_companion/core/session/app_session.dart';

void main() {
  FlutterSecureStorage.setMockInitialValues({});
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    await AppSession.instance.wipeAndReset();
  });

  // The first-launch welcome/story gating now lives in the router redirect
  // (fresh users are forced to /welcome). onboardingEntryPathForSession is only
  // consulted after that gate, so it always resolves to mandatory auth.
  test('entry path resolves to auth once past the welcome gate', () async {
    await AppSession.instance.load();
    await AppSession.instance.markWelcomeManifestoSeen();

    expect(
      onboardingEntryPathForSession(AppSession.instance),
      '/onboarding/auth',
    );
  });

  test('signed-out returning users go straight to auth', () async {
    await AppSession.instance.completeOnboarding(
      method: 'email',
      email: 'user@example.com',
      userId: 'returning-router-fixture',
    );
    expect(AppSession.instance.status, SessionStatus.authenticated);
    await AppSession.instance.signOut();

    expect(
      onboardingEntryPathForSession(AppSession.instance),
      '/onboarding/auth',
    );
  });

  // O-H2 — while a verified local-read scope is published only the read-only shell
  // and the reconnect (sign-in) route are reachable; every action, editing and
  // account-control route, however it is reached, is redirected back to the shell.
  group('local-read route allowlist', () {
    test('the shell and reconnect are allowed, with or without a query', () {
      expect(localReadRedirect('/'), isNull);
      expect(localReadRedirect('/?from=notification'), isNull);
      expect(localReadRedirect('/onboarding/auth'), isNull);
    });

    test('every other route is redirected to the shell', () {
      const denied = [
        '/transaction/tx-1',
        '/transaction/tx-1?edit=1',
        '/paste',
        '/budgets',
        '/budgets/new',
        '/budgets/b1/edit',
        '/goals',
        '/goals/new',
        '/goals/g1',
        '/accounts',
        '/account/a1',
        '/cards',
        '/card/1234',
        '/subscriptions',
        '/reports',
        '/settings',
        '/profile',
        '/settings/planning-currency-repair',
        '/data-transfer',
        '/backup',
        '/backup/restore',
        '/capture/sms-permission',
        '/coupons',
        '/coupons/merchant/m1',
        '/savings',
        '/referrals',
        '/privacy',
        '/help',
        '/announcements',
        '/achievements',
        '/welcome',
        '/onboarding/setup',
        '/onboarding/brand',
        '/onboarding/privacy',
        '/design',
        '/unknown/deep/link',
      ];
      for (final location in denied) {
        expect(localReadRedirect(location), '/', reason: location);
      }
    });

    test('look-alike paths do not slip through the prefix', () {
      expect(localReadRedirect('//onboarding/auth'), '/');
      expect(localReadRedirect('/onboarding/auth/../setup'), '/');
      expect(localReadRedirect('/onboarding/authx'), '/');
    });
  });
}
