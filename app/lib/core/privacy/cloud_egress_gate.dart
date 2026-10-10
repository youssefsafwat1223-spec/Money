import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../../features/capture/services/native_capture_bridge.dart';
import '../backend/supabase_config.dart';
import '../security/secure_storage_options.dart';
import 'consent_authority.dart';

/// Astra G / C.4: the durable shared denial state and the ONE admission gate.
///
/// ## The record
/// `cloud_egress_state = {state: ON|DISABLING|OFF, owner_uid,
/// transition_generation, reserved_version}`, one per owner, kept in
/// secure storage AND an app-support file (and, on iOS, a third copy in the
/// Keychain shared group / App Group file through the native bridge methods
/// `setCloudEgressState` / `getCloudEgressState`). Any reader that finds
/// DISABLING, OFF, unreadable, corrupt or conflicting state denies egress.
///
/// ## Merge (the only reconciliation rule set)
///  * a valid DISABLING/OFF record in ANY store overrides its absence (or an ON
///    record) in the others; among restrictive records the higher generation
///    wins and, at equal generation, OFF (the commit) wins over DISABLING;
///  * a corrupt or unreadable store makes the whole readout UNCERTAIN: egress is
///    denied until a later read is clean or an explicit enable/disable rewrites
///    every store;
///  * a record for owner A is never applied to owner B and is never dropped by
///    B's writes (every write re-emits the merged records of all owners).
///
/// ## Admission
/// Every Dart network request (the [GatedHttpClient] used by every transport and
/// by the Supabase client, plus the service gates) calls [admit]. It takes a
/// short in-process lock, reads the durable state and registers the request in
/// the in-flight set. [beginDisabling] writes DISABLING under the SAME lock, so
/// no request newly passes admission after DISABLING began. The only request
/// admitted in DISABLING is the one-shot revoke ([runRevoke]).
///
/// ## Astra H2: the Cloud-OFF invariant
/// Cloud OFF blocks all automatic, background and application-data network
/// egress. The only operations permitted while OFF are explicit user-initiated
/// sign-in, re-authentication, delete-account and cancel-delete, with their
/// strictly necessary authentication exchanges. They do not enable Cloud and
/// authorize nothing else. They run through [runAccountControl], an
/// operation-scoped, time-boxed, endpoint-allowlisted capability (see
/// [AccountControlGrant] and [kAccountControlAllowlist]).
///
/// UNKNOWN / MISSING / CORRUPT state is OFF / UNRESOLVED / DENY:
///  * a process-level `resolved` latch: until bootstrap finished the egress
///    reconciliation ([markResolved]) admission denies EVERYTHING, grants
///    included;
///  * an absent record is not ON: [permits] is false, and only an explicit
///    enable ([enable]) writes ON.
///
/// Requests admitted before DISABLING may complete, but a response that returns
/// after the in-process epoch advanced is DISCARDED (an [EgressDeniedException]
/// reaches the caller), so it can have no state effect. [drain] waits for the
/// in-flight set (bounded) and cancels what is still running. Bytes already
/// transmitted cannot be recalled.
enum EgressState {
  on('ON'),
  disabling('DISABLING'),
  off('OFF');

  const EgressState(this.wire);
  final String wire;

  static EgressState? parse(Object? raw) {
    for (final s in values) {
      if (s.wire == raw) return s;
    }
    return null;
  }
}

@immutable
class CloudEgressRecord {
  const CloudEgressRecord({
    required this.state,
    required this.ownerUid,
    required this.transitionGeneration,
    required this.reservedVersion,
  });

  final EgressState state;

  /// '' for the signed-out scope.
  final String ownerUid;
  final int transitionGeneration;
  final int reservedVersion;

  bool get restrictive => state != EgressState.on;

  Map<String, Object?> toJson() => {
        'state': state.wire,
        'owner_uid': ownerUid,
        'transition_generation': transitionGeneration,
        'reserved_version': reservedVersion,
      };

  /// Null when [raw] is not a well-formed record (the slot is then corrupt).
  static CloudEgressRecord? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final state = EgressState.parse(raw['state']);
    final owner = raw['owner_uid'];
    final gen = raw['transition_generation'];
    final version = raw['reserved_version'];
    if (state == null || owner is! String || gen is! int || version is! int) {
      return null;
    }
    return CloudEgressRecord(
      state: state,
      ownerUid: owner,
      transitionGeneration: gen,
      reservedVersion: version,
    );
  }

  CloudEgressRecord copyWith({
    EgressState? state,
    int? transitionGeneration,
    int? reservedVersion,
  }) =>
      CloudEgressRecord(
        state: state ?? this.state,
        ownerUid: ownerUid,
        transitionGeneration: transitionGeneration ?? this.transitionGeneration,
        reservedVersion: reservedVersion ?? this.reservedVersion,
      );

  @override
  bool operator ==(Object other) =>
      other is CloudEgressRecord &&
      other.state == state &&
      other.ownerUid == ownerUid &&
      other.transitionGeneration == transitionGeneration &&
      other.reservedVersion == reservedVersion;

  @override
  int get hashCode =>
      Object.hash(state, ownerUid, transitionGeneration, reservedVersion);
}

enum SlotStatus { absent, value, corrupt, unreadable }

class SlotRead {
  const SlotRead(this.status, [this.raw]);
  final SlotStatus status;
  final String? raw;
}

/// One durable string slot. Implemented over secure storage and over a file.
abstract class DurableSlot {
  Future<SlotRead> read();
  Future<void> write(String value);
  Future<void> delete();
}

class SecureStorageSlot implements DurableSlot {
  SecureStorageSlot(this._storage, this._key);
  final FlutterSecureStorage _storage;
  final String _key;

  @override
  Future<SlotRead> read() async {
    try {
      final v = await _storage.read(key: _key);
      return v == null
          ? const SlotRead(SlotStatus.absent)
          : SlotRead(SlotStatus.value, v);
    } catch (_) {
      return const SlotRead(SlotStatus.unreadable);
    }
  }

  @override
  Future<void> write(String value) => _storage.write(key: _key, value: value);

  @override
  Future<void> delete() => _storage.delete(key: _key);
}

class FileSlot implements DurableSlot {
  FileSlot(this._directory, this._name);
  final Future<Directory> Function() _directory;
  final String _name;

  Future<File> _file() async => File('${(await _directory()).path}/$_name');

  @override
  Future<SlotRead> read() async {
    try {
      final f = await _file();
      if (!await f.exists()) return const SlotRead(SlotStatus.absent);
      return SlotRead(SlotStatus.value, await f.readAsString());
    } catch (_) {
      return const SlotRead(SlotStatus.unreadable);
    }
  }

  @override
  Future<void> write(String value) async {
    final f = await _file();
    await f.writeAsString(value, flush: true);
  }

  @override
  Future<void> delete() async {
    final f = await _file();
    if (await f.exists()) await f.delete();
  }
}

/// The iOS third copy (Keychain shared group + App Group file), written by the
/// native side. Native records are PER OWNER: a read names the owner, a write
/// affects only that owner. `unavailable` is any bridge failure, a null answer
/// on iOS or an `uncertain` snapshot, and is fail-closed.
class NativeEgressSlot {
  const NativeEgressSlot({required this.read, required this.write});

  /// Null = no record for [owner]. Throws when the native store is unavailable,
  /// corrupt, unreadable or uncertain.
  final Future<CloudEgressRecord?> Function(String owner) read;
  final Future<void> Function(CloudEgressRecord record) write;

  static NativeEgressSlot? platformDefault() {
    if (!NativeCaptureBridge.hasNativeQueue) return null;
    return NativeEgressSlot(
      read: (owner) async {
        final snap =
            await NativeCaptureBridge.getCloudEgressState(ownerUid: owner);
        if (snap == null || snap.uncertain) {
          throw const FormatException('native_egress_uncertain');
        }
        if (owner.isEmpty) {
          if (snap.status != CloudEgressStatus.ownerless) {
            throw const FormatException('native_ownerless_unverified');
          }
          return null;
        }
        if (snap.status == CloudEgressStatus.unset) return null;
        final state = EgressState.parse(snap.state);
        final generation = snap.transitionGeneration;
        final reserved = snap.reservedVersion;
        if (snap.status != CloudEgressStatus.record ||
            state == null ||
            generation == null ||
            reserved == null || generation < 0 || reserved < 0 ||
            snap.ownerUid != owner) {
          throw const FormatException('native_egress_corrupt');
        }
        return CloudEgressRecord(
          state: state,
          ownerUid: owner,
          transitionGeneration: generation,
          reservedVersion: reserved,
        );
      },
      write: (r) => NativeCaptureBridge.setCloudEgressState(
        state: r.state.wire,
        ownerUid: r.ownerUid,
        transitionGeneration: r.transitionGeneration,
        reservedVersion: r.reservedVersion,
      ),
    );
  }
}

/// The merged view of every store.
class EgressReadout {
  const EgressReadout(this.records, this.problems);

  /// Per owner, after the merge.
  final Map<String, CloudEgressRecord> records;

  /// Names of the stores that were corrupt or unreadable (never contents).
  final List<String> problems;

  bool get uncertain => problems.isNotEmpty;
}

class EgressWriteResult {
  const EgressWriteResult(this.succeeded, this.attempted);
  final int succeeded;
  final int attempted;
  bool get any => succeeded > 0;
  bool get all => succeeded == attempted && attempted > 0;
}

class CloudEgressStore {
  CloudEgressStore({
    required DurableSlot secure,
    required DurableSlot file,
    NativeEgressSlot? native,
  })  : _secure = secure,
        _file = file,
        _native = native;

  factory CloudEgressStore.platform({
    FlutterSecureStorage? storage,
    Future<Directory> Function()? directory,
    NativeEgressSlot? native,
    bool useNativeDefault = true,
  }) =>
      CloudEgressStore(
        secure: SecureStorageSlot(
            storage ?? SecureStorageOptions.storage, kSecureKey),
        file: FileSlot(directory ?? getApplicationSupportDirectory, kFileName),
        native: native ??
            (useNativeDefault ? NativeEgressSlot.platformDefault() : null),
      );

  /// `qirsh.` prefix so the session wipe keeps it.
  static const kSecureKey = 'qirsh.cloud_egress_state.v1';
  static const kFileName = 'cloud_egress_state.v1';

  final DurableSlot _secure;
  final DurableSlot _file;
  final NativeEgressSlot? _native;

  static Map<String, CloudEgressRecord>? _parseEnvelope(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map || decoded['v'] != 1 || decoded['records'] is! Map) {
        return null;
      }
      final out = <String, CloudEgressRecord>{};
      for (final e in (decoded['records'] as Map).entries) {
        final rec = CloudEgressRecord.fromJson(e.value);
        if (rec == null || e.key is! String || rec.ownerUid != e.key) {
          return null;
        }
        out[e.key as String] = rec;
      }
      return out;
    } catch (_) {
      return null;
    }
  }

  static String _envelope(Map<String, CloudEgressRecord> records) =>
      jsonEncode({
        'v': 1,
        'records': {for (final e in records.entries) e.key: e.value.toJson()},
      });

  Future<EgressReadout> read({String? owner}) async {
    final problems = <String>[];
    final layers = <Map<String, CloudEgressRecord>>[];

    Future<void> slot(String name, DurableSlot s) async {
      final r = await s.read();
      switch (r.status) {
        case SlotStatus.absent:
          return;
        case SlotStatus.unreadable:
        case SlotStatus.corrupt:
          problems.add(name);
        case SlotStatus.value:
          final parsed = _parseEnvelope(r.raw!);
          if (parsed == null) {
            problems.add(name);
          } else {
            layers.add(parsed);
          }
      }
    }

    await slot('secure', _secure);
    await slot('file', _file);
    final native = _native;
    if (native != null) {
      // Native records are per owner: ask for the requested owner and every
      // owner the Dart stores know about (a DISABLING marker must be found).
      final owners = {
        if (owner != null) owner,
        for (final l in layers) ...l.keys,
      };
      if (owners.isEmpty) owners.add('');
      for (final o in owners) {
        try {
          final rec = await native.read(o);
          if (rec != null) layers.add({rec.ownerUid: rec});
        } catch (_) {
          problems.add('native');
          break;
        }
      }
    }
    return EgressReadout(_merge(layers), problems);
  }

  /// See the class docs of [CloudEgressGate] for the rules.
  static Map<String, CloudEgressRecord> _merge(
      List<Map<String, CloudEgressRecord>> layers) {
    final byOwner = <String, List<CloudEgressRecord>>{};
    for (final layer in layers) {
      for (final r in layer.values) {
        byOwner.putIfAbsent(r.ownerUid, () => []).add(r);
      }
    }
    int rank(EgressState s) => s == EgressState.off ? 1 : 0;
    return {
      for (final e in byOwner.entries)
        e.key: () {
          final restrictive = e.value.where((r) => r.restrictive).toList();
          final pool = restrictive.isNotEmpty ? restrictive : e.value;
          pool.sort((a, b) {
            final g = b.transitionGeneration.compareTo(a.transitionGeneration);
            return g != 0 ? g : rank(b.state).compareTo(rank(a.state));
          });
          return pool.first;
        }(),
    };
  }

  /// Writes [record] for its owner into EVERY store, re-emitting the merged
  /// records of all other owners (a B write never drops A's marker).
  Future<EgressWriteResult> write(CloudEgressRecord record) async {
    final merged = {
      ...(await read(owner: record.ownerUid)).records,
      record.ownerUid: record
    };
    final body = _envelope(merged);
    var ok = 0;
    var attempted = 2;
    try {
      await _secure.write(body);
      ok++;
    } catch (_) {}
    try {
      await _file.write(body);
      ok++;
    } catch (_) {}
    final native = _native;
    if (native != null) {
      attempted++;
      try {
        await native.write(record);
        ok++;
      } catch (_) {}
    }
    return EgressWriteResult(ok, attempted);
  }
}

/// Thrown into callers whose request was refused, cancelled or discarded.
/// A [http.ClientException] on purpose, so every transport and the Supabase
/// client treat it as an ordinary (retryable) network failure.
class EgressDeniedException extends http.ClientException {
  EgressDeniedException(this.reason) : super('egress_denied:$reason');
  final String reason;
}

class EgressWriteFailedException implements Exception {
  const EgressWriteFailedException(this.what);
  final String what;
  @override
  String toString() => 'EgressWriteFailedException($what)';
}

enum EgressGrantKind { accountControl, revoke }

/// The ONLY operations allowed to reach the network while Cloud is OFF
/// (Astra H2.1). They never enable Cloud and never widen any consent.
enum AccountControlOp { signIn, reauthenticate, deleteAccount, cancelDelete }

/// One exact endpoint: method + path (+ the one permitted `grant_type` query).
/// Anything else (another path, another query key, another method) is denied.
@immutable
class AccountControlEndpoint {
  const AccountControlEndpoint(this.method, this.path, {this.grantType});
  final String method;

  /// Relative to the configured Supabase URL.
  final String path;

  /// When set, the query must be EXACTLY `grant_type=<this>`; when null the
  /// query must be empty.
  final String? grantType;

  bool matches(
      String requestMethod, String relativePath, Map<String, String> q) {
    if (requestMethod.toUpperCase() != method || relativePath != path) {
      return false;
    }
    if (grantType == null) return q.isEmpty;
    return q.length == 1 && q['grant_type'] == grantType;
  }

  @override
  String toString() =>
      '$method $path${grantType == null ? '' : '?grant_type=$grantType'}';
}

/// The exact per-op OFF allowlist, derived from the app's real code paths and
/// the pinned package sources (gotrue 2.21.0, supabase 2.12.2, postgrest 2.7.1):
///
///  * `signIn` / `reauthenticate` (identical: the app has ONE interactive
///    sign-in surface, `SupabaseAuthService`, also used when a session expired):
///    Google/Apple `auth.signInWithIdToken` -> POST /auth/v1/token?grant_type=id_token
///    (gotrue_client.dart:422-434); email `signInWithOtp(email:)` -> POST
///    /auth/v1/otp (:470-500); `verifyOTP` -> POST /auth/v1/verify (:577-585).
///  * `deleteAccount` / `cancelDelete`: `rpc('request_account_deletion')` /
///    `rpc('cancel_account_deletion')` -> POST /rest/v1/rpc/<fn> (postgrest.dart:118;
///    POST because `get` defaults false), PLUS the strictly necessary
///    POST /auth/v1/token?grant_type=refresh_token that
///    `SupabaseClient._getAccessToken` (supabase_client.dart:253) issues when the
///    stored access token is expired. That refresh is allowed ONLY inside these
///    two ops.
/// `/auth/v1/user`, `/auth/v1/logout`, PostgREST tables, other RPCs,
/// functions, storage and realtime are NOT on any list.
const Map<AccountControlOp, List<AccountControlEndpoint>>
    kAccountControlAllowlist = {
  AccountControlOp.signIn: _signInEndpoints,
  AccountControlOp.reauthenticate: _signInEndpoints,
  AccountControlOp.deleteAccount: [
    AccountControlEndpoint('POST', '/rest/v1/rpc/request_account_deletion'),
    AccountControlEndpoint('POST', '/auth/v1/token',
        grantType: 'refresh_token'),
  ],
  AccountControlOp.cancelDelete: [
    AccountControlEndpoint('POST', '/rest/v1/rpc/cancel_account_deletion'),
    AccountControlEndpoint('POST', '/auth/v1/token',
        grantType: 'refresh_token'),
  ],
};

const List<AccountControlEndpoint> _signInEndpoints = [
  AccountControlEndpoint('POST', '/auth/v1/token', grantType: 'id_token'),
  AccountControlEndpoint('POST', '/auth/v1/otp'),
  AccountControlEndpoint('POST', '/auth/v1/verify'),
];

/// Default lifetime of an account-control grant, on a MONOTONIC clock.
///
/// Why 30 s: the longest legitimate op is delete/cancel with an expired access
/// token = one refresh exchange + one RPC, sequential. gotrue itself bounds a
/// refresh's retry window at 30 s (`Constants.autoRefreshTickDuration`), and a
/// mobile HTTPS exchange normally takes a few seconds. 30 s covers that with
/// margin; anything longer would only widen the window in which a forgotten
/// zone timer could act. The grant starts immediately BEFORE the Supabase
/// exchange (after any native Google/Apple UI returned) and ends in `finally`.
const Duration kAccountControlTtl = Duration(seconds: 30);

/// One operation-scoped grant. Admission requires [active] (not ended, not
/// expired), the configured Supabase host and an endpoint on the op's list.
class AccountControlGrant {
  AccountControlGrant._(this.op, this.id, this.ttl, this._now)
      : _startedAt = _now();

  final AccountControlOp op;
  final int id;
  final Duration ttl;
  final Duration Function() _now;
  final Duration _startedAt;
  bool _ended = false;

  bool get active => !_ended && (_now() - _startedAt) < ttl;

  void _end() => _ended = true;

  /// Why [uri]/[method] is outside this grant, or null when it is inside.
  String? scopeViolation(String method, Uri uri, String supabaseUrl) {
    final base = Uri.tryParse(supabaseUrl);
    if (base == null || base.host.isEmpty) return 'grant_host';
    if (uri.scheme != base.scheme ||
        uri.host != base.host ||
        uri.port != base.port ||
        uri.userInfo.isNotEmpty) {
      return 'grant_host';
    }
    final prefix = base.path.endsWith('/')
        ? base.path.substring(0, base.path.length - 1)
        : base.path;
    if (!uri.path.startsWith(prefix)) return 'grant_endpoint';
    final relative = uri.path.substring(prefix.length);
    for (final e in kAccountControlAllowlist[op]!) {
      if (e.matches(method, relative, uri.queryParameters)) return null;
    }
    return 'grant_endpoint';
  }
}

/// What the transport asks to send (method + URL only, never the body).
@immutable
class AdmissionRequest {
  const AdmissionRequest(this.method, this.url);
  final String method;
  final Uri url;
}

/// A per-call exception to the persistent gate, carried in the [Zone] so the
/// transport can see it. Only two exist: the one-shot revoke (DISABLING only)
/// and an operation-scoped account-control grant (never automatic traffic).
class EgressGrant {
  EgressGrant.accountControl(AccountControlGrant this.control)
      : kind = EgressGrantKind.accountControl,
        owner = null,
        generation = null;
  const EgressGrant.revoke(
      {required String this.owner, required int this.generation})
      : kind = EgressGrantKind.revoke,
        control = null;

  final EgressGrantKind kind;
  final String? owner;
  final int? generation;
  final AccountControlGrant? control;
}

/// One admitted request.
class EgressTicket {
  EgressTicket._(this.owner, this.epoch, this.grant, this.request);
  final String owner;
  final int epoch;
  final EgressGrant? grant;
  final AdmissionRequest? request;
  final Completer<void> _cancel = Completer<void>();
  bool _released = false;

  /// Completes when [CloudEgressGate.drain] gave up waiting for this request.
  Future<void> get cancelled => _cancel.future;
  bool get isCancelled => _cancel.isCompleted;
}

/// The frozen inputs of one DISABLING transition (C.4).
@immutable
class DisableFreeze {
  const DisableFreeze({
    required this.owner,
    required this.transitionGeneration,
    required this.reservedVersion,
  });
  final String owner;
  final int transitionGeneration;
  final int reservedVersion;

  EgressGrant get revokeGrant =>
      EgressGrant.revoke(owner: owner, generation: transitionGeneration);

  CloudEgressRecord record(EgressState state) => CloudEgressRecord(
        state: state,
        ownerUid: owner,
        transitionGeneration: transitionGeneration,
        reservedVersion: reservedVersion,
      );
}

class DrainResult {
  const DrainResult({required this.waited, required this.cancelled});
  final bool waited;
  final int cancelled;
}

class _Mutex {
  Future<void> _tail = Future<void>.value();

  Future<T> synchronized<T>(Future<T> Function() body) async {
    final prev = _tail;
    final done = Completer<void>();
    _tail = done.future;
    await prev;
    try {
      return await body();
    } finally {
      done.complete();
    }
  }
}

class CloudEgressGate {
  CloudEgressGate({
    CloudEgressStore? store,
    Future<String?> Function()? activeOwner,
    this.drainTimeout = const Duration(seconds: 5),
    this.nativeMaxWait = const Duration(seconds: 10),
    this.nativePoll = const Duration(milliseconds: 200),
    Future<({int count, DateTime? latestDeadline})?> Function(String owner)?
        nativeInflight,
    bool resolved = false,
    String Function()? supabaseUrl,
    this.accountControlTtl = kAccountControlTtl,
    Duration Function()? monotonic,
  })  : _nativeInflight = nativeInflight,
        _store = store,
        _activeOwner = activeOwner,
        _resolved = resolved,
        _supabaseUrl = supabaseUrl ?? (() => SupabaseConfig.url),
        _monotonic = monotonic ?? _processClock;

  static final Stopwatch _processStopwatch = Stopwatch()..start();
  static Duration _processClock() => _processStopwatch.elapsed;

  /// The process-wide gate. Bootstrap configures [activeOwner]; tests replace it.
  static CloudEgressGate instance = CloudEgressGate();

  static const Symbol _grantKey = #qirshEgressGrant;

  final Duration drainTimeout;

  /// Lifetime of one account-control grant (monotonic clock).
  final Duration accountControlTtl;
  final Duration Function() _monotonic;
  final String Function() _supabaseUrl;
  int _grantSeq = 0;
  bool _resolved;

  /// H2.3: false until bootstrap completed the egress reconciliation. While
  /// false admission denies EVERYTHING (grants and the revoke included) and
  /// [permits] is false.
  bool get isResolved => _resolved;
  void markResolved() => _resolved = true;

  /// Fired whenever the synchronous permit mirror changes (Sentry, ads,
  /// banners follow it).
  final ValueNotifier<bool> permitNotifier = ValueNotifier<bool>(false);

  /// Upper bound on waiting for native extension uploads already admitted.
  final Duration nativeMaxWait;
  final Duration nativePoll;
  final Future<({int count, DateTime? latestDeadline})?> Function(String owner)?
      _nativeInflight;
  CloudEgressStore? _store;
  Future<String?> Function()? _activeOwner;

  CloudEgressStore get store => _store ??= CloudEgressStore.platform();

  /// The replica owner the request on hand belongs to (null = signed out).
  void configureActiveOwner(Future<String?> Function() activeOwner) =>
      _activeOwner = activeOwner;

  /// Called after every state change (auto-refresh policy, sync mirror).
  Future<void> Function(bool permitsNetwork)? onPermitChanged;

  final _Mutex _lock = _Mutex();
  final Set<EgressTicket> _inFlight = {};
  Completer<void>? _idle;
  int _epoch = 0;
  bool _permitMirror = false;

  /// In-process transition epoch (P4). Advanced SYNCHRONOUSLY at the start of a
  /// disable, an enable, an account transition or a sign-out; every async
  /// mutation captures it and re-checks it before it writes.
  int get epoch => _epoch;
  int advanceEpoch() => ++_epoch;

  int get inFlightCount => _inFlight.length;

  /// Synchronous best-effort mirror of "this process may fetch (images)". False
  /// until a clean read says ON for the active owner; false whenever denied.
  bool get permitsNetworkSync =>
      _permitMirror && _resolved && !ConsentAuthority.egressFrozen;

  Future<String> _owner(String? explicit) async {
    if (explicit != null) return explicit;
    try {
      final configured = _activeOwner;
      if (configured != null) return await configured() ?? '';
      // Unconfigured (a background path): AppSession's owner marker, read raw.
      return await SecureStorageOptions.storage
              .read(key: 'local_data_owner_uid') ??
          '';
    } catch (_) {
      return '';
    }
  }

  /// The merged durable view for [owner] (default: the active owner).
  Future<EgressView> view({String? owner}) async {
    final o = await _owner(owner);
    final readout = await store.read(owner: o);
    return EgressView(o, readout);
  }

  /// Service-level check: true ONLY for a resolved process, a clean read and a
  /// durable ON record for the active owner. DISABLING / OFF / uncertain /
  /// frozen / ABSENT (never explicitly enabled, e.g. an upgrade) / unresolved
  /// all answer false (Astra H2.2).
  Future<bool> permits({String? owner}) async {
    if (!_resolved || ConsentAuthority.egressFrozen) return false;
    final v = await view(owner: owner);
    return !v.uncertain && v.record?.state == EgressState.on;
  }

  /// H2.5 `url_launcher`: whether the app may hand [uri] to the OS browser. An
  /// external launch is user-visible network egress (the OS fetches the page), so
  /// it follows [permits]. The only exception is an allowlisted host inside an
  /// ACTIVE account-control grant (the configured Supabase host); no other
  /// exception exists.
  Future<bool> mayLaunchExternal(Uri uri) async {
    if (await permits()) return true;
    final control = (Zone.current[_grantKey] as EgressGrant?)?.control;
    if (control == null ||
        !control.active ||
        !_resolved ||
        ConsentAuthority.egressFrozen) {
      return false;
    }
    final base = Uri.tryParse(_supabaseUrl());
    return base != null &&
        base.host.isNotEmpty &&
        uri.scheme == 'https' &&
        uri.host == base.host;
  }

  Future<String?> _decide(
      String owner, EgressGrant? grant, AdmissionRequest? request) async {
    if (!_resolved) return 'unresolved';
    final revoke = grant?.kind == EgressGrantKind.revoke;
    final control = grant?.control;
    if (control != null) {
      // A grant that ended or expired admits NOTHING (a zone timer or retry
      // that fires after the op finished lands here).
      if (!control.active) return 'grant_inactive';
      if (request == null) return 'grant_scope';
    }
    if (ConsentAuthority.egressFrozen && !revoke) return 'frozen';
    final readout = await store.read(owner: owner);
    if (readout.uncertain) return 'state_uncertain';
    final rec = readout.records[owner];
    if (rec != null && rec.state == EgressState.disabling) {
      return revoke &&
              grant!.owner == owner &&
              grant.generation == rec.transitionGeneration
          ? null
          : 'disabling';
    }
    if (revoke) return 'revoke_outside_disabling';
    if (control != null) {
      // Account control: exact host + method + path (+ grant_type) only, in ON,
      // OFF and unset alike. Everything else inside the allowance is denied.
      return control.scopeViolation(
          request!.method, request.url, _supabaseUrl());
    }
    if (rec == null || rec.state == EgressState.off) return 'off';
    return null;
  }

  /// THE admission gate. Throws [EgressDeniedException] when refused.
  Future<EgressTicket> admit(
      {String? owner, EgressGrant? grant, AdmissionRequest? request}) async {
    final g = grant ?? Zone.current[_grantKey] as EgressGrant?;
    // The lock position is taken synchronously, so admission order is call
    // order: a request made before a disable was called is decided before it.
    return _lock.synchronized(() async {
      final o = await _owner(owner);
      final deny = await _decide(o, g, request);
      // A granted request says nothing about whether AUTOMATIC traffic may run.
      if (g == null) _setMirror(deny == null);
      if (deny != null) throw EgressDeniedException(deny);
      final t = EgressTicket._(o, _epoch, g, request);
      _inFlight.add(t);
      return t;
    });
  }

  void release(EgressTicket t) {
    if (t._released) return;
    t._released = true;
    _inFlight.remove(t);
    if (_inFlight.isEmpty) {
      final idle = _idle;
      _idle = null;
      if (idle != null && !idle.isCompleted) idle.complete();
    }
  }

  /// True when a result that belongs to [t] may still be used.
  bool isCurrent(EgressTicket t) => !t.isCancelled && t.epoch == _epoch;

  /// Runs [body] under an admitted ticket (released when it settles).
  Future<T> guarded<T>(Future<T> Function(EgressTicket ticket) body,
      {String? owner, EgressGrant? grant}) async {
    final t = await admit(owner: owner, grant: grant);
    try {
      return await runZoned(() => body(t),
          zoneValues: grant == null ? null : {_grantKey: grant});
    } finally {
      release(t);
    }
  }

  /// Runs [body] under an operation-scoped account-control grant (H2.1): the
  /// ONLY way to reach the network while Cloud is OFF. Call it immediately
  /// before the Supabase exchange, after any native Google/Apple UI returned.
  ///
  ///  * the grant lives in the [Zone] of [body]; unrelated concurrent calls do
  ///    not inherit it;
  ///  * it expires after [accountControlTtl] on a monotonic clock and is ended in
  ///    `finally` on success, failure and timeout; a timer or retry spawned in
  ///    the zone that fires later finds it inactive and is denied;
  ///  * on a timeout the requests still running under it are cancelled;
  ///  * it never writes the egress record, never flips Cloud ON and never touches
  ///    consent.
  Future<T> runAccountControl<T>(
      AccountControlOp op, Future<T> Function() body) async {
    final control =
        AccountControlGrant._(op, ++_grantSeq, accountControlTtl, _monotonic);
    final grant = EgressGrant.accountControl(control);
    try {
      // `() async => await body()` on purpose: a lazily-executed builder (a
      // PostgREST rpc) only sends when it is first awaited, and that await must
      // happen INSIDE the grant zone, not in the caller's.
      return await runZoned(() async => await body(),
              zoneValues: {_grantKey: grant})
          .timeout(accountControlTtl, onTimeout: () {
        control._end();
        for (final t in _inFlight.toList()) {
          if (identical(t.grant?.control, control) && !t._cancel.isCompleted) {
            t._cancel.complete();
          }
        }
        throw TimeoutException('account_control_timeout');
      });
    } finally {
      control._end();
    }
  }

  /// The ONE request admitted in DISABLING. At most one call per transition (the
  /// caller guards that with its durable `revoke_attempt`). A timeout cancels
  /// the request and is reported as [TimeoutException].
  Future<T> runRevoke<T>(
      DisableFreeze freeze, Duration timeout, Future<T> Function() body) async {
    final grant = freeze.revokeGrant;
    final t = await admit(owner: freeze.owner, grant: grant);
    try {
      return await runZoned(() => body(), zoneValues: {_grantKey: grant})
          .timeout(timeout, onTimeout: () {
        if (!t._cancel.isCompleted) t._cancel.complete();
        throw TimeoutException('revoke_timeout');
      });
    } finally {
      release(t);
    }
  }

  // ── transitions ────────────────────────────────────────────────────────────

  /// Writes DISABLING durably, under the admission lock, with the transition
  /// generation advanced FIRST. Throws [EgressWriteFailedException] when not a
  /// single store took the record (the caller then sends no revoke).
  Future<DisableFreeze> beginDisabling({
    required String owner,
    required int reservedVersion,
  }) =>
      _lock.synchronized(() async {
        final prev = (await store.read(owner: owner)).records[owner];
        final gen = (prev?.transitionGeneration ?? 0) + 1;
        final freeze = DisableFreeze(
            owner: owner,
            transitionGeneration: gen,
            reservedVersion: reservedVersion);
        final w = await store.write(freeze.record(EgressState.disabling));
        _setMirror(false);
        if (!w.any) throw const EgressWriteFailedException('disabling');
        return freeze;
      });

  /// Re-writes DISABLING (a failed local OFF write must leave the marker).
  Future<bool> rewriteDisabling(DisableFreeze freeze) async =>
      (await _lock.synchronized(
              () => store.write(freeze.record(EgressState.disabling))))
          .any;

  /// Durable OFF. True when at least one store holds it. Never reopens traffic
  /// by itself: on false the DISABLING record is still there.
  Future<bool> commitOff(DisableFreeze freeze) async {
    final w = await _lock
        .synchronized(() => store.write(freeze.record(EgressState.off)));
    _setMirror(false);
    return w.any;
  }

  /// An explicit enable: a NEW generation and version (strictly greater), ON in
  /// EVERY store. A partial write leaves a restrictive record behind (the merge
  /// keeps it), so it throws.
  Future<CloudEgressRecord> enable({
    required String owner,
    required int reservedVersion,
  }) =>
      _lock.synchronized(() async {
        final prev = (await store.read(owner: owner)).records[owner];
        final rec = CloudEgressRecord(
          state: EgressState.on,
          ownerUid: owner,
          transitionGeneration: (prev?.transitionGeneration ?? 0) + 1,
          reservedVersion: reservedVersion,
        );
        final w = await store.write(rec);
        if (!w.all) {
          // Never leave a half-written ON behind: best-effort restrictive OFF.
          await store.write(rec.copyWith(state: EgressState.off));
          throw const EgressWriteFailedException('enable');
        }
        return rec;
      });

  /// Writes an arbitrary record under the lock (startup reconciliation).
  Future<EgressWriteResult> writeRecord(CloudEgressRecord record) =>
      _lock.synchronized(() => store.write(record));

  /// Waits for the in-flight set to drain (bounded by [drainTimeout]) and
  /// cancels whatever is still running. Only after this may OFF be committed.
  Future<DrainResult> drain() async {
    if (_inFlight.isEmpty) {
      return const DrainResult(waited: false, cancelled: 0);
    }
    final idle = _idle ??= Completer<void>();
    await idle.future.timeout(drainTimeout, onTimeout: () {});
    if (_inFlight.isEmpty) return const DrainResult(waited: true, cancelled: 0);
    final pending = _inFlight.toList();
    for (final t in pending) {
      if (!t._cancel.isCompleted) t._cancel.complete();
      release(t);
    }
    return DrainResult(waited: true, cancelled: pending.length);
  }

  /// Waits for native extension uploads admitted before DISABLING: until the
  /// count is 0 or the latest native deadline, never longer than [nativeMaxWait].
  /// An unavailable answer waits out the whole bound. Off iOS there is nothing.
  Future<void> drainNative(String owner) async {
    final query = _nativeInflight ??
        (NativeCaptureBridge.hasNativeQueue
            ? (String o) =>
                NativeCaptureBridge.nativeInflightUploads(ownerUid: o)
            : null);
    if (query == null) return;
    final limit = DateTime.now().add(nativeMaxWait);
    while (true) {
      ({int count, DateTime? latestDeadline})? r;
      try {
        r = await query(owner);
      } catch (_) {}
      final now = DateTime.now();
      if (r == null) {
        final left = limit.difference(now);
        if (left > Duration.zero) await Future<void>.delayed(left);
        return;
      }
      final cap = r.latestDeadline != null && r.latestDeadline!.isBefore(limit)
          ? r.latestDeadline!
          : limit;
      if (r.count == 0 || !now.isBefore(cap)) return;
      await Future<void>.delayed(nativePoll);
    }
  }

  /// Refreshes the synchronous mirror and tells [onPermitChanged].
  Future<void> refresh() async {
    final v = await view();
    _setMirror(_resolved && !v.uncertain && v.record?.state == EgressState.on);
  }

  void _setMirror(bool permits) {
    final next = permits && _resolved && !ConsentAuthority.egressFrozen;
    if (next == _permitMirror) return;
    _permitMirror = next;
    permitNotifier.value = next;
    final cb = onPermitChanged;
    if (cb != null) unawaited(cb(next).catchError((_) {}));
  }
}

class EgressView {
  const EgressView(this.owner, this.readout);
  final String owner;
  final EgressReadout readout;
  bool get uncertain => readout.uncertain;
  CloudEgressRecord? get record => readout.records[owner];
}

/// The transport every Dart network path uses. Admission happens per request;
/// the ticket is held until the response body has been read. A response that
/// arrives after the epoch advanced (or after a drain gave up on it) is
/// discarded with [EgressDeniedException].
class GatedHttpClient extends http.BaseClient {
  GatedHttpClient([http.Client? inner]) : _inner = inner ?? http.Client();

  final http.Client _inner;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final gate = CloudEgressGate.instance;
    final ticket = await gate.admit(
        request: AdmissionRequest(request.method, request.url));
    final result = Completer<http.StreamedResponse>();
    var settled = false;
    void fail(Object e, [StackTrace? s]) {
      if (settled) return;
      settled = true;
      gate.release(ticket);
      result.completeError(e, s);
    }

    // H2.1: a granted request must not follow redirects (a 3xx could leave the
    // allowlisted endpoint or host). Set before the request is finalized.
    if (ticket.grant?.control != null) request.followRedirects = false;
    unawaited(
        ticket.cancelled.then((_) => fail(EgressDeniedException('cancelled'))));
    http.BaseRequest outgoing = request;
    if (request is http.Request) {
      outgoing = http.AbortableRequest(request.method, request.url,
          abortTrigger: ticket.cancelled)
        ..headers.addAll(request.headers)
        ..bodyBytes = request.bodyBytes
        ..followRedirects = request.followRedirects
        ..maxRedirects = request.maxRedirects
        ..persistentConnection = request.persistentConnection;
    }
    _inner.send(outgoing).then((resp) {
      if (settled) {
        resp.stream.drain<void>().catchError((_) {});
        return;
      }
      settled = true;
      result.complete(http.StreamedResponse(
        _track(gate, ticket, resp.stream),
        resp.statusCode,
        contentLength: resp.contentLength,
        request: resp.request,
        headers: resp.headers,
        isRedirect: resp.isRedirect,
        persistentConnection: resp.persistentConnection,
        reasonPhrase: resp.reasonPhrase,
      ));
    }, onError: (Object e, StackTrace s) => fail(e, s));
    return result.future;
  }

  static Stream<List<int>> _track(CloudEgressGate gate, EgressTicket ticket,
      Stream<List<int>> body) async* {
    try {
      await for (final chunk in body) {
        if (!gate.isCurrent(ticket)) throw EgressDeniedException('stale');
        yield chunk;
      }
      if (!gate.isCurrent(ticket)) throw EgressDeniedException('stale');
    } finally {
      gate.release(ticket);
    }
  }

  @override
  void close() => _inner.close();
}
