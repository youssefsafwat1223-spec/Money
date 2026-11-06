import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:money_companion/core/session/admission_authority.dart';
import 'package:money_companion/core/session/app_session.dart';
import 'package:money_companion/core/startup/install_presentation_store.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'f2_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late F2Fixture f;
  late InstallPresentationStore presentation;
  late SupabaseClient sdk;
  late Future<http.Response> Function(http.Request) respond;
  late List<http.Request> profileRequests;

  setUp(() async {
    f = await F2Fixture.create();
    profileRequests = [];
    respond = (request) async => http.Response(
          jsonEncode([
            {'onboarding_completed_at': '2026-10-01T00:00:00Z'}
          ]),
          200,
          headers: {'content-type': 'application/json'},
        );
    sdk = SupabaseClient(
      'https://example.supabase.co',
      'synthetic-anon',
      authOptions: const AuthClientOptions(autoRefreshToken: false),
      httpClient: MockClient((request) async {
        if (request.url.path.endsWith('/profiles')) {
          profileRequests.add(request);
          final reply = await respond(request);
          return http.Response(reply.body, reply.statusCode,
              headers: reply.headers, request: request);
        }
        return http.Response('{}', 200);
      }),
    );
    await F2Fixture.recoverSession_(sdk, 'returning-owner');
    presentation = InstallPresentationStore(
      File('${f.support.path}/install-presentation.json'),
    );
    await presentation.prepare(
        hasExistingData: () async => false,
        resetPresentation: f.session.resetInstallPresentation);
    f.session.configureInstallPresentation(presentation);
    await f.session.markOnboardingLanguageChosen();
    await f.session.markWelcomeManifestoSeen();
    await f.session.setIdentity(
      method: 'apple',
      userId: 'returning-owner',
      email: 'returning-owner@example.com',
      sessionCurrent: () => sdk.auth.currentSession?.isExpired == false,
    );
  });

  tearDown(() async {
    f.session.configureInstallPresentation(null);
    await sdk.dispose();
    await f.dispose();
  });

  Future<bool> verify() =>
      f.session.reconcileAccountOnboarding(sdk, requireRemoteResult: true);

  test('verified returning account skips setup after reinstall and reopening',
      () async {
    expect(presentation.requiresSetup, isTrue);
    expect(f.session.hasCompletedOnboarding, isFalse);

    expect(await verify(), isTrue);
    expect(profileRequests, hasLength(1));
    expect(
        profileRequests.single.url.queryParameters['id'], 'eq.returning-owner');
    expect(profileRequests.single.url.queryParameters['select'],
        'onboarding_completed_at');
    expect(presentation.requiresSetup, isFalse);
    expect(presentation.languageChosen, isTrue);
    expect(f.session.hasSeenWelcomeManifesto, isTrue);
    await f.session.load();
    expect(f.session.status, SessionStatus.authenticated);
    expect(await verify(), isTrue);
    expect(profileRequests, hasLength(1),
        reason: 'verified completion is cached for ordinary reopening');
  });

  test('confirmed incomplete account still receives setup', () async {
    respond = (_) async => http.Response(
          '[{"onboarding_completed_at":null}]',
          200,
          headers: {'content-type': 'application/json'},
        );

    expect(await verify(), isFalse);
    expect(presentation.requiresSetup, isTrue);
    expect(f.session.hasCompletedOnboarding, isFalse);
  });

  test('unavailable lookup retries without converting failure to incomplete',
      () async {
    respond =
        (_) async => http.Response('{"message":"private-server-detail"}', 503);

    await expectLater(verify(), throwsA(isA<OnboardingStatusUnavailable>()));
    expect(presentation.requiresSetup, isTrue);
    expect(f.session.hasCompletedOnboarding, isFalse);
    expect(sdk.auth.currentSession!.user.id, 'returning-owner');

    respond = (_) async => http.Response(
          '[{"onboarding_completed_at":"2026-10-01T00:00:00Z"}]',
          200,
          headers: {'content-type': 'application/json'},
        );
    expect(await verify(), isTrue);
  });

  test('sign-out during lookup cannot complete the old installation state',
      () async {
    final arrived = Completer<void>();
    final release = Completer<void>();
    respond = (_) async {
      arrived.complete();
      await release.future;
      return http.Response(
        '[{"onboarding_completed_at":"2026-10-01T00:00:00Z"}]',
        200,
        headers: {'content-type': 'application/json'},
      );
    };
    final result =
        expectLater(verify(), throwsA(isA<StaleAdmissionException>()));
    await arrived.future;
    await f.session.signOut();
    release.complete();
    await result;
    expect(presentation.requiresSetup, isTrue);
    expect(f.session.hasCompletedOnboarding, isFalse);
  });

  test('a server that never answers has a bounded verification wait', () async {
    final stalled = Completer<http.Response>();
    respond = (_) => stalled.future;
    try {
      await expectLater(verify(), throwsA(isA<OnboardingStatusUnavailable>()));
      expect(presentation.requiresSetup, isTrue);
    } finally {
      stalled.complete(http.Response('[]', 200,
          headers: {'content-type': 'application/json'}));
    }
  });
}
