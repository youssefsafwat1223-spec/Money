import 'dart:convert';

import 'package:http/http.dart' as http;

class AiParseResponse {
  const AiParseResponse({
    required this.amount,
    required this.currency,
    this.merchantName,
    this.type,
    this.categoryKey,
    this.modelUsed,
  });

  final double amount;
  final String currency;
  final String? merchantName;
  final String? type;
  final String? categoryKey;
  final String? modelUsed;

  factory AiParseResponse.fromJson(Map<String, dynamic> json) {
    return AiParseResponse(
      amount: (json['amount'] as num).toDouble(),
      currency: json['currency'] as String,
      merchantName: json['merchant_name'] as String?,
      type: json['type'] as String?,
      categoryKey: json['category_key'] as String?,
      modelUsed: json['model_used'] as String?,
    );
  }
}

abstract class AiParserClient {
  Future<AiParseResponse?> parse({
    required String sanitizedSms,
    required String senderId,
    required String installId,
  });
}

class SupabaseAiParserClient implements AiParserClient {
  SupabaseAiParserClient({
    required String edgeFunctionUrl,
    required Future<String?> Function() getAnonJwt,
    http.Client? httpClient,
  })  : _url = edgeFunctionUrl,
        _getAnonJwt = getAnonJwt,
        _http = httpClient ?? http.Client();

  final String _url;
  final Future<String?> Function() _getAnonJwt;
  final http.Client _http;

  @override
  Future<AiParseResponse?> parse({
    required String sanitizedSms,
    required String senderId,
    required String installId,
  }) async {
    final jwt = await _getAnonJwt();
    if (jwt == null) return null;
    try {
      final response = await _http
          .post(
            Uri.parse(_url),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $jwt',
            },
            body: jsonEncode({
              'sanitized_sms': sanitizedSms,
              'sender_id': senderId,
              'install_id': installId,
            }),
          )
          .timeout(const Duration(seconds: 10));

      if (response.statusCode != 200) return null;
      final json = jsonDecode(response.body) as Map<String, dynamic>;
      if (json['amount'] == null || json['currency'] == null) return null;
      return AiParseResponse.fromJson(json);
    } catch (_) {
      return null;
    }
  }
}
