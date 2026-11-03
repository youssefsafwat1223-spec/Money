import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/auth/owned_tls_socket.dart';
import 'package:money_companion/core/auth/refresh_transport.dart';

import 'tls_fixture.dart';

/// ASR v7.2 §10.1–§10.4: the refresh exchange's phases (open = connect only,
/// send = credential bytes), its request shape, redirect/body limits, and the
/// T1/T2/T5 transport cases against a real local TLS server.
void main() {
  TlsFixture? tls;
  late HttpServer server;
  late List<_Seen> seen;
  late Future<void> Function(HttpRequest req) handler;
  var connections = 0;

  setUpAll(() async => tls = await TlsFixture.create());
  tearDownAll(() async => tls?.dispose());

  setUp(() async {
    if (tls == null) return;
    seen = [];
    connections = 0;
    handler = (req) async {
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode({'access_token': 'a', 'refresh_token': 'r2'}));
      await req.response.close();
    };
    server = await HttpServer.bindSecure('localhost', 0, tls!.serverContext);
    server.listen((req) async {
      final body = await utf8.decodeStream(req);
      seen.add(_Seen(req.method, req.uri, req.headers, body));
      await handler(req);
    });
  });

  tearDown(() async {
    if (tls == null) return;
    await server.close(force: true);
  });

  RefreshExchange exchange({ConnectionOwner? owner}) => RefreshExchange(
        tokenUri: Uri.parse(
            'https://localhost:${server.port}/auth/v1/token?grant_type=refresh_token'),
        apiKey: 'anon-test-key',
        owner: owner ??
            ConnectionOwner(
              context: tls!.clientContext,
              rawConnect: (h, p) {
                connections++;
                return RawSocket.startConnect(h, p);
              },
            ),
      );

  Future<void> quiet(RefreshExchange ex) => ex
      .quiesced()
      .timeout(const Duration(seconds: 5), onTimeout: () => fail('not quiescent'));

  test('request shape: POST, grant in query, JSON body, apikey, no redirects',
      () async {
    if (tls == null) return markTestSkipped('openssl unavailable');
    final ex = exchange();
    await ex.open();
    expect(seen, isEmpty, reason: 'open() writes no request bytes');
    final res = await ex.send('r1');
    ex.close();
    await quiet(ex);
    expect(res.statusCode, 200);
    expect((res.json! as Map)['refresh_token'], 'r2');
    final s = seen.single;
    expect(s.method, 'POST');
    expect(s.uri.path, '/auth/v1/token');
    expect(s.uri.queryParameters, {'grant_type': 'refresh_token'});
    expect(jsonDecode(s.body), {'refresh_token': 'r1'});
    expect(s.headers.value('apikey'), 'anon-test-key');
    expect(s.headers.contentType?.mimeType, 'application/json');
  });

  test('a gzip HTTP 200 is decoded before JSON parsing', () async {
    if (tls == null) return markTestSkipped('openssl unavailable');
    final payload = {'access_token': 'a', 'refresh_token': 'r2'};
    handler = (req) async {
      req.response.headers
        ..contentType = ContentType.json
        ..set(HttpHeaders.contentEncodingHeader, 'gzip');
      req.response.add(gzip.encode(utf8.encode(jsonEncode(payload))));
      await req.response.close();
    };
    final ex = exchange();
    addTearDown(() async {
      ex.cancel();
      await quiet(ex);
    });
    await ex.open();
    final result = await ex.send('r1');
    expect(seen.single.headers.value(HttpHeaders.acceptEncodingHeader), 'gzip');
    expect(result.statusCode, 200);
    expect(result.json, payload,
        reason: 'compressed success must not consume a retry as invalid JSON');
  });

  test('gzip cannot bypass the decompressed response size limit', () async {
    if (tls == null) return markTestSkipped('openssl unavailable');
    final wire = gzip.encode(List<int>.filled(100 * 1024, 0x20));
    expect(wire.length, lessThan(64 * 1024));
    handler = (req) async {
      req.response.headers.set(HttpHeaders.contentEncodingHeader, 'gzip');
      req.response.add(wire);
      await req.response.close();
    };
    final ex = exchange();
    addTearDown(() async {
      ex.cancel();
      await quiet(ex);
    });
    await ex.open();
    await expectLater(ex.send('r1'), throwsA(isA<RefreshBodyTooLarge>()));
  });

  test('malformed gzip is refused and the transport quiesces', () async {
    if (tls == null) return markTestSkipped('openssl unavailable');
    handler = (req) async {
      req.response.headers.set(HttpHeaders.contentEncodingHeader, 'gzip');
      req.response.add(utf8.encode('not a gzip stream'));
      await req.response.close();
    };
    final ex = exchange();
    addTearDown(() async {
      ex.cancel();
      await quiet(ex);
    });
    await ex.open();
    await expectLater(ex.send('r1'), throwsA(anything));
  });

  test('cancelling a streaming gzip response settles the owned transport',
      () async {
    if (tls == null) return markTestSkipped('openssl unavailable');
    final firstChunk = Completer<void>();
    final wire = gzip.encode(utf8.encode('{"refresh_token":"r2"}'));
    handler = (req) async {
      req.response.bufferOutput = false;
      req.response.headers.set(HttpHeaders.contentEncodingHeader, 'gzip');
      req.response.add(wire.sublist(0, wire.length ~/ 2));
      await req.response.flush();
      firstChunk.complete();
    };
    final ex = exchange();
    await ex.open();
    final result = ex.send('r1');
    await firstChunk.future;
    ex.cancel();
    await expectLater(result, throwsA(anything));
    await quiet(ex);
  });

  test('T1 cancel before open → zero connections', () async {
    if (tls == null) return markTestSkipped('openssl unavailable');
    final ex = exchange()..cancel();
    await expectLater(ex.open(), throwsA(isA<RefreshCancelled>()));
    await quiet(ex);
    expect(connections, 0);
    expect(seen, isEmpty);
  });

  test('cancel after open, before send → no credential bytes', () async {
    if (tls == null) return markTestSkipped('openssl unavailable');
    final ex = exchange();
    await ex.open();
    ex.cancel();
    await expectLater(ex.send('r1'), throwsA(isA<RefreshCancelled>()));
    await quiet(ex);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(seen, isEmpty);
    expect(ex.sent, isFalse);
  });

  test('T2 cancel while the response is pending → aborted, quiescent', () async {
    if (tls == null) return markTestSkipped('openssl unavailable');
    final arrived = Completer<void>();
    handler = (req) async {
      arrived.complete();
      await Future<void>.delayed(const Duration(seconds: 30));
    };
    final ex = exchange();
    await ex.open();
    final res = ex.send('r1');
    await arrived.future;
    ex.cancel();
    await expectLater(res, throwsA(anything));
    await quiet(ex);
  });

  test('T2 cancel during body streaming → subscription cancelled, quiescent',
      () async {
    if (tls == null) return markTestSkipped('openssl unavailable');
    final firstChunk = Completer<void>();
    handler = (req) async {
      req.response.bufferOutput = false;
      req.response.write('{"access_token":');
      await req.response.flush();
      firstChunk.complete();
      await Future<void>.delayed(const Duration(seconds: 30));
    };
    final ex = exchange();
    await ex.open();
    final res = ex.send('r1');
    await firstChunk.future;
    await Future<void>.delayed(const Duration(milliseconds: 50));
    ex.cancel();
    await expectLater(res, throwsA(anything));
    await quiet(ex);
  });

  test('T5 a 3xx is reported, never followed', () async {
    if (tls == null) return markTestSkipped('openssl unavailable');
    handler = (req) async {
      req.response.statusCode = 307;
      req.response.headers.set('location', 'https://localhost:${server.port}/x');
      await req.response.close();
    };
    final ex = exchange();
    await ex.open();
    final res = await ex.send('r1');
    ex.close();
    await quiet(ex);
    expect(res.isRedirect, isTrue);
    expect(seen, hasLength(1));
  });

  test('an oversized body is refused', () async {
    if (tls == null) return markTestSkipped('openssl unavailable');
    handler = (req) async {
      req.response.add(List<int>.filled(100 * 1024, 0x20));
      await req.response.close();
    };
    final ex = exchange();
    await ex.open();
    await expectLater(ex.send('r1'), throwsA(isA<RefreshBodyTooLarge>()));
    ex.close();
    await quiet(ex);
  });

  test('send is single-use', () async {
    if (tls == null) return markTestSkipped('openssl unavailable');
    final ex = exchange();
    await ex.open();
    await ex.send('r1');
    await expectLater(ex.send('r1'), throwsA(isA<RefreshCancelled>()));
    ex.close();
    await quiet(ex);
    expect(seen, hasLength(1));
  });
}

class _Seen {
  _Seen(this.method, this.uri, this.headers, this.body);
  final String method;
  final Uri uri;
  final HttpHeaders headers;
  final String body;
}
