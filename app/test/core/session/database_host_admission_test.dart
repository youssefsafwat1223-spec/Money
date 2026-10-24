import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/session/admission_authority.dart';
import 'package:money_companion/core/session/app_session.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'f2_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late F2Fixture fixture;
  late SupabaseClient sdk;
  var firstBinding = true;

  Future<void> publish() async {
    final actual = sdk.auth.currentSession!;
    await fixture.session.setIdentity(
      method: 'apple',
      email: actual.user.email,
      userId: actual.user.id,
      sessionCurrent: () =>
          sdk.auth.currentSession?.accessToken == actual.accessToken &&
          sdk.auth.currentSession?.isExpired == false,
    );
    await fixture.session.finishOnboarding(client: sdk);
    if (firstBinding) {
      final settled = Completer<void>();
      fixture.session.debugAuthEventCompleted = (event) {
        if (event == AuthChangeEvent.tokenRefreshed && !settled.isCompleted) {
          settled.complete();
        }
      };
      await fixture.session.bindSupabaseAuth(sdk);
      await settled.future;
      fixture.session.debugAuthEventCompleted = null;
      firstBinding = false;
    } else {
      await fixture.session.bindSupabaseAuth(sdk);
    }
    expect(fixture.flow.isRunning, isFalse);
    expect(fixture.host.current!.database.admitsSecondary, isTrue);
    expect(fixture.session.hasCompletedOnboarding, isTrue);
  }

  setUp(() async {
    fixture = await F2Fixture.create();
    fixture.session.configureAccountScope(fixture.host);
    sdk = await fixture.clientFor('host-admission-owner');
    await publish();
    // Do not capture a broker receipt here: loss must invalidate the genuine
    // publication lifetime even when no authority object has yet been requested.
  });

  tearDown(() async {
    fixture.session.debugAuthEventCompleted = null;
    await fixture.dispose();
    await sdk.dispose();
  });

  test(
      'known loss during held explicit identity publication denies first capture',
      () async {
    final hold = fixture.storage.holdOnce(
        (op, key) => op == 'write' && key == 'onboarding_current_account_v1');
    final actual = sdk.auth.currentSession!;
    final publishing = fixture.session.setIdentity(
      method: 'apple',
      email: actual.user.email,
      userId: actual.user.id,
      sessionCurrent: () =>
          sdk.auth.currentSession?.accessToken == actual.accessToken,
    );
    final settled = publishing.then<void>((_) {}, onError: (Object error) {
      expect(error, isA<StaleAdmissionException>());
    });
    await hold.reached.future;
    fixture.session.markSessionInvalid();
    hold.release.complete();
    await settled;
    expect(sdk.auth.currentSession!.isExpired, isFalse);
    expect(fixture.session.captureDatabaseHostAdmission(), isNull);
    await publish();
    expect(fixture.session.captureDatabaseHostAdmission(), isNotNull);
  });

  test('known loss during held automatic publication denies first capture',
      () async {
    final hold = fixture.storage.holdOnce(
        (op, key) => op == 'write' && key == 'onboarding_current_account_v1');
    final publishing = fixture.session.reconcileAccountOnboarding(sdk);
    await hold.reached.future;
    fixture.session.markSessionInvalid();
    hold.release.complete();
    await publishing;
    expect(fixture.session.captureDatabaseHostAdmission(), isNull);
    await publish();
    expect(fixture.session.captureDatabaseHostAdmission(), isNotNull);
  });

  test('publication listener loss before first capture remains restrictive',
      () async {
    var lost = false;
    void listener() {
      if (!lost && fixture.session.status == SessionStatus.authenticated) {
        lost = true;
        fixture.session.markSessionInvalid();
      }
    }

    fixture.session.addListener(listener);
    try {
      await fixture.session.setIdentity(
          method: 'apple',
          email: sdk.auth.currentSession!.user.email,
          userId: sdk.auth.currentSession!.user.id,
          sessionCurrent: () => sdk.auth.currentSession?.isExpired == false);
    } finally {
      fixture.session.removeListener(listener);
    }
    expect(lost, isTrue);
    expect(fixture.session.captureDatabaseHostAdmission(), isNull);
    await publish();
    expect(fixture.session.captureDatabaseHostAdmission(), isNotNull);
  });

  test('failed identity commit cannot authorize first capture', () async {
    fixture.storage.gate = (op, key) async {
      if (op == 'write' && key == 'auth_method') {
        throw StateError('commit refused');
      }
    };
    await expectLater(
        fixture.session.setIdentity(
            method: 'apple',
            email: sdk.auth.currentSession!.user.email,
            userId: sdk.auth.currentSession!.user.id,
            sessionCurrent: () => sdk.auth.currentSession?.isExpired == false),
        throwsStateError);
    expect(fixture.session.captureDatabaseHostAdmission(), isNull);
    fixture.storage.gate = null;
    await publish();
    expect(fixture.session.captureDatabaseHostAdmission(), isNotNull);
  });

  test(
      'failed same owner identity cannot gain issuer through finish onboarding',
      () async {
    fixture.storage.gate = (op, key) async {
      if (op == 'write' && key == 'auth_method') {
        throw StateError('identity commit refused');
      }
    };
    await expectLater(
        fixture.session.setIdentity(
            method: 'apple',
            email: sdk.auth.currentSession!.user.email,
            userId: sdk.auth.currentSession!.user.id,
            sessionCurrent: () => sdk.auth.currentSession?.isExpired == false),
        throwsStateError);
    fixture.storage.gate = null;
    await fixture.session.finishOnboarding(client: sdk);
    expect(fixture.session.captureDatabaseHostAdmission(), isNull);
    await publish();
    expect(fixture.session.captureDatabaseHostAdmission(), isNotNull);
  });

  test(
      'incomplete onboarding observed SDK loss cannot finish into issuer without new admission',
      () async {
    final previousSdk = sdk;
    sdk = await fixture.clientFor('incomplete-onboarding-owner');
    final actual = sdk.auth.currentSession!;
    await fixture.session.setIdentity(
        method: 'apple',
        email: actual.user.email,
        userId: actual.user.id,
        sessionCurrent: () =>
            sdk.auth.currentSession?.accessToken == actual.accessToken);
    await fixture.session.bindSupabaseAuth(sdk);
    expect(fixture.session.hasCompletedOnboarding, isFalse);
    expect(fixture.session.captureDatabaseHostAdmission(), isNull);
    await sdk.auth.signOut(scope: SignOutScope.local);
    await fixture.session.reconcileAccountOnboarding(sdk);
    await fixture.recoverSession(sdk, actual.user.id);
    await fixture.session.finishOnboarding(client: sdk);
    expect(fixture.session.captureDatabaseHostAdmission(), isNull);
    await previousSdk.dispose();
    await publish();
    expect(fixture.session.captureDatabaseHostAdmission(), isNotNull);
  });

  test('genuine cold automatic admission publishes current host issuer',
      () async {
    final owner = sdk.auth.currentSession!.user.id;
    // Genuine preserved storage/scope restart, then SDK restore/reconcile.
    // No private status, owner or epoch fields are manufactured.
    await fixture.restart();
    fixture.session.configureAccountScope(fixture.host);
    await fixture.session.bindSupabaseAuth(sdk);
    expect(fixture.session.hasCompletedOnboarding, isTrue);
    expect(fixture.host.current!.uid == owner, isTrue);
    expect(fixture.host.current!.database.admitsSecondary, isTrue);
    expect(fixture.flow.isRunning, isFalse);
    expect(fixture.session.captureDatabaseHostAdmission(), isNotNull);
  });

  test('genuine different owner publication issues a fresh exact receipt',
      () async {
    final old = fixture.session.captureDatabaseHostAdmission()!;
    final previousSdk = sdk;
    sdk = await fixture.clientFor('host-admission-next-owner');
    await publish();
    await previousSdk.dispose();
    final fresh = fixture.session.captureDatabaseHostAdmission();
    expect(fresh, isNotNull);
    expect(fresh!.uid == sdk.auth.currentSession!.user.id, isTrue);
    expect(identical(fresh.database, fixture.host.current!.database), isTrue);
    expect(old.isCurrent, isFalse);
  });

  test('known loss during internal new-owner generation rotation still denies',
      () async {
    final previousSdk = sdk;
    sdk = await fixture.clientFor('host-admission-next-owner');
    final hold = fixture.storage.holdOnce(
        (op, key) => op == 'delete' && key == 'local_data_owner_generation');
    final actual = sdk.auth.currentSession!;
    final publishing = fixture.session.setIdentity(
        method: 'apple',
        email: actual.user.email,
        userId: actual.user.id,
        sessionCurrent: () =>
            sdk.auth.currentSession?.accessToken == actual.accessToken);
    await hold.reached.future;
    fixture.session.markSessionInvalid();
    hold.release.complete();
    await publishing;
    await fixture.session.bindSupabaseAuth(sdk);
    expect(fixture.session.captureDatabaseHostAdmission(), isNull);
    await previousSdk.dispose();
    await publish();
    expect(fixture.session.captureDatabaseHostAdmission(), isNotNull);
  });
}
