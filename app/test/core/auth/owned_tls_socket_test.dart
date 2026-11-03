import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/auth/owned_tls_socket.dart';

import 'tls_fixture.dart';

/// A real secure socket whose event subscription's cancellation completes
/// only when [gate] does (Phase 4c B8: a delayed cancellation).
class _SlowCancelSecure extends Stream<RawSocketEvent>
    implements RawSecureSocket {
  _SlowCancelSecure(this._s, this.gate);
  final RawSecureSocket _s;
  final Completer<void> gate;

  @override
  StreamSubscription<RawSocketEvent> listen(
      void Function(RawSocketEvent event)? onData,
      {Function? onError,
      void Function()? onDone,
      bool? cancelOnError}) {
    final inner = _s.listen(onData,
        onError: onError, onDone: onDone, cancelOnError: cancelOnError);
    return _SlowSubscription(inner, gate);
  }

  @override
  bool get readEventsEnabled => _s.readEventsEnabled;
  @override
  set readEventsEnabled(bool v) => _s.readEventsEnabled = v;
  @override
  bool get writeEventsEnabled => _s.writeEventsEnabled;
  @override
  set writeEventsEnabled(bool v) => _s.writeEventsEnabled = v;
  @override
  Uint8List? read([int? len]) => _s.read(len);
  @override
  int write(List<int> buffer, [int offset = 0, int? count]) =>
      _s.write(buffer, offset, count);
  @override
  Future<RawSocket> close() => _s.close();
  @override
  void shutdown(SocketDirection direction) => _s.shutdown(direction);
  @override
  InternetAddress get address => _s.address;
  @override
  int get port => _s.port;
  @override
  InternetAddress get remoteAddress => _s.remoteAddress;
  @override
  int get remotePort => _s.remotePort;
  @override
  bool setOption(SocketOption option, bool enabled) =>
      _s.setOption(option, enabled);
  @override
  Uint8List getRawOption(RawSocketOption option) => _s.getRawOption(option);
  @override
  void setRawOption(RawSocketOption option) => _s.setRawOption(option);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _SlowSubscription implements StreamSubscription<RawSocketEvent> {
  _SlowSubscription(this._inner, this._gate);
  final StreamSubscription<RawSocketEvent> _inner;
  final Completer<void> _gate;

  @override
  Future<void> cancel() async {
    await _inner.cancel();
    await _gate.future;
  }

  @override
  void onData(void Function(RawSocketEvent data)? handleData) =>
      _inner.onData(handleData);
  @override
  void onError(Function? handleError) => _inner.onError(handleError);
  @override
  void onDone(void Function()? handleDone) => _inner.onDone(handleDone);
  @override
  void pause([Future<void>? resumeSignal]) => _inner.pause(resumeSignal);
  @override
  void resume() => _inner.resume();
  @override
  bool get isPaused => _inner.isPaused;
  @override
  Future<E> asFuture<E>([E? futureValue]) => _inner.asFuture(futureValue);
}

/// ASR v7.2 §10.1/§10.4 (V1) and tests TLS1–TLS3: operation-owned TLS
/// connections, cancellation in every factory stage, and transport quiescence
/// that never depends on the SDK handshake future settling.
///
/// TLS cases use [TlsFixture] and skip when `openssl` is absent.
void main() {
  TlsFixture? tls;
  late SecurityContext serverCtx;
  late SecurityContext clientCtx;
  var haveOpenssl = true;

  setUpAll(() async {
    tls = await TlsFixture.create();
    if (tls == null) {
      haveOpenssl = false;
      return;
    }
    serverCtx = tls!.serverContext;
    clientCtx = tls!.clientContext;
  });

  tearDownAll(() async => tls?.dispose());

  HttpClient clientFor(ConnectionOwner owner) => HttpClient()
    ..findProxy = ((_) => 'DIRECT')
    ..connectionFactory = owner.create;

  Future<void> expectQuiescent(ConnectionOwner owner) => owner
      .quiesced()
      .timeout(const Duration(seconds: 5),
          onTimeout: () => fail('owner did not quiesce'));

  group('conformance (OwnedTlsSocket under a real HttpClient)', () {
    late HttpServer server;

    setUp(() async {
      if (!haveOpenssl) return;
      server = await HttpServer.bindSecure('localhost', 0, serverCtx);
      server.listen((req) async {
        final body = await utf8.decodeStream(req);
        if (req.uri.path == '/chunked') {
          req.response.bufferOutput = false;
          for (var i = 0; i < 5; i++) {
            req.response.write('part$i;');
            await req.response.flush();
          }
        } else if (req.uri.path == '/big') {
          req.response.contentLength = 300000;
          req.response.add(List<int>.filled(300000, 0x61));
        } else {
          req.response.headers.contentType = ContentType.json;
          req.response.write(jsonEncode({'echo': body}));
        }
        await req.response.close();
      });
    });

    tearDown(() async {
      if (!haveOpenssl) return;
      await server.close(force: true);
    });

    Future<String> post(String path, String body) async {
      final owner = ConnectionOwner(context: clientCtx);
      final client = clientFor(owner);
      try {
        final req = await client
            .postUrl(Uri.parse('https://localhost:${server.port}$path'));
        req.persistentConnection = false;
        req.add(utf8.encode(body));
        final res = await req.close();
        return await utf8.decodeStream(res);
      } finally {
        client.close(force: true);
        owner.closeAll();
        await expectQuiescent(owner);
      }
    }

    test('content-length request/response round trip', () async {
      if (!haveOpenssl) return markTestSkipped('openssl unavailable');
      expect(await post('/echo', '{"refresh_token":"x"}'),
          '{"echo":"{\\"refresh_token\\":\\"x\\"}"}');
    });

    test('chunked response', () async {
      if (!haveOpenssl) return markTestSkipped('openssl unavailable');
      expect(await post('/chunked', ''), 'part0;part1;part2;part3;part4;');
    });

    test('large body with backpressure', () async {
      if (!haveOpenssl) return markTestSkipped('openssl unavailable');
      expect((await post('/big', '')).length, 300000);
    });

    test('default certificate validation rejects an untrusted peer', () async {
      if (!haveOpenssl) return markTestSkipped('openssl unavailable');
      final owner = ConnectionOwner(); // no trusted test cert
      final client = clientFor(owner);
      await expectLater(
          client.postUrl(Uri.parse('https://localhost:${server.port}/echo')),
          throwsA(isA<HandshakeException>()));
      client.close(force: true);
      owner.closeAll();
      await expectQuiescent(owner);
    });
  });

  group('factory refusals', () {
    test('a proxy or plaintext request is refused without a connection',
        () async {
      var connects = 0;
      final owner = ConnectionOwner(rawConnect: (h, p) {
        connects++;
        return RawSocket.startConnect(h, p);
      });
      await expectLater(owner.create(Uri.parse('https://example.test/'), 'p', 1),
          throwsA(isA<RefreshCancelled>()));
      await expectLater(owner.create(Uri.parse('http://example.test/'), null, null),
          throwsA(isA<RefreshCancelled>()));
      expect(connects, 0);
      await expectQuiescent(owner);
    });

    test('an invocation after cancellation creates nothing', () async {
      var connects = 0;
      final owner = ConnectionOwner(rawConnect: (h, p) {
        connects++;
        return RawSocket.startConnect(h, p);
      })
        ..cancel();
      await expectLater(
          owner.create(Uri.parse('https://localhost:1/'), null, null),
          throwsA(isA<RefreshCancelled>()));
      expect(connects, 0);
      expect(owner.invocations.single.isSettled, isTrue);
    });
  });

  group('TLS1 stalled handshake', () {
    late ServerSocket stall;
    late List<Socket> accepted;
    late List<Completer<void>> peerClosed;

    setUp(() async {
      accepted = [];
      peerClosed = [];
      // Accepts TCP and never answers the ClientHello.
      stall = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      stall.listen((s) {
        accepted.add(s);
        final c = Completer<void>();
        peerClosed.add(c);
        s.listen((_) {}, onDone: () {
          if (!c.isCompleted) c.complete();
        }, onError: (Object _) {
          if (!c.isCompleted) c.complete();
        });
      });
    });

    tearDown(() async {
      for (final s in accepted) {
        s.destroy();
      }
      await stall.close();
    });

    Future<FactoryInvocation> startStalled(ConnectionOwner owner) async {
      final taskF =
          owner.create(Uri.parse('https://127.0.0.1:${stall.port}/'), null, null);
      final inv = owner.invocations.last;
      final task = await taskF;
      task.socket.ignore();
      while (inv.stage != FactoryStage.tlsHandshaking) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      // Let the ClientHello reach the stalled peer.
      while (accepted.isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      return inv;
    }

    test('(a) cancel closes the descriptor and quiesces without the peer',
        () async {
      final owner = ConnectionOwner(context: SecurityContext());
      final inv = await startStalled(owner);
      owner.cancel();
      await expectQuiescent(owner);
      expect(inv.isSettled, isTrue);
      expect(inv.sdkFutureAbandoned, isTrue);
      await expectLater(inv.completer.future, throwsA(isA<RefreshCancelled>()));
      // The peer observes the closure: no further client activity is possible.
      await peerClosed.single.future.timeout(const Duration(seconds: 5));
    });

    test(
        '(b) an SDK handshake future that never settles is abandoned; the '
        'owner still quiesces', () async {
      // The v7.1 counterexample: shutdown(receive)+close() drops the queued
      // readClosed, leaving the handshake future pending forever. Modelled
      // exactly by a handshake future that never completes.
      final never = Completer<RawSecureSocket>();
      final owner = ConnectionOwner(
          rawSecure: (raw, {required host, context}) => never.future);
      final inv = await startStalled(owner);
      // Reproduce the dropped event literally, too.
      owner.cancel();
      await expectQuiescent(owner);
      expect(never.isCompleted, isFalse);
      expect(inv.sdkFutureAbandoned, isTrue);
      await peerClosed.single.future.timeout(const Duration(seconds: 5));
    });

    test(
        'Phase 4 B8: a failed descriptor close is not confirmed closure; '
        'quiescence reports it instead of completing', () async {
      final never = Completer<RawSecureSocket>();
      final owner = ConnectionOwner(
          rawSecure: (raw, {required host, context}) => never.future,
          rawClose: (raw) async {
            await raw.close(); // the fd is really closed; the call reports failure
            throw const SocketException('close failed');
          });
      final inv = await startStalled(owner);
      owner.cancel();
      await expectLater(owner.quiesced().timeout(const Duration(seconds: 5)),
          throwsA(isA<TransportCloseUnconfirmed>()));
      expect(inv.closeFailed, isTrue);
    });

    test('(c) a late handshake error after quiescence is consumed', () async {
      final late = Completer<RawSecureSocket>();
      final owner = ConnectionOwner(
          rawSecure: (raw, {required host, context}) => late.future);
      final inv = await startStalled(owner);
      owner.cancel();
      await expectQuiescent(owner);
      late.completeError(const HandshakeException('late'));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(inv.isSettled, isTrue); // no state change, no unhandled error
    });
  });

  test('TLS1 late handshake success after quiescence is closed, never handed off',
      () async {
    if (!haveOpenssl) return markTestSkipped('openssl unavailable');
    final server = await SecureServerSocket.bind('localhost', 0, serverCtx);
    final serverSockets = <SecureSocket>[];
    final serverDone = Completer<void>();
    server.listen((s) {
      serverSockets.add(s);
      s.listen((_) {}, onDone: () {
        if (!serverDone.isCompleted) serverDone.complete();
      }, onError: (Object _) {
        if (!serverDone.isCompleted) serverDone.complete();
      });
      // The owner's own TCP connection to this port is closed mid-handshake by
      // the cancellation; the server-side handshake error is expected.
    }, onError: (Object _) {});
    final gate = Completer<void>();
    final owner = ConnectionOwner(
        rawSecure: (raw, {required host, context}) async {
      // A real, fully handshaken connection that arrives only after cancel.
      final late = await RawSecureSocket.connect('localhost', server.port,
          context: clientCtx);
      await gate.future;
      return late;
    });
    final taskF =
        owner.create(Uri.parse('https://localhost:${server.port}/'), null, null);
    final inv = owner.invocations.last;
    (await taskF).socket.ignore();
    while (inv.stage != FactoryStage.tlsHandshaking) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    owner.cancel();
    await expectQuiescent(owner);
    gate.complete();
    await serverDone.future.timeout(const Duration(seconds: 5));
    await expectLater(inv.completer.future, throwsA(isA<RefreshCancelled>()));
    for (final s in serverSockets) {
      s.destroy();
    }
    await server.close();
  });

  test('TLS2 cancel before the task-creation future settles', () async {
    final listener = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final peerDone = Completer<void>();
    listener.listen((s) => s.listen((_) {}, onDone: () {
          if (!peerDone.isCompleted) peerDone.complete();
        }));
    final creation = Completer<ConnectionTask<RawSocket>>();
    final owner = ConnectionOwner(rawConnect: (h, p) => creation.future);
    final taskF =
        owner.create(Uri.parse('https://127.0.0.1:${listener.port}/'), null, null);
    // Registered synchronously, before the factory's first await.
    final inv = owner.invocations.single;
    expect(inv.stage, FactoryStage.starting);
    (await taskF).socket.ignore();
    owner.cancel();
    // The slow "DNS" now delivers a real connection task.
    creation.complete(
        await RawSocket.startConnect(InternetAddress.loopbackIPv4, listener.port));
    await expectQuiescent(owner);
    await expectLater(inv.completer.future, throwsA(isA<RefreshCancelled>()));
    await listener.close();
  });

  test('Phase 4c B8: a cancelled hand-off settles only after its socket '
      'subscription cancellation completed', () async {
    if (!haveOpenssl) return markTestSkipped('openssl unavailable');
    final server = await HttpServer.bindSecure('localhost', 0, serverCtx);
    final requestSeen = Completer<void>();
    server.listen((req) {
      // Never responds.
      if (!requestSeen.isCompleted) requestSeen.complete();
    });
    final gate = Completer<void>();
    final owner = ConnectionOwner(
        rawSecure: (raw, {required host, context}) async => _SlowCancelSecure(
            await RawSecureSocket.secure(raw,
                host: host,
                context: clientCtx,
                supportedProtocols: const ['http/1.1']),
            gate));
    final client = clientFor(owner);
    final req =
        await client.postUrl(Uri.parse('https://localhost:${server.port}/t'));
    req.add(utf8.encode('{}'));
    final resF = req.close();
    resF.ignore();
    await requestSeen.future;
    final inv = owner.invocations.single;
    expect(inv.stage, FactoryStage.connected);
    var quiet = false;
    final q = owner.quiesced().then((_) => quiet = true);
    owner.cancel();
    client.close(force: true);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(inv.isSettled, isFalse,
        reason: 'the raw closure alone does not settle the invocation');
    expect(quiet, isFalse);
    gate.complete();
    await q.timeout(const Duration(seconds: 5),
        onTimeout: () => fail('owner did not quiesce'));
    expect(inv.isSettled, isTrue);
    await server.close(force: true);
  });

  test('TLS3 cancel after hand-off destroys the connection', () async {
    if (!haveOpenssl) return markTestSkipped('openssl unavailable');
    final server = await HttpServer.bindSecure('localhost', 0, serverCtx);
    final requestSeen = Completer<void>();
    server.listen((req) {
      // Never responds.
      if (!requestSeen.isCompleted) requestSeen.complete();
    });
    final owner = ConnectionOwner(context: clientCtx);
    final client = clientFor(owner);
    final req =
        await client.postUrl(Uri.parse('https://localhost:${server.port}/t'));
    req.add(utf8.encode('{}'));
    final resF = req.close();
    resF.ignore();
    await requestSeen.future;
    expect(owner.invocations.single.stage, FactoryStage.connected);
    owner.cancel();
    client.close(force: true);
    await expectQuiescent(owner);
    await server.close(force: true);
  });
}
