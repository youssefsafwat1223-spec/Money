import 'dart:convert';

import 'package:sign_in_with_apple/sign_in_with_apple.dart';

import 'supabase_auth_service.dart' show appleHashedNonce;

/// Outcome of the Apple re-authentication that proves intent to delete.
sealed class AppleReauthResult {
  const AppleReauthResult();
}

/// [challengeResponse] is the contract's JSON string
/// `{"identity_token": ..., "authorization_code": ...}`. Never log it.
final class AppleReauthGranted extends AppleReauthResult {
  const AppleReauthGranted(this.challengeResponse);
  final String challengeResponse;
  @override
  String toString() => 'AppleReauthGranted';
}

/// The person dismissed the Apple sheet. Nothing may be sent to the server.
final class AppleReauthCancelled extends AppleReauthResult {
  const AppleReauthCancelled();
}

/// Apple (or the platform) failed, or returned an unusable credential.
final class AppleReauthFailed extends AppleReauthResult {
  const AppleReauthFailed();
}

/// Port so the Delete Account flow never touches the platform in tests.
abstract interface class AppleDeletionReauth {
  /// Re-authenticates with Apple, binding the request to [nonce] (the raw
  /// server nonce; Apple receives its lower-hex SHA-256, exactly as sign-in).
  Future<AppleReauthResult> reauthenticate({required String nonce});
}

typedef AppleCredentialFetcher = Future<AuthorizationCredentialAppleID> Function({
  required List<AppleIDAuthorizationScopes> scopes,
  required String nonce,
});

Future<AuthorizationCredentialAppleID> _platformFetch({
  required List<AppleIDAuthorizationScopes> scopes,
  required String nonce,
}) =>
    SignInWithApple.getAppleIDCredential(scopes: scopes, nonce: nonce);

String buildAppleChallengeResponse(
        {required String identityToken, required String authorizationCode}) =>
    jsonEncode(<String, String>{
      'identity_token': identityToken,
      'authorization_code': authorizationCode,
    });

class PlatformAppleDeletionReauth implements AppleDeletionReauth {
  const PlatformAppleDeletionReauth({AppleCredentialFetcher? fetch})
      : _fetch = fetch ?? _platformFetch;
  final AppleCredentialFetcher _fetch;

  @override
  Future<AppleReauthResult> reauthenticate({required String nonce}) async {
    final AuthorizationCredentialAppleID credential;
    try {
      credential = await _fetch(
          scopes: const <AppleIDAuthorizationScopes>[],
          nonce: appleHashedNonce(nonce));
    } on SignInWithAppleAuthorizationException catch (e) {
      return e.code == AuthorizationErrorCode.canceled
          ? const AppleReauthCancelled()
          : const AppleReauthFailed();
    } catch (_) {
      return const AppleReauthFailed();
    }
    final token = credential.identityToken;
    final code = credential.authorizationCode;
    if (token == null || token.isEmpty || code.isEmpty) {
      return const AppleReauthFailed();
    }
    return AppleReauthGranted(buildAppleChallengeResponse(
        identityToken: token, authorizationCode: code));
  }
}
