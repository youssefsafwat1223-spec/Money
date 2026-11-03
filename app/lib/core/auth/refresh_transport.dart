import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'owned_tls_socket.dart';

/// ASR design v7.2 §10 — the coordinator's refresh exchange.
///
/// One instance carries exactly ONE `grant_type=refresh_token` request on a
/// dedicated `HttpClient` whose only connection source is an op-owned
/// [ConnectionOwner] (DIRECT, no proxy CONNECT, no reuse, no redirects). It is
/// not `http.Client`, `GatedHttpClient` or `AbortableRequest`: the gate denies
/// every other refresh request (§3.1), and this exchange is admitted by the
/// coordinator's own refresh ticket instead.
///
/// The phases are separate so the coordinator can interleave its durable
/// bookkeeping exactly as §10.3 orders it:
///   [open]  — connection establishment (egress; only after P_admit);
///   [send]  — called synchronously right after P_send: the credential bytes are
///             added and the response is read (body capped);
///   [cancel]/[quiesced] — §10.4.
/// The phases of one refresh exchange as the coordinator drives them (§10.3).
abstract class RefreshChannel {
  Future<void> open();
  Future<RefreshHttpResult> send(String refreshToken);
  bool get sent;
  void cancel();
  void close();
  Future<void> quiesced();
}

class RefreshExchange implements RefreshChannel {
  RefreshExchange({
    required this.tokenUri,
    required String apiKey,
    SecurityContext? context,
    ConnectionOwner? owner,
    this.maxBodyBytes = 64 * 1024,
  })  : _apiKey = apiKey,
        owner = owner ?? ConnectionOwner(context: context) {
    _client = HttpClient()
      ..findProxy = ((_) => 'DIRECT')
      ..connectionFactory = this.owner.create
      ..idleTimeout = const Duration(seconds: 1)
      // HttpClient advertises gzip by default. Decode it before the bounded
      // body read and JSON parsing; compressed bytes are not a JSON failure.
      ..autoUncompress = true;
  }

  /// `<origin>/auth/v1/token?grant_type=refresh_token` (the gate's
  /// `authTokenPath()`).
  final Uri tokenUri;
  final String _apiKey;
  final ConnectionOwner owner;
  final int maxBodyBytes;
  late final HttpClient _client;

  HttpClientRequest? _request;
  StreamSubscription<List<int>>? _body;
  Completer<void>? _bodyDone;
  bool _cancelled = false;
  bool _sent = false;
  int _pendingFutures = 0;
  final StreamController<void> _changes =
      StreamController<void>.broadcast(sync: true);

  bool get isCancelled => _cancelled;

  /// True once [send] handed the credential bytes to the request.
  @override
  bool get sent => _sent;

  /// Connects (DNS/TCP/TLS through the owner's factory) and returns once the
  /// request object exists. No credential byte is written here.
  @override
  Future<void> open() async {
    if (_cancelled) throw const RefreshCancelled('open');
    _pendingFutures++;
    try {
      final req = await _client.postUrl(tokenUri);
      if (_cancelled) {
        req.abort(const RefreshCancelled('open'));
        throw const RefreshCancelled('open');
      }
      req
        ..followRedirects = false
        ..maxRedirects = 0
        ..persistentConnection = false
        ..headers.set('apikey', _apiKey)
        ..headers.set(HttpHeaders.authorizationHeader, 'Bearer $_apiKey')
        ..headers.contentType = ContentType.json;
      _request = req;
    } finally {
      _pendingFutures--;
      _changes.add(null);
    }
  }

  /// Adds the credential body and reads the response. The synchronous part (up
  /// to the first await) performs the `add`, so the caller's P_send check and
  /// this call form one synchronous block (§9.4).
  @override
  Future<RefreshHttpResult> send(String refreshToken) {
    final req = _request;
    if (req == null || _cancelled || _sent) {
      return Future.error(const RefreshCancelled('send'));
    }
    _sent = true;
    req.add(utf8.encode(jsonEncode({'refresh_token': refreshToken})));
    return _read(req.close());
  }

  Future<RefreshHttpResult> _read(Future<HttpClientResponse> responseFuture) async {
    _pendingFutures++;
    try {
      final res = await responseFuture;
      if (_cancelled) throw const RefreshCancelled('response');
      final bytes = <int>[];
      final done = _bodyDone = Completer<void>();
      _body = res.listen((chunk) {
        bytes.addAll(chunk);
        if (bytes.length > maxBodyBytes) {
          final body = _body;
          if (body != null) _trackCancel(body.cancel());
          if (!done.isCompleted) {
            done.completeError(const RefreshBodyTooLarge());
          }
        }
      }, onError: (Object e, StackTrace st) {
        if (!done.isCompleted) done.completeError(e, st);
      }, onDone: () {
        if (!done.isCompleted) done.complete();
      }, cancelOnError: true);
      await done.future;
      _body = null;
      _bodyDone = null;
      if (_cancelled) throw const RefreshCancelled('body');
      Object? json;
      try {
        json = jsonDecode(utf8.decode(bytes));
      } on FormatException {
        json = null;
      }
      return RefreshHttpResult(
          statusCode: res.statusCode,
          json: json,
          isRedirect: res.statusCode >= 300 && res.statusCode < 400);
    } finally {
      _pendingFutures--;
      _changes.add(null);
    }
  }

  /// §10.4: latch, abort the request while its response is pending, cancel the
  /// body subscription, close the client and every owned connection.
  @override
  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    _request?.abort(const RefreshCancelled('cancel'));
    final body = _body;
    _body = null;
    if (body != null) _trackCancel(body.cancel());
    // A cancelled subscription never reports done: settle the read ourselves.
    final bodyDone = _bodyDone;
    _bodyDone = null;
    if (bodyDone != null && !bodyDone.isCompleted) {
      bodyDone.completeError(const RefreshCancelled('body'));
    }
    _client.close(force: true);
    owner.cancel();
  }

  /// Normal end of an exchange: releases every owned resource.
  @override
  void close() {
    _client.close(force: true);
    owner.closeAll();
  }

  /// Body-subscription cancellations started by this exchange; quiescence
  /// waits for each to complete (§10.4: cancellation work is accounted for).
  final List<Future<void>> _cancels = [];

  void _trackCancel(Future<void> cancel) =>
      _cancels.add(cancel.then<void>((_) {}, onError: (_) {}));

  /// Transport quiescence (§10.4): the owner's invocations are settled, the
  /// request/response/body futures this exchange awaits have settled and every
  /// subscription cancellation has completed. Call [cancel] or [close] first.
  /// Throws [TransportCloseUnconfirmed] when an owned descriptor's closure is
  /// not confirmed (only after everything else has settled).
  @override
  Future<void> quiesced() async {
    Object? unconfirmed;
    try {
      await owner.quiesced();
    } on TransportCloseUnconfirmed catch (e) {
      unconfirmed = e;
    }
    while (_pendingFutures > 0) {
      await _changes.stream.first;
    }
    await Future.wait(_cancels);
    if (unconfirmed != null) throw unconfirmed;
  }
}

/// The raw outcome of one exchange; validation (§10.6) is the coordinator's.
class RefreshHttpResult {
  const RefreshHttpResult(
      {required this.statusCode, required this.json, required this.isRedirect});

  final int statusCode;

  /// The decoded JSON body, or null when it is not JSON.
  final Object? json;
  final bool isRedirect;
}

class RefreshBodyTooLarge implements Exception {
  const RefreshBodyTooLarge();
  @override
  String toString() => 'RefreshBodyTooLarge';
}
