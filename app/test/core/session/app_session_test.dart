import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/session/app_session.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    await AppSession.instance.wipeAndReset();
  });

  test('fresh installs start at onboarding', () async {
    await AppSession.instance.load();

    expect(AppSession.instance.status, SessionStatus.needsOnboarding);
    expect(AppSession.instance.hasCompletedOnboarding, isFalse);
    expect(AppSession.instance.hasSeenWelcomeManifesto, isFalse);
    expect(AppSession.instance.authMethod, isNull);
  });

  test('sign out keeps completed onboarding for returning users', () async {
    await AppSession.instance.completeOnboarding(
      method: 'email',
      email: 'user@example.com',
    );

    expect(AppSession.instance.status, SessionStatus.authenticated);
    expect(AppSession.instance.hasCompletedOnboarding, isTrue);

    await AppSession.instance.signOut();

    expect(AppSession.instance.status, SessionStatus.needsOnboarding);
    expect(AppSession.instance.hasCompletedOnboarding, isTrue);
    expect(AppSession.instance.authMethod, isNull);
    expect(AppSession.instance.email, isNull);
  });

  test('returning users become authenticated after signing in again', () async {
    await AppSession.instance.completeOnboarding(
      method: 'email',
      email: 'user@example.com',
    );
    await AppSession.instance.signOut();

    await AppSession.instance.setIdentity(
      method: 'email',
      email: 'user@example.com',
    );

    expect(AppSession.instance.status, SessionStatus.authenticated);
    expect(AppSession.instance.hasCompletedOnboarding, isTrue);
    expect(AppSession.instance.authMethod, 'email');
    expect(AppSession.instance.email, 'user@example.com');
  });

  test('completed users without a local identity are sent back to auth only',
      () async {
    FlutterSecureStorage.setMockInitialValues({
      'onboarding_done': '1',
    });

    await AppSession.instance.load();

    expect(AppSession.instance.status, SessionStatus.needsOnboarding);
    expect(AppSession.instance.hasCompletedOnboarding, isTrue);
    expect(AppSession.instance.hasSeenWelcomeManifesto, isTrue);
    expect(AppSession.instance.authMethod, isNull);
  });

  test('wipe reset makes the first-launch welcome eligible again', () async {
    await AppSession.instance.markWelcomeManifestoSeen();

    expect(AppSession.instance.hasSeenWelcomeManifesto, isTrue);

    await AppSession.instance.wipeAndReset();

    expect(AppSession.instance.hasSeenWelcomeManifesto, isFalse);
    expect(AppSession.instance.status, SessionStatus.needsOnboarding);
  });
}
