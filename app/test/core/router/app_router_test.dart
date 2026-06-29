import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/router/app_router.dart';
import 'package:money_companion/core/session/app_session.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    await AppSession.instance.wipeAndReset();
  });

  test('fresh users enter the full onboarding flow', () async {
    await AppSession.instance.load();

    expect(onboardingEntryPathForSession(AppSession.instance), '/onboarding');
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
