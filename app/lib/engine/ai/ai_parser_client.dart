import 'dart:convert';

import 'package:http/http.dart' as http;

class AiParseException implements Exception {
  const AiParseException(this.reason);

  final String reason;

  @override
  String toString() => 'AiParseException($reason)';
}

class AiParseResponse {
  const AiParseResponse({
    required this.amount,
    required this.currency,
    this.merchantName,
    this.type,
    this.categoryKey,
    this.direction,
    this.occurredAt,
    this.modelUsed,
  });

  final double amount;
  final String currency;
  final String? merchantName;
  final String? type;
  final String? categoryKey;
  final String? direction;
  final DateTime? occurredAt;
  final String? modelUsed;

  factory AiParseResponse.fromJson(Map<String, dynamic> json) {
    return AiParseResponse(
      amount: (json['amount'] as num).toDouble(),
      currency: json['currency'] as String,
      merchantName: json['merchant_name'] as String?,
      type: json['type'] as String?,
      categoryKey: json['category_key'] as String?,
      direction: json['direction'] as String?,
      occurredAt: json['occurred_at'] is String
          ? DateTime.tryParse(json['occurred_at'] as String)
          : null,
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
    if (jwt == null || jwt.isEmpty) {
      throw const AiParseException('missing_jwt');
    }
    final body = jsonEncode({
      'sanitized_sms': sanitizedSms,
      'sender_id': senderId,
      'install_id': installId,
    });
    // Up to 2 attempts: cold starts / transient 5xx on the edge function are
    // common (e.g. a 502 then a 200), so retry once before giving up. The
    // per-attempt timeout guarantees we never hang.
    for (var attempt = 1; attempt <= 2; attempt++) {
      try {
        final response = await _http
            .post(
              Uri.parse(_url),
              headers: {
                'Content-Type': 'application/json',
                'Authorization': 'Bearer $jwt',
              },
              body: body,
            )
            .timeout(const Duration(seconds: 12));

        if (response.statusCode == 200) {
          final json = jsonDecode(response.body) as Map<String, dynamic>;
          if (json['is_transaction'] == false) {
            return null; // AI explicitly says this is not a transaction
          }
          if (json['amount'] == null || json['currency'] == null) {
            throw const AiParseException('missing_amount_or_currency');
          }
          return AiParseResponse.fromJson(json);
        }
        final transient = response.statusCode == 502 ||
            response.statusCode == 503 ||
            response.statusCode == 504;
        if (transient && attempt < 2) {
          await Future.delayed(const Duration(milliseconds: 600));
          continue;
        }
        if (transient) return null;
        var reason = 'http_${response.statusCode}';
        try {
          final json = jsonDecode(response.body);
          if (json is Map && json['error'] != null) {
            reason = '$reason:${json['error']}';
          }
        } catch (_) {
          // Keep the HTTP status if the body is not JSON.
        }
        throw AiParseException(reason);
      } catch (error) {
        if (attempt < 2) {
          await Future.delayed(const Duration(milliseconds: 600));
          continue;
        }
        if (error is AiParseException) rethrow;
        return null;
      }
    }
    throw const AiParseException('unknown_failure');
  }
}
