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
    );
    await AppSession.instance.signOut();

    expect(
      onboardingEntryPathForSession(AppSession.instance),
      '/onboarding/auth',
    );
  });
}
