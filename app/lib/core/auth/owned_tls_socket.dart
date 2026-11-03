import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// ASR design v7.2 §10.1/§10.4 (V1) — operation-owned TLS connections for the
/// coordinator's refresh exchange.
///
/// `SecureSocket.startConnect`'s cancel callback controls only the TCP attempt:
/// once TCP succeeds the winning socket has left the connecting set
/// (socket_patch.dart:1087), so a stalled TLS handshake cannot be terminated
/// through it. `SecureSocket.secure(Socket)` is no better: it detaches the raw
/// socket (`_detachRaw` sets `_raw = null`, socket_patch.dart:2847-2856), after
/// which the plain socket's `destroy()` is a no-op. So the operation builds the
/// connection from parts it owns — `RawSocket.startConnect`, then
/// `RawSecureSocket.secure(raw)` while it keeps the [RawSocket] handle — and
/// exposes the handshaken connection to `HttpClient` through [OwnedTlsSocket].
///
/// Cancellation never relies on an SDK event to settle the handshake future
/// (`shutdown(receive)` only queues a read event that a following `close()`
/// drops, socket_patch.dart:1652-1658; a plain close may reach
/// `_doneHandler → _close`, which never completes it, secure_socket.dart:783-799,
/// 947-950). The owner closes the descriptor, settles its OWN completer with
/// [RefreshCancelled], and abandons any SDK future that is still pending: a late
/// error is consumed and a late socket is closed on arrival, never handed off.
///
/// Quiescence ([ConnectionOwner.quiesced]) is a property of owned resources and
/// confirmed descriptor closure, not of SDK-internal futures.

/// The error an owned connection future settles with once its operation was
/// cancelled. Never carries a cause that could identify the user.
/// An owned descriptor's `close()` failed: closure is not confirmed, so the
/// transport is not quiescent (§10.4). The caller fails closed.
class TransportCloseUnconfirmed implements Exception {
  const TransportCloseUnconfirmed();
  @override
  String toString() => 'TransportCloseUnconfirmed';
}

class RefreshCancelled implements Exception {
  const RefreshCancelled([this.stage = 'unknown']);

  /// The factory stage the cancellation met (diagnostic only).
  final String stage;

  @override
  String toString() => 'RefreshCancelled($stage)';
}

/// Seams for tests: the production values are the real `dart:io` calls.
typedef RawConnect = Future<ConnectionTask<RawSocket>> Function(
    Object host, int port);
typedef RawSecure = Future<RawSecureSocket> Function(RawSocket raw,
    {required String host, SecurityContext? context});
typedef RawClose = Future<void> Function(RawSocket raw);

Future<void> _defaultRawClose(RawSocket raw) => raw.close();

Future<ConnectionTask<RawSocket>> _defaultRawConnect(Object host, int port) =>
    RawSocket.startConnect(host, port);

Future<RawSecureSocket> _defaultRawSecure(RawSocket raw,
        {required String host, SecurityContext? context}) =>
    RawSecureSocket.secure(raw,
        host: host, context: context, supportedProtocols: const ['http/1.1']);

/// Stage of one factory invocation (§10.4 table).
enum FactoryStage {
  starting,
  tcpConnecting,
  tcpConnected,
  tlsHandshaking,
  connected,
  settled,
}

/// One call of the connection factory. Registered synchronously, before the
/// factory's first await, so the owner's resource set is always complete.
class FactoryInvocation {
  FactoryInvocation._(this.id, this._rawClose);

  final RawClose _rawClose;

  final int id;
  FactoryStage stage = FactoryStage.starting;

  /// The op-owned future `HttpClient` awaits (through
  /// `ConnectionTask.fromSocket`). Settled with a connection or with
  /// [RefreshCancelled]/an error — independently of any SDK future.
  final Completer<Socket> completer = Completer<Socket>();

  ConnectionTask<RawSocket>? _tcpTask;

  /// Every raw descriptor this invocation created, with its close future once
  /// closing started. Settlement requires every one of them to be confirmed
  /// closed.
  final List<RawSocket> _raws = [];
  final Map<RawSocket, Future<void>> _closing = {};
  OwnedTlsSocket? _socket;

  /// The SDK future that may never settle after a cancelled handshake
  /// (abandoned, guarded).
  bool sdkFutureAbandoned = false;

  /// Pending SDK-internal futures this invocation is still waiting for that
  /// are NOT abandoned (task-creation, TCP socket). Settlement waits for them.
  int _outstandingSdk = 0;

  bool get isSettled => stage == FactoryStage.settled;

  /// A close that failed is not confirmed closure (§10.4): it is recorded and
  /// [ConnectionOwner.quiesced] reports it instead of completing normally.
  bool closeFailed = false;

  Future<void> _closeRaw(RawSocket raw) =>
      _closing[raw] ??= _rawClose(raw).then<void>((_) {}, onError: (_) {
        closeFailed = true;
      });
}

/// Owns every connection created for ONE refresh operation's `HttpClient`.
///
/// Usage: install [create] as `HttpClient.connectionFactory` (with
/// `findProxy = (_) => 'DIRECT'`, so HttpClient calls it with `(uri, null,
/// null)` and uses the result directly, http_impl.dart:2685-2689).
class ConnectionOwner {
  ConnectionOwner({
    SecurityContext? context,
    RawConnect? rawConnect,
    RawSecure? rawSecure,
    RawClose? rawClose,
  })  : _context = context,
        _rawConnect = rawConnect ?? _defaultRawConnect,
        _rawSecure = rawSecure ?? _defaultRawSecure,
        _rawClose = rawClose ?? _defaultRawClose;

  final SecurityContext? _context;
  final RawConnect _rawConnect;
  final RawSecure _rawSecure;
  final RawClose _rawClose;

  final List<FactoryInvocation> _invocations = [];
  int _nextId = 0;
  bool _cancelled = false;
  final StreamController<void> _changes = StreamController<void>.broadcast(sync: true);

  bool get isCancelled => _cancelled;
  List<FactoryInvocation> get invocations => List.unmodifiable(_invocations);

  /// The `HttpClient.connectionFactory`. Registration and the latch check run
  /// synchronously, before any await.
  Future<ConnectionTask<Socket>> create(
      Uri uri, String? proxyHost, int? proxyPort) {
    final inv = FactoryInvocation._(_nextId++, _rawClose);
    _invocations.add(inv);
    if (proxyHost != null || proxyPort != null || uri.scheme != 'https') {
      // DIRECT https only: a proxy CONNECT or plaintext would be egress this
      // owner does not control.
      _settle(inv, error: const RefreshCancelled('refused'));
      return Future<ConnectionTask<Socket>>.error(
          const RefreshCancelled('refused'));
    }
    if (_cancelled) {
      _settle(inv, error: const RefreshCancelled('starting'));
      return Future<ConnectionTask<Socket>>.error(
          const RefreshCancelled('starting'));
    }
    unawaited(_run(inv, uri.host, uri.hasPort ? uri.port : 443));
    return Future<ConnectionTask<Socket>>.value(ConnectionTask.fromSocket(
        inv.completer.future, () => unawaited(_cancelInvocation(inv))));
  }

  Future<void> _run(FactoryInvocation inv, String host, int port) async {
    // starting: RawSocket.startConnect resolves the host before its task exists.
    final ConnectionTask<RawSocket> task;
    inv._outstandingSdk++;
    try {
      task = await _rawConnect(host, port);
    } catch (e) {
      inv._outstandingSdk--;
      _settle(inv, error: _cancelled ? const RefreshCancelled('starting') : e);
      return;
    }
    inv._outstandingSdk--;
    inv._tcpTask = task;
    inv.stage = FactoryStage.tcpConnecting;
    if (_cancelled) task.cancel();

    final RawSocket raw;
    inv._outstandingSdk++;
    try {
      raw = await task.socket;
    } catch (e) {
      inv._outstandingSdk--;
      _settle(inv,
          error: _cancelled ? const RefreshCancelled('tcpConnecting') : e);
      return;
    }
    inv._outstandingSdk--;
    inv._raws.add(raw);
    inv.stage = FactoryStage.tcpConnected;
    if (_cancelled || inv.isSettled) {
      await inv._closeRaw(raw);
      _settle(inv, error: const RefreshCancelled('tcpConnected'));
      return;
    }

    inv.stage = FactoryStage.tlsHandshaking;
    final handshake = _rawSecure(raw, host: host, context: _context);
    final RawSecureSocket secure;
    try {
      secure = await handshake;
    } catch (e) {
      // A failed or cancelled handshake: the descriptor is ours to close.
      await inv._closeRaw(raw);
      _settle(inv,
          error: _cancelled ? const RefreshCancelled('tlsHandshaking') : e);
      return;
    }
    if (inv.sdkFutureAbandoned || _cancelled || inv.isSettled) {
      // Late success after cancellation: close on arrival, never hand off.
      secure.close().ignore();
      await inv._closeRaw(raw);
      _settle(inv, error: const RefreshCancelled('tlsHandshaking'));
      return;
    }
    late final OwnedTlsSocket socket;
    socket = OwnedTlsSocket._(secure, raw, onClosed: () {
      // Settled only once the descriptor's close AND the socket's own event
      // subscription cancellation have completed.
      unawaited(Future.wait([inv._closeRaw(raw), socket.subscriptionCancelled])
          .then((_) => _settle(inv)));
    });
    inv._socket = socket;
    inv.stage = FactoryStage.connected;
    inv.completer.complete(socket);
    _changes.add(null);
  }

  /// Cancels one invocation (HttpClient's `ConnectionTask.cancel`, or the
  /// owner-wide [cancel]). Performs the §10.4 action for the current stage.
  Future<void> _cancelInvocation(FactoryInvocation inv) async {
    switch (inv.stage) {
      case FactoryStage.settled:
        return;
      case FactoryStage.starting:
        // The task-creation future is still pending; `_run` cancels the task
        // (or closes a delivered socket) when it settles.
        _cancelledInvocation(inv);
        return;
      case FactoryStage.tcpConnecting:
        inv._tcpTask?.cancel();
        _cancelledInvocation(inv);
        return;
      case FactoryStage.tcpConnected:
        _cancelledInvocation(inv);
        for (final raw in inv._raws) {
          await inv._closeRaw(raw);
        }
        _settle(inv, error: const RefreshCancelled('tcpConnected'));
        return;
      case FactoryStage.tlsHandshaking:
        // Close only; the handshake future is abandoned (it may never
        // settle). The owner's completer settles now.
        inv.sdkFutureAbandoned = true;
        _failCompleter(inv, const RefreshCancelled('tlsHandshaking'));
        for (final raw in inv._raws) {
          await inv._closeRaw(raw);
        }
        _settle(inv, error: const RefreshCancelled('tlsHandshaking'));
        return;
      case FactoryStage.connected:
        inv._socket?.destroy();
        for (final raw in inv._raws) {
          await inv._closeRaw(raw);
        }
        _settle(inv);
        return;
    }
  }

  void _cancelledInvocation(FactoryInvocation inv) =>
      _failCompleter(inv, RefreshCancelled(inv.stage.name));

  void _failCompleter(FactoryInvocation inv, Object error) {
    if (!inv.completer.isCompleted) {
      inv.completer.future.ignore();
      inv.completer.completeError(error);
    }
  }

  /// Marks [inv] settled once its completer is settled, every descriptor it
  /// created is confirmed closed, and no non-abandoned SDK future is pending.
  void _settle(FactoryInvocation inv, {Object? error}) {
    if (error != null) _failCompleter(inv, error);
    if (inv.isSettled) return;
    if (!inv.completer.isCompleted) return;
    if (inv._outstandingSdk > 0) return;
    if (inv.stage == FactoryStage.connected && !_cancelled) {
      // A live hand-off settles when its socket is closed (onClosed).
      if (!(inv._socket?.isClosed ?? true)) return;
    }
    for (final raw in inv._raws) {
      if (!inv._closing.containsKey(raw)) return;
    }
    // Phase 4c B8: every path (onClosed, the stage cancel actions) settles only
    // after a handed-off socket's own subscription cancellation completed too.
    final socket = inv._socket;
    if (socket != null && !socket.isClosed) return;
    unawaited(Future.wait([
      ...inv._closing.values,
      if (socket != null) socket.subscriptionCancelled,
    ]).then((_) {
      if (inv.isSettled) return;
      inv.stage = FactoryStage.settled;
      _changes.add(null);
    }));
  }

  /// Sets the latch and runs the cancel action for every invocation.
  void cancel() {
    _cancelled = true;
    for (final inv in List.of(_invocations)) {
      unawaited(_cancelInvocation(inv));
    }
  }

  /// Closes every owned connection (the normal end of an exchange as well as
  /// cancellation): after this, [quiesced] completes once every invocation has
  /// settled.
  void closeAll() => cancel();

  /// Completes when every registered invocation is settled (§10.4 transport
  /// quiescence). Callers must have called [cancel]/[closeAll] first or let
  /// every connection close; a timeout wrapper is not evidence of quiescence.
  Future<void> quiesced() async {
    while (_invocations.any((i) => !i.isSettled)) {
      await _changes.stream.first;
    }
    if (_invocations.any((i) => i.closeFailed)) {
      throw const TransportCloseUnconfirmed();
    }
  }
}

/// A [Socket] over an op-owned [RawSecureSocket] whose underlying [RawSocket]
/// the operation also holds. Implements just what `HttpClient` needs; the
/// conformance test runs a real `HttpClient` against a local TLS server.
class OwnedTlsSocket extends Stream<Uint8List> implements Socket {
  OwnedTlsSocket._(this._secure, this._raw, {required void Function() onClosed})
      : _onClosed = onClosed {
    _controller = StreamController<Uint8List>(
      onPause: () => _secure.readEventsEnabled = false,
      onResume: () => _secure.readEventsEnabled = true,
      onCancel: () {
        if (!_closed) destroy();
      },
    );
    _secure.writeEventsEnabled = false;
    _subscription = _secure.listen(_onEvent,
        onError: _onError, onDone: _onDone, cancelOnError: false);
    _sink = IOSink(_SecureConsumer(this));
  }

  final RawSecureSocket _secure;
  final RawSocket _raw;
  final void Function() _onClosed;
  late final StreamController<Uint8List> _controller;
  late final StreamSubscription<RawSocketEvent> _subscription;

  /// Completes when the event subscription's cancellation has completed (set
  /// when the socket closes; part of transport quiescence, §10.4).
  Future<void> get subscriptionCancelled =>
      _subscriptionCancelled ?? Future<void>.value();
  Future<void>? _subscriptionCancelled;
  late final IOSink _sink;
  final Completer<void> _done = Completer<void>();
  bool _closed = false;

  // Write state for the consumer.
  final List<Uint8List> _pending = [];
  int _pendingOffset = 0;
  Completer<void>? _drained;

  bool get isClosed => _closed;

  void _onEvent(RawSocketEvent event) {
    switch (event) {
      case RawSocketEvent.read:
        final data = _secure.read();
        if (data != null && data.isNotEmpty && !_controller.isClosed) {
          _controller.add(data);
        }
      case RawSocketEvent.write:
        _flushPending();
      case RawSocketEvent.readClosed:
        if (!_controller.isClosed) unawaited(_controller.close());
      case RawSocketEvent.closed:
        _finish();
    }
  }

  void _onError(Object error, StackTrace st) {
    if (!_controller.isClosed) _controller.addError(error, st);
    _finish(error);
  }

  void _onDone() => _finish();

  void _flushPending() {
    while (_pending.isNotEmpty) {
      final chunk = _pending.first;
      final written = _closed
          ? 0
          : _secure.write(chunk, _pendingOffset, chunk.length - _pendingOffset);
      if (_closed) break;
      _pendingOffset += written;
      if (_pendingOffset < chunk.length) {
        _secure.writeEventsEnabled = true;
        return;
      }
      _pending.removeAt(0);
      _pendingOffset = 0;
    }
    if (_pending.isEmpty) {
      final d = _drained;
      _drained = null;
      d?.complete();
    }
  }

  Future<void> _write(List<int> data) {
    if (_closed) return Future<void>.error(const SocketException.closed());
    _pending.add(data is Uint8List ? data : Uint8List.fromList(data));
    _drained ??= Completer<void>();
    final d = _drained!;
    _flushPending();
    return d.future;
  }

  void _finish([Object? error]) {
    if (_closed) return;
    _closed = true;
    _drained?.completeError(error ?? const SocketException.closed());
    _drained?.future.ignore();
    _drained = null;
    _pending.clear();
    _subscriptionCancelled =
        _subscription.cancel().then<void>((_) {}, onError: (_) {});
    if (!_controller.isClosed) unawaited(_controller.close());
    _secure.close().ignore();
    if (!_done.isCompleted) _done.complete();
    _onClosed();
  }

  // ---------------------------------------------------------------- Stream
  @override
  StreamSubscription<Uint8List> listen(void Function(Uint8List event)? onData,
          {Function? onError, void Function()? onDone, bool? cancelOnError}) =>
      _controller.stream.listen(onData,
          onError: onError, onDone: onDone, cancelOnError: cancelOnError);

  // ---------------------------------------------------------------- IOSink
  @override
  Encoding get encoding => _sink.encoding;
  @override
  set encoding(Encoding value) => _sink.encoding = value;
  @override
  void add(List<int> data) => _sink.add(data);
  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      _sink.addError(error, stackTrace);
  @override
  Future<dynamic> addStream(Stream<List<int>> stream) => _sink.addStream(stream);
  @override
  Future<dynamic> flush() => _sink.flush();
  @override
  Future<dynamic> close() => _sink.close();
  @override
  Future<dynamic> get done => _done.future;
  @override
  void write(Object? object) => _sink.write(object);
  @override
  void writeAll(Iterable<Object?> objects, [String separator = '']) =>
      _sink.writeAll(objects, separator);
  @override
  void writeln([Object? object = '']) => _sink.writeln(object);
  @override
  void writeCharCode(int charCode) => _sink.writeCharCode(charCode);

  // ---------------------------------------------------------------- Socket
  @override
  void destroy() {
    if (_closed) return;
    _finish();
    _raw.close().ignore();
  }

  @override
  bool setOption(SocketOption option, bool enabled) =>
      _secure.setOption(option, enabled);
  @override
  Uint8List getRawOption(RawSocketOption option) =>
      _secure.getRawOption(option);
  @override
  void setRawOption(RawSocketOption option) => _secure.setRawOption(option);
  @override
  int get port => _secure.port;
  @override
  int get remotePort => _secure.remotePort;
  @override
  InternetAddress get address => _secure.address;
  @override
  InternetAddress get remoteAddress => _secure.remoteAddress;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('OwnedTlsSocket: ${invocation.memberName}');
}

class _SecureConsumer implements StreamConsumer<List<int>> {
  _SecureConsumer(this._socket);
  final OwnedTlsSocket _socket;

  @override
  Future<dynamic> addStream(Stream<List<int>> stream) {
    final completer = Completer<void>();
    late StreamSubscription<List<int>> sub;
    sub = stream.listen((data) {
      sub.pause(_socket._write(data).catchError((Object e) {
        sub.cancel();
        if (!completer.isCompleted) completer.completeError(e);
      }));
    }, onError: (Object e, StackTrace st) {
      if (!completer.isCompleted) completer.completeError(e, st);
    }, onDone: () {
      if (!completer.isCompleted) completer.complete();
    }, cancelOnError: true);
    return completer.future;
  }

  @override
  Future<dynamic> close() async {
    if (!_socket._closed) _socket._secure.shutdown(SocketDirection.send);
  }
}
