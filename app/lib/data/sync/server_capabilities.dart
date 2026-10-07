/// A-6 — the explicit server capability probe.
///
/// The server advertises app-visible capabilities through the read-only RPC
/// `qirsh_server_capabilities()` (authenticated, returns jsonb). Before the
/// deferred migration 0102 is deployed the RPC does not exist, which is itself
/// the answer: the capability is UNSUPPORTED. Authority is positive-proof only:
/// a capability is [ServerCapabilityState.verified] only when the RPC returned
/// its key as `true`, or a send of that shape was accepted ([noteVerified]).
library;

import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/backend/supabase_config.dart';
import '../../core/sync/sync_health.dart';

enum ServerCapabilityState {
  /// Probe not possible / failed transiently (network, auth, server error,
  /// consent off). NOT proof of anything; rows stay held.
  unknown,
  verified,

  /// RPC missing, or the key is absent/false.
  unsupported,
}

/// RPC key for awaiting-FX (amount 0 + foreign amount/currency) transactions.
const String kCapAwaitingFxTransactions = 'awaiting_fx_transactions';

/// RPC key for the WP-4 sequence pull (manifest §8). It is the kill switch:
/// withdrawing it sends clients back to the legacy timestamp pull.
const String kCapSyncSeq = 'sync_seq';

class ServerCapabilitiesService {
  ServerCapabilitiesService({
    required Future<String?> Function() getAuthUserId,
    required SupabaseClient Function() getClient,
    Future<bool> Function()? mayEgress,
    SyncHealth? health,
    String Function()? getServerUrl,
    DateTime Function()? clock,
    this.unknownRetryAfter = const Duration(minutes: 2),
  })  : _getAuthUserId = getAuthUserId,
        _getClient = getClient,
        _mayEgress = mayEgress ?? _deny,
        _health = health,
        _getServerUrl = getServerUrl ?? (() => SupabaseConfig.url),
        _clock = clock ?? DateTime.now;

  static Future<bool> _deny() async => false;

  final Future<String?> Function() _getAuthUserId;
  final SupabaseClient Function() _getClient;
  final Future<bool> Function() _mayEgress;
  final SyncHealth? _health;
  final String Function() _getServerUrl;
  final DateTime Function() _clock;

  /// Minimum gap between probes while the answer is still [unknown], so an
  /// offline device does not probe on every push cycle.
  final Duration unknownRetryAfter;

  // Per-session cache keyed by server URL + uid (never persisted).
  final Map<String, ServerCapabilityState> _awaitingFx = {};
  final Map<String, DateTime> _unknownAt = {};
  final Map<String, DateTime> _probedAt = {};

  final List<void Function(String uid, ServerCapabilityState)> _listeners = [];

  // WP-4: unlike awaiting-FX a `verified` sync_seq must NOT stick for the whole
  // session (it is a kill switch), so every answer expires after [syncSeqTtl].
  final Map<String, ServerCapabilityState> _syncSeq = {};
  final Map<String, DateTime> _syncSeqAt = {};
  static const Duration syncSeqTtl = Duration(minutes: 15);

  String _key(String uid) => '${_getServerUrl()}|$uid';

  /// Cached state with no network.
  ServerCapabilityState cachedAwaitingFx(String uid) =>
      _awaitingFx[_key(uid)] ?? ServerCapabilityState.unknown;

  /// Called whenever the cached state for a user changes.
  void addListener(void Function(String uid, ServerCapabilityState) l) =>
      _listeners.add(l);

  /// Resolves the awaiting-FX capability for [uid]: cached verified/unsupported
  /// answers are returned as-is (one probe per session); an unknown answer is
  /// re-probed at most every [unknownRetryAfter] unless [force]. Consent-gated:
  /// with financialSync off nothing is sent and the result is unknown.
  Future<ServerCapabilityState> awaitingFxTransactions({
    String? uid,
    bool force = false,
  }) async {
    final user = uid ?? await _getAuthUserId();
    if (user == null) return ServerCapabilityState.unknown;
    final key = _key(user);
    final cached = _awaitingFx[key] ?? ServerCapabilityState.unknown;
    if (!force && cached != ServerCapabilityState.unknown) return cached;
    final last = _unknownAt[key];
    if (!force &&
        last != null &&
        _clock().difference(last) < unknownRetryAfter) {
      return cached;
    }

    if (!await _mayEgress()) {
      _health?.recordConsentBlocked(SyncDomain.ledger);
      return ServerCapabilityState.unknown;
    }

    _probedAt[key] = _clock();
    ServerCapabilityState result;
    try {
      final raw = await _getClient().rpc('qirsh_server_capabilities');
      result = raw is Map && raw[kCapAwaitingFxTransactions] == true
          ? ServerCapabilityState.verified
          : ServerCapabilityState.unsupported;
    } catch (e) {
      if (_isRpcMissing(e)) {
        result = ServerCapabilityState.unsupported;
      } else {
        result = ServerCapabilityState.unknown;
        _health?.noteFailure(SyncDomain.ledger, e);
      }
    }
    _set(user, result);
    return result;
  }

  /// WP-4: whether the server advertises `sync_seq` for [uid]. Positive proof
  /// only: [ServerCapabilityState.unsupported] means the RPC is missing or the
  /// key is absent/false (-> legacy timestamp pull); auth/network/server errors
  /// are [ServerCapabilityState.unknown] (never treated as "absent"). Consent
  /// gated by the caller (the ledger pull checks egress first).
  Future<ServerCapabilityState> syncSeq({String? uid}) async {
    final user = uid ?? await _getAuthUserId();
    if (user == null) return ServerCapabilityState.unknown;
    final key = _key(user);
    final at = _syncSeqAt[key];
    final cached = _syncSeq[key];
    if (cached != null &&
        cached != ServerCapabilityState.unknown &&
        at != null &&
        _clock().difference(at) < syncSeqTtl) {
      return cached;
    }
    if (!await _mayEgress()) return ServerCapabilityState.unknown;
    ServerCapabilityState result;
    try {
      final raw = await _getClient().rpc('qirsh_server_capabilities');
      result = raw is Map && raw[kCapSyncSeq] == true
          ? ServerCapabilityState.verified
          : ServerCapabilityState.unsupported;
    } catch (e) {
      if (_isRpcMissing(e)) {
        result = ServerCapabilityState.unsupported;
      } else {
        result = ServerCapabilityState.unknown;
        _health?.noteFailure(SyncDomain.ledger, e);
      }
    }
    _syncSeq[key] = result;
    _syncSeqAt[key] = _clock();
    return result;
  }

  /// A-5: re-probes a cached `unsupported` / `unknown` answer (the server may
  /// have deployed the capability since — migration 0102 — while this process
  /// kept running), at most once per [minInterval]. A `verified` answer is never
  /// re-probed. Called on app resume; Retry uses `force: true` directly.
  Future<ServerCapabilityState> reprobeIfStale({
    Duration minInterval = const Duration(minutes: 15),
  }) async {
    final user = await _getAuthUserId();
    if (user == null) return ServerCapabilityState.unknown;
    final key = _key(user);
    final cached = _awaitingFx[key] ?? ServerCapabilityState.unknown;
    if (cached == ServerCapabilityState.verified) return cached;
    final last = _probedAt[key];
    if (last != null && _clock().difference(last) < minInterval) return cached;
    return awaitingFxTransactions(uid: user, force: true);
  }

  /// A send of the awaiting-FX shape was accepted by the server: proof.
  void noteVerified(String uid) => _set(uid, ServerCapabilityState.verified);

  /// The server rejected the awaiting-FX shape (23514) this session.
  void noteUnsupported(String uid) =>
      _set(uid, ServerCapabilityState.unsupported);

  void _set(String uid, ServerCapabilityState state) {
    final key = _key(uid);
    final before = _awaitingFx[key] ?? ServerCapabilityState.unknown;
    _awaitingFx[key] = state;
    if (state == ServerCapabilityState.unknown) {
      _unknownAt[key] = _clock();
    } else {
      _unknownAt.remove(key);
    }
    if (before != state) {
      for (final l in List.of(_listeners)) {
        l(uid, state);
      }
    }
  }

  /// The RPC does not exist (PostgREST schema-cache miss / HTTP 404 / undefined
  /// function). Auth, network and server errors are NOT "missing".
  static bool _isRpcMissing(Object e) {
    if (e is! PostgrestException) return false;
    final code = e.code ?? '';
    return code == 'PGRST202' || code == '404' || code == '42883';
  }
}
