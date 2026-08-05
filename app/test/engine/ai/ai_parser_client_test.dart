// MALI-060n — client sends a server-verifiable device secret + a stable
// idempotency request id + schema version to parse-sms.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:money_companion/engine/ai/ai_parser_client.dart';

void main() {
  SupabaseAiParserClient clientWith(
    http.Client http, {
    Future<String?> Function()? loadDeviceSecret,
  }) {
    return SupabaseAiParserClient(
      edgeFunctionUrl: 'https://x.test/functions/v1/parse-sms',
      getAnonJwt: () async => 'anon-jwt',
      loadDeviceSecret: loadDeviceSecret,
      httpClient: http,
    );
  }

  test('sends device_secret, request_id and schema_version', () async {
    late Map<String, dynamic> sent;
    final mock = MockClient((req) async {
      sent = jsonDecode(req.body) as Map<String, dynamic>;
      return http.Response(jsonEncode({'amount': 10.0, 'currency': 'SAR'}), 200);
    });
    await clientWith(mock, loadDeviceSecret: () async => 'the-secret').parse(
      sanitizedSms: 'ACME purchase',
      senderId: 'ACME',
      installId: 'install-1',
    );
    expect(sent['device_secret'], 'the-secret');
    expect(sent['schema_version'], 1);
    expect(sent['request_id'], isA<String>());
    expect((sent['request_id'] as String).isNotEmpty, isTrue);
  });

  test('reuses the same request_id across the internal retry (idempotent)',
      () async {
    final ids = <String>[];
    var attempt = 0;
    final mock = MockClient((req) async {
      ids.add((jsonDecode(req.body) as Map<String, dynamic>)['request_id'] as String);
      attempt++;
      // First attempt: transient 502; second: success.
      return attempt == 1
          ? http.Response(jsonEncode({'error': 'x'}), 502)
          : http.Response(jsonEncode({'amount': 10.0, 'currency': 'SAR'}), 200);
    });
    await clientWith(mock, loadDeviceSecret: () async => 's').parse(
      sanitizedSms: 'ACME',
      senderId: 'ACME',
      installId: 'i',
    );
    expect(ids.length, 2);
    expect(ids[0], ids[1]); // same id → server dedupes, no double charge
  });

  test('omits device_secret when none is available (degrades to unauth)',
      () async {
    late Map<String, dynamic> sent;
    final mock = MockClient((req) async {
      sent = jsonDecode(req.body) as Map<String, dynamic>;
      return http.Response(jsonEncode({'amount': 10.0, 'currency': 'SAR'}), 200);
    });
    await clientWith(mock, loadDeviceSecret: () async => null).parse(
      sanitizedSms: 'ACME',
      senderId: 'ACME',
      installId: 'i',
    );
    expect(sent.containsKey('device_secret'), isFalse);
    expect(sent['schema_version'], 1);
  });
}
