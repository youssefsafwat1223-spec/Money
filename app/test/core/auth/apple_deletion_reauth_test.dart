import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/auth/apple_deletion_reauth.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';

AuthorizationCredentialAppleID _credential(
        {String? token = 'id-token', String code = 'auth-code'}) =>
    AuthorizationCredentialAppleID(
        userIdentifier: null,
        givenName: null,
        familyName: null,
        authorizationCode: code,
        email: null,
        identityToken: token,
        state: null);

void main() {
  test('asks Apple for no scopes with sha256-hex(nonce) and builds the contract JSON',
      () async {
    List<AppleIDAuthorizationScopes>? askedScopes;
    String? sent;
    final port = PlatformAppleDeletionReauth(
        fetch: ({required scopes, required nonce}) async {
      askedScopes = scopes;
      sent = nonce;
      return _credential();
    });
    final result = await port.reauthenticate(nonce: 'raw-nonce');
    expect(sent, sha256.convert(utf8.encode('raw-nonce')).toString());
    expect(askedScopes, isEmpty);
    expect(result, isA<AppleReauthGranted>());
    expect(jsonDecode((result as AppleReauthGranted).challengeResponse), {
      'identity_token': 'id-token',
      'authorization_code': 'auth-code',
    });
    expect('$result', isNot(contains('id-token')));
  });

  test('the person cancelling is a cancel, distinct from failures', () async {
    Future<AppleReauthResult> run(Object error) =>
        PlatformAppleDeletionReauth(
            fetch: ({required scopes, required nonce}) async =>
                throw error).reauthenticate(nonce: 'n');
    expect(
        await run(const SignInWithAppleAuthorizationException(
            code: AuthorizationErrorCode.canceled, message: 'x')),
        isA<AppleReauthCancelled>());
    expect(
        await run(const SignInWithAppleAuthorizationException(
            code: AuthorizationErrorCode.failed, message: 'x')),
        isA<AppleReauthFailed>());
    expect(await run(StateError('platform')), isA<AppleReauthFailed>());
  });

  test('a credential without an identity token or code is a failure', () async {
    for (final c in [_credential(token: null), _credential(token: ''), _credential(code: '')]) {
      final r = await PlatformAppleDeletionReauth(
          fetch: ({required scopes, required nonce}) async =>
              c).reauthenticate(nonce: 'n');
      expect(r, isA<AppleReauthFailed>());
    }
  });
}
