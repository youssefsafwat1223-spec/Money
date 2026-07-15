import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart';
import 'package:http/testing.dart';
import 'package:money_companion/features/capture/services/capture_backend_client.dart';

void main() {
  test('pending-send retry preserves payload id and AI consent', () async {
    late Request sent;
    final client = CaptureBackendClient(
      supabaseUrl: 'https://example.supabase.co',
      anonKey: 'anon-key',
      httpClient: MockClient((request) async {
        sent = request;
        return Response('{"status":"processed"}', 200);
      }),
    );

    await client.processIosSms(
      installId: 'install-a',
      deviceSecret: 'device-secret',
      payloadId: 'stable-payload',
      smsText: 'bank message',
      receivedAt: DateTime.utc(2026, 7, 14, 12),
      allowAi: false,
    );

    final body = jsonDecode(sent.body) as Map<String, dynamic>;
    expect(body['payloadId'], 'stable-payload');
    expect(body['allowAi'], isFalse);
    expect(sent.url.path, '/functions/v1/process-ios-sms');
  });

  test('unlink uses device credentials and never requires a user JWT',
      () async {
    late Request sent;
    final client = CaptureBackendClient(
      supabaseUrl: 'https://example.supabase.co',
      anonKey: 'anon-key',
      httpClient: MockClient((request) async {
        sent = request;
        return Response('{"ok":true}', 200);
      }),
    );

    await client.unlinkDevice(
      installId: 'install-a',
      deviceSecret: 'device-secret',
    );

    expect(sent.url.path, '/functions/v1/unlink-capture-device');
    expect(sent.headers['authorization'], 'Bearer anon-key');
    expect(jsonDecode(sent.body), {
      'installId': 'install-a',
      'deviceSecret': 'device-secret',
    });
  });

  test('unlink failure is reported without rotating the local secret',
      () async {
    final client = CaptureBackendClient(
      supabaseUrl: 'https://example.supabase.co',
      anonKey: 'anon-key',
      httpClient: MockClient((_) async => Response('{}', 401)),
    );

    await expectLater(
      client.unlinkDevice(installId: 'install-a', deviceSecret: 'bad'),
      throwsA(isA<CaptureBackendException>()),
    );
  });
}
