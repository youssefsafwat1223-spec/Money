import 'package:google_sign_in/google_sign_in.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as supabase;

import 'auth_service.dart';

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

  @override
  Future<AuthIdentity> signInWithApple() async {
    final credential = await SignInWithApple.getAppleIDCredential(
      scopes: const [
        AppleIDAuthorizationScopes.email,
        AppleIDAuthorizationScopes.fullName,
      ],
    );
    final identityToken = credential.identityToken;
    if (identityToken == null || identityToken.isEmpty) {
      throw const AuthException('لم نستطع قراءة رمز دخول Apple.');
    }
    final response = await _client.auth.signInWithIdToken(
      provider: supabase.OAuthProvider.apple,
      idToken: identityToken,
    );
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
