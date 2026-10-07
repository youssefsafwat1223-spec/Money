import 'dart:convert';

import 'package:http/http.dart' as http;

import 'capture_backend_client.dart';

/// WP-6 — the v2 (JWT) consent contract of the capture backend: both calls carry
/// the device secret AND the user's JWT, and a monotonically increasing version.
/// Kept apart from [CaptureBackendClient] so the build-50 (device-secret only)
/// contract and its fakes stay untouched.
class CaptureConsentClient {
  CaptureConsentClient({
    required String supabaseUrl,
    required String anonKey,
    http.Client? httpClient,
  })  : _supabaseUrl = supabaseUrl,
        _anonKey = anonKey,
        _http = httpClient ?? http.Client();

  final String _supabaseUrl;
  final String _anonKey;
  final http.Client _http;

  Uri _uri(String name) => Uri.parse('$_supabaseUrl/functions/v1/$name');

  Map<String, String> _headers(String jwt) => {
        'Content-Type': 'application/json',
        'apikey': _anonKey,
        'Authorization': 'Bearer $jwt',
      };

  /// `link-capture-device` v2: binds the install to the JWT's user and REPLACES
  /// the consent projection (owner, both flags, version) in one statement.
  Future<void> link({
    required String installId,
    required String deviceSecret,
    required String jwt,
    required bool cloud,
    required bool ai,
    required int version,
  }) async {
    final response = await _http
        .post(
          _uri('link-capture-device'),
          headers: _headers(jwt),
          body: jsonEncode({
            'installId': installId,
            'deviceSecret': deviceSecret,
            'schema_version': 2,
            'consent': {
              'cloud_processing_enabled': cloud,
              'ai_consent_granted': ai,
              'version': version,
            },
          }),
        )
        .timeout(const Duration(seconds: 12));
    if (response.statusCode != 200) {
      throw CaptureBackendException(
          'link_device_failed_${response.statusCode}');
    }
  }

  /// `set-device-consent` v2: owner-scoped, applied only when [version] is newer
  /// than the stored one. A revocation fans out server-side in the same call.
  Future<void> setConsent({
    required String installId,
    required String deviceSecret,
    required String jwt,
    required bool cloud,
    required bool ai,
    required int version,
  }) async {
    final response = await _http
        .post(
          _uri('set-device-consent'),
          headers: _headers(jwt),
          body: jsonEncode({
            'installId': installId,
            'deviceSecret': deviceSecret,
            'schema_version': 2,
            'cloud_processing_enabled': cloud,
            'ai_consent_granted': ai,
            'consent_version': version,
          }),
        )
        .timeout(const Duration(seconds: 12));
    if (response.statusCode != 200) {
      throw CaptureBackendException(
          'set_consent_failed_${response.statusCode}');
    }
  }
}
