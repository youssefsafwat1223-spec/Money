import 'dart:convert';

/// Synthetic sessions for ASR tests. The access token is an unsigned JWT-shaped
/// string carrying only `sub` and `exp` (the SDK derives `expiresAt` from it).
/// No real credential is ever used.
String fakeJwt({required String uid, required int exp}) {
  String b64(Object o) =>
      base64Url.encode(utf8.encode(jsonEncode(o))).replaceAll('=', '');
  return '${b64({'alg': 'none', 'typ': 'JWT'})}.${b64({'sub': uid, 'exp': exp})}.sig';
}

Map<String, dynamic> sessionJson({
  required String uid,
  required int exp,
  String refreshToken = 'refresh-1',
}) =>
    {
      'access_token': fakeJwt(uid: uid, exp: exp),
      'expires_in': 3600,
      'refresh_token': refreshToken,
      'token_type': 'bearer',
      'user': {
        'id': uid,
        'app_metadata': <String, dynamic>{},
        'user_metadata': <String, dynamic>{},
        'aud': 'authenticated',
        'created_at': '2026-01-01T00:00:00Z',
      },
    };
