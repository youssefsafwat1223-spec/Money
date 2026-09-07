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

    test('the decoy plist client is NOT the registered scheme', () {
      // ios/GoogleService-Info.plist carries a different client whose reversed
      // scheme is absent from Info.plist — proof it could never work.
      final service =
          File('ios/GoogleService-Info.plist').readAsStringSync();
      final info = File('ios/Runner/Info.plist').readAsStringSync();
      final decoy = RegExp(r'com\.googleusercontent\.apps\.[0-9a-zA-Z\-]+')
          .allMatches(service)
          .map((m) => m.group(0)!)
          .toSet();
      final registered = RegExp(r'com\.googleusercontent\.apps\.[0-9a-zA-Z\-]+')
          .allMatches(info)
          .map((m) => m.group(0)!)
          .toSet();
      expect(decoy.difference(registered), isNotEmpty,
          reason: 'documents the known mismatch; if this ever becomes empty '
              'the decoy was aligned or removed and this test can go');
    });

    test('iOS is considered configured', () {
      expect(googleSignInConfigured(platform: TargetPlatform.iOS), isTrue);
    });
  });

  group('Android needs the web client', () {
    test('no GOOGLE_SERVER_CLIENT_ID define means not configured', () {
      expect(googleServerClientId, isNull);
      expect(googleSignInConfigured(platform: TargetPlatform.android), isFalse);
    });

    test('sign-in fails as a configuration error, without opening Google',
        () async {
      final service = SupabaseAuthService(
        client: _client(),
        googleSignIn: _NeverCalledGoogleSignIn(),
        platform: TargetPlatform.android,
      );
      await expectLater(
        service.signInWithGoogle(),
        throwsA(isA<AuthException>()
            .having((e) => e.message, 'message', contains('غير متاح'))),
      );
    });

    test('the error is not the misleading token-read message', () async {
      final service = SupabaseAuthService(
        client: _client(),
        googleSignIn: _NeverCalledGoogleSignIn(),
        platform: TargetPlatform.android,
      );
      try {
        await service.signInWithGoogle();
        fail('expected an AuthException');
      } on AuthException catch (e) {
        expect(e.message.contains('لم نستطع قراءة رمز'), isFalse,
            reason: 'that message blamed the token read for a config defect');
      }
    });
  });
}
