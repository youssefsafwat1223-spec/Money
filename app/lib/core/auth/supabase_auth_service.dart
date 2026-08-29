import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as supabase;

import 'auth_service.dart';

/// Audit **H-9** — Apple Sign-In nonce binding.
///
/// Apple's OIDC flow binds an identity token to ONE sign-in attempt by way of a
/// nonce: the SHA-256 hash of a fresh random value is sent with the
/// authorization request, Apple embeds that hash in the returned token, and the
/// RAW value is handed to the token exchange, which recomputes the hash and
/// compares. Without it, a still-valid Apple identity token minted for this app
/// carries no per-attempt challenge and can be replayed to the public auth
/// endpoint for its whole validity window.
///
/// Qirsh previously sent NO nonce in either direction.
///
/// Length is 32 bytes of `Random.secure()` — never a timestamp, counter or
/// `Random()` — rendered base64url. The raw value never leaves this file except
/// as the token-exchange parameter, and is never logged or persisted.
String generateAppleRawNonce({Random? random}) {
  final rng = random ?? Random.secure();
  final bytes = List<int>.generate(32, (_) => rng.nextInt(256));
  return base64UrlEncode(bytes).replaceAll('=', '');
}

/// The value sent to Apple: lowercase hex SHA-256 of the raw nonce, which is the
/// representation Apple's `ASAuthorizationAppleIDRequest.nonce` expects and what
/// the token's `nonce` claim is compared against.
String appleHashedNonce(String rawNonce) =>
    sha256.convert(utf8.encode(rawNonce)).toString();

class SupabaseAuthService implements AuthService {
  SupabaseAuthService({
    supabase.SupabaseClient? client,
    GoogleSignIn? googleSignIn,
  })  : _client = client ?? supabase.Supabase.instance.client,
        _googleSignIn = googleSignIn ??
            GoogleSignIn(
              scopes: const ['email'],
              clientId:
                  '881903820931-c4cttgekf9d3tcv3j2lt10ao2upk4b1m.apps.googleusercontent.com',
            );

  final supabase.SupabaseClient _client;
  final GoogleSignIn _googleSignIn;

  @override
  Future<void> signOutProviderSession() => _googleSignIn.signOut();

  @override
  Future<AuthIdentity> signInWithGoogle() async {
    final account = await _googleSignIn.signIn();
    if (account == null) {
      throw const AuthCancelledException('تم إلغاء تسجيل الدخول بجوجل.');
    }
    final auth = await account.authentication;
    final idToken = auth.idToken;
    if (idToken == null || idToken.isEmpty) {
      throw const AuthException('لم نستطع قراءة رمز دخول جوجل.');
    }
    // The native iOS Google Sign-In SDK generates and hashes its own nonce
    // inside the id_token without exposing the raw value, so we can't pass a
    // matching nonce here. Supabase's Google provider must have "Skip nonce
    // checks" enabled for this native flow to be accepted.
    final response = await _client.auth.signInWithIdToken(
      provider: supabase.OAuthProvider.google,
      idToken: idToken,
      accessToken: auth.accessToken,
    );
    final email = response.user?.email ?? account.email;
    return AuthIdentity(
      method: 'google',
      email: email,
      userId: response.user?.id,
    );
  }

  /// Monotonic per-attempt marker. Each Apple sign-in owns its nonce as a LOCAL
  /// value (so two concurrent attempts can never share or overwrite one), and
  /// this additionally ensures a stale attempt that completes late cannot
  /// establish a session behind a newer one.
  int _appleAttemptSeq = 0;

  @override
  Future<AuthIdentity> signInWithApple() async {
    final attempt = ++_appleAttemptSeq;
    // Per-attempt, function-scoped: nothing to clear on a terminal outcome
    // because nothing outlives this frame. Never logged, never persisted.
    final rawNonce = generateAppleRawNonce();

    final AuthorizationCredentialAppleID credential;
    try {
      credential = await SignInWithApple.getAppleIDCredential(
        scopes: const [
          AppleIDAuthorizationScopes.email,
          AppleIDAuthorizationScopes.fullName,
        ],
        // Apple receives the HASH; the raw value is proved at exchange time.
        nonce: appleHashedNonce(rawNonce),
      );
    } on SignInWithAppleAuthorizationException catch (e) {
      // A cancelled attempt must end as a cancellation, not an opaque error —
      // and it establishes no session, leaving this attempt's nonce unused.
      if (e.code == AuthorizationErrorCode.canceled) {
        throw const AuthCancelledException('تم إلغاء تسجيل الدخول بـ Apple.');
      }
      throw const AuthException('تعذّر تسجيل الدخول بـ Apple.');
    }

    if (attempt != _appleAttemptSeq) {
      // Superseded while the system sheet was open.
      throw const AuthCancelledException('تم إلغاء تسجيل الدخول بـ Apple.');
    }

    final identityToken = credential.identityToken;
    if (identityToken == null || identityToken.isEmpty) {
      throw const AuthException('لم نستطع قراءة رمز دخول Apple.');
    }

    final response = await _client.auth.signInWithIdToken(
      provider: supabase.OAuthProvider.apple,
      idToken: identityToken,
      // The RAW nonce for THIS attempt. The backend re-hashes it and compares
      // against the token's `nonce` claim, so a token minted for a different
      // attempt (or with no nonce at all) cannot be exchanged here.
      nonce: rawNonce,
    );

    if (attempt != _appleAttemptSeq) {
      throw const AuthCancelledException('تم إلغاء تسجيل الدخول بـ Apple.');
    }

    final email = response.user?.email ?? credential.email;
    return AuthIdentity(
      method: 'apple',
      email: email,
      userId: response.user?.id,
    );
  }

  @override
  Future<void> sendEmailCode(String email) async {
    await _client.auth.signInWithOtp(email: email);
  }

  @override
  Future<AuthIdentity?> verifyEmailCode({
    required String email,
    required String code,
  }) async {
    final token = code.replaceAll(RegExp(r'\s'), '');
    final response = await _client.auth.verifyOTP(
      email: email,
      token: token,
      type: supabase.OtpType.email,
    );
    final user = response.user;
    if (user == null) return null;
    return AuthIdentity(
      method: 'email',
      email: user.email ?? email,
      userId: user.id,
    );
  }
}

class AuthException implements Exception {
  const AuthException(this.message);

  final String message;

  @override
  String toString() => message;
}

class AuthCancelledException extends AuthException {
  const AuthCancelledException(super.message);
}
