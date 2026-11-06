import 'dart:io';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/session/app_session.dart';
import 'package:money_companion/core/startup/install_presentation_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late File marker;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('qirsh-install-ui-');
    marker = File('${root.path}/presentation.json');
  });
  tearDown(() async {
    AppSession.instance.configureInstallPresentation(null);
    await root.delete(recursive: true);
  });

  test('reinstall clears only presentation flags and requires the whole setup', () async {
    FlutterSecureStorage.setMockInitialValues({
      'onboarding_done': '1', 'welcome_manifesto_seen': '1',
      'onboarding_completed_accounts_v1': '["uid:previous"]',
      'onboarding_current_account_v1': 'uid:previous', 'coach_marks_seen': 'home',
      'app_theme_mode': 'dark', 'local_data_owner_uid': 'previous',
      'cloud_egress_state_v1': 'preserve-barrier',
      'mali_install_id': 'preserve-device-identity', 'database-key': 'preserve-key',
    });
    final store = InstallPresentationStore(marker);
    await store.prepare(hasExistingData: () async => false,
        resetPresentation: AppSession.instance.resetInstallPresentation);
    expect(store.requiresSetup, isTrue);
    const storage = FlutterSecureStorage();
    final values = await storage.readAll();
    expect(values['welcome_manifesto_seen'], isNull);
    expect(values['onboarding_done'], isNull);
    expect(values['onboarding_completed_accounts_v1'], isNull);
    expect(values['app_theme_mode'], isNull);
    expect(values['local_data_owner_uid'], 'previous');
    expect(values['cloud_egress_state_v1'], 'preserve-barrier');
    expect(values['mali_install_id'], 'preserve-device-identity');
    expect(values['database-key'], 'preserve-key');
  });

  test('ordinary update preserves existing welcome, login and setup', () async {
    var resets = 0;
    final store = InstallPresentationStore(marker);
    await store.prepare(hasExistingData: () async => true,
        resetPresentation: () async => resets++);
    expect(store.requiresSetup, isFalse);
    expect(resets, 0);
  });

  test('reopen during setup preserves progress; completion survives restart', () async {
    var resets = 0;
    await InstallPresentationStore(marker).prepare(hasExistingData: () async => false,
        resetPresentation: () async => resets++);
    final restart = InstallPresentationStore(marker);
    await restart.prepare(hasExistingData: () async => false,
        resetPresentation: () async => resets++);
    expect(resets, 1);
    expect(restart.requiresSetup, isTrue);
    await restart.completeSetup();
    final completed = InstallPresentationStore(marker);
    await completed.prepare(hasExistingData: () async => false,
        resetPresentation: () async => resets++);
    expect(completed.requiresSetup, isFalse);
    expect(resets, 1);
  });

  test('language choice survives reopening before the welcome is complete', () async {
    final store = InstallPresentationStore(marker);
    await store.prepare(hasExistingData: () async => false,
        resetPresentation: () async {});
    expect(store.languageChosen, isFalse);
    await store.chooseLanguage();
    final restarted = InstallPresentationStore(marker);
    await restarted.prepare(hasExistingData: () async => false,
        resetPresentation: () async => fail('the first-run reset already finished'));
    expect(restarted.languageChosen, isTrue);
    expect(restarted.requiresSetup, isTrue);
  });

  test('interrupted presentation reset retries before marking it complete', () async {
    final store = InstallPresentationStore(marker);
    await expectLater(store.prepare(hasExistingData: () async => false,
        resetPresentation: () async => throw StateError('locked')), throwsStateError);
    var resets = 0;
    final retry = InstallPresentationStore(marker);
    await retry.prepare(hasExistingData: () async => true,
        resetPresentation: () async => resets++);
    expect(resets, 1);
    expect(retry.requiresSetup, isTrue);
  });

  test('uncertain local data never resets flags or writes a marker', () async {
    await expectLater(InstallPresentationStore(marker).prepare(
        hasExistingData: () async => null,
        resetPresentation: () async => fail('must not reset')), throwsStateError);
    expect(await marker.exists(), isFalse);
  });
}
