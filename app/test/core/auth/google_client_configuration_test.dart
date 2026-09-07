import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:money_companion/core/auth/auth_service.dart';
import 'package:money_companion/core/auth/supabase_auth_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as supabase;

/// Android does not accept an iOS OAuth client, and `clientId` is not a
/// supported parameter there: `GoogleSignInPlugin.java:222-231` reinterprets it
/// as `serverClientId` with only a log warning. The build therefore called
/// `requestIdToken(<iOS client>)` — an audience Google will never mint a token
/// for — and the resulting null `idToken` surfaced as "لم نستطع قراءة رمز دخول
/// جوجل", blaming the token read for what was a configuration error.

/// Fails the test if the Google sheet is opened; the config guard must run first.
class _NeverCalledGoogleSignIn extends Fake implements GoogleSignIn {
  @override
  Future<GoogleSignInAccount?> signIn() async {
    fail('signIn() must not be reached on a misconfigured platform');
  }
}

supabase.SupabaseClient _client() =>
    supabase.SupabaseClient('https://example.supabase.co', 'anon-key');

void main() {
  group('canonical iOS client', () {
    test('is the client whose reversed form Info.plist registers', () {
      final plist = File('ios/Runner/Info.plist').readAsStringSync();
      final reversed =
          'com.googleusercontent.apps.${kGoogleIosClientId.split('.').first}';
      expect(plist.contains(reversed), isTrue,
          reason: 'only the client owning the registered URL scheme can '
              'complete a callback');
    });

    test('iOS is considered configured', () {
      expect(googleSignInConfigured(platform: TargetPlatform.iOS), isTrue);
    });
  });

  group('platform split (the fix itself)', () {
    test('iOS gets the iOS client and NEVER a serverClientId', () {
      // GIDSignIn.m:726-727 turns serverClientId into the OAuth `audience`,
      // which would mint the iOS token for the WEB client and break the
      // Supabase audience check that works today.
      final ios = buildGoogleSignIn(TargetPlatform.iOS);
      expect(ios.clientId, kGoogleIosClientId);
      expect(ios.serverClientId, isNull,
          reason: 'serverClientId on iOS silently flips the token audience');
    });

    test('Android gets NO clientId — the plugin would misread it', () {
      // GoogleSignInPlugin.java:222-231 reinterprets clientId as
      // serverClientId on Android, which is the original defect.
      final android = buildGoogleSignIn(TargetPlatform.android);
      expect(android.clientId, isNull);
      expect(android.serverClientId, googleServerClientId);
    });

    test('macOS is treated like iOS, not Android', () {
      expect(buildGoogleSignIn(TargetPlatform.macOS).clientId,
          kGoogleIosClientId);
    });
  });

  group('Android needs the web client', () {
    test('configuration follows the define, whichever way it is set', () {
      // Tolerant of a run WITH --dart-define=GOOGLE_SERVER_CLIENT_ID: assert
      // the relationship, not the environment.
      expect(googleSignInConfigured(platform: TargetPlatform.android),
          googleServerClientId != null);
    });

    test('whitespace is not configuration', () {
      // A define of "   " must not count as configured.
      expect(googleServerClientId, anyOf(isNull, isNot(matches(r'^\s*$'))));
    });

    test('sign-in fails as a configuration error, without opening Google',
        () async {
      if (googleServerClientId != null) return; // configured build: N/A
      final service = SupabaseAuthService(
        client: _client(),
        googleSignIn: _NeverCalledGoogleSignIn(),
        platform: TargetPlatform.android,
      );
      await expectLater(
        service.signInWithGoogle(),
        throwsA(isA<AuthConfigurationException>()
            .having((e) => e.message, 'message', contains('غير متاح'))),
      );
    });

    test('the error is not the misleading token-read message', () async {
      if (googleServerClientId != null) return; // configured build: N/A
      final service = SupabaseAuthService(
        client: _client(),
        googleSignIn: _NeverCalledGoogleSignIn(),
        platform: TargetPlatform.android,
      );
      try {
        await service.signInWithGoogle();
        fail('expected an AuthException');
      } on AuthConfigurationException catch (e) {
        expect(e.message.contains('لم نستطع قراءة رمز'), isFalse,
            reason: 'that message blamed the token read for a config defect');
      }
    });
  });
}
