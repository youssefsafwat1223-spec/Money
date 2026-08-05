import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../domain/entities/bank_discovery_models.dart';

abstract class BankDiscoveryClient {
  Future<BankDiscoverySuggestion?> detectBank(BankDiscoveryRequest request);
}

class GeminiBankDiscoveryClient implements BankDiscoveryClient {
  GeminiBankDiscoveryClient({
    required String edgeFunctionUrl,
    required Future<String?> Function() getAnonJwt,
    Future<String?> Function()? loadDeviceSecret,
    http.Client? httpClient,
    Duration timeout = const Duration(seconds: 4),
  })  : _url = edgeFunctionUrl,
        _getAnonJwt = getAnonJwt,
        _loadDeviceSecret = loadDeviceSecret,
        _http = httpClient ?? http.Client(),
        _timeout = timeout;

  final String _url;
  final Future<String?> Function() _getAnonJwt;

  /// MALI-060n: server-verified device secret. Without it the hardened server
  /// returns authentication_required and discovery is silently skipped.
  final Future<String?> Function()? _loadDeviceSecret;
  final http.Client _http;
  final Duration _timeout;

  @override
  Future<BankDiscoverySuggestion?> detectBank(
    BankDiscoveryRequest request,
  ) async {
    final jwt = await _getAnonJwt();
    if (jwt == null) return null;
    final deviceSecret = await _loadDeviceSecret?.call();
    try {
      final response = await _http
          .post(
            Uri.parse(_url),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $jwt',
            },
            body: jsonEncode({
              'sender_id': request.senderId,
              'sanitized_sms': request.sanitizedSms,
              'detected_currency': request.detectedCurrency,
              'locale_hint': request.localeHint,
              'install_id': request.installId,
              if (deviceSecret != null && deviceSecret.isNotEmpty)
                'device_secret': deviceSecret,
              'schema_version': 1,
            }),
          )
          .timeout(_timeout);
      if (response.statusCode != 200) return null;
      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) return null;
      return BankDiscoverySuggestion.fromJson(decoded);
    } catch (_) {
      return null;
    }
  }
}
