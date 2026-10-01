/// Runtime probe for the SERVER planning-currency capability (migration 0077:
/// `user_budgets.currency` and `user_goals.currency`).
///
/// Production deployment state of 0077 is unknown at build time, so the answer
/// is discovered, never assumed. The probe is a read-only PostgREST request
/// `select('currency').limit(0)` per table — budgets and goals independently:
///
///  * success                              -> verified for that table
///  * 42703 (undefined column), PGRST204 / PGRST200 (column not found in the
///    schema cache), 42P01 / PGRST205 (table missing) -> unsupported
///  * anything else (network, auth, 5xx, ambiguous) -> unknown (NOT proof of
///    anything; rows stay parked and the probe is retried)
///
/// Authority is positive-proof only; the combined value published to
/// `planningServerCurrencyCapabilityProvider` is the WEAKER of the two tables.
/// Consent-gated (financialSync, asked fresh on every probe, fail-closed) and
/// only when signed in. Results are cached per server URL + uid for the process
/// (never persisted); `unknown` is re-probed with a back-off, `unsupported` and
/// `unknown` are re-probed on resume ([reprobeIfStale]) and on Retry
/// (`force: true`), because the server may have deployed 0077 meanwhile.
library;

import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/backend/supabase_config.dart';
import '../../core/sync/sync_health.dart';
import 'exact_transport_capability.dart';

class PlanningCurrencyCapabilityProbe {
  PlanningCurrencyCapabilityProbe({
    required Future<String?> Function() getAuthUserId,
    required Future<void> Function(String table) probeCurrencyColumn,
    required void Function(ExactTransportCapability combined) onChanged,
    Future<bool> Function()? mayEgress,
    SyncHealth? health,
    String Function()? getServerUrl,
    DateTime Function()? clock,
    this.unknownRetryAfter = const Duration(minutes: 2),
  })  : _getAuthUserId = getAuthUserId,
        _probeColumn = probeCurrencyColumn,
        _onChanged = onChanged,
        _mayEgress = mayEgress ?? _deny,
        _health = health,
        _getServerUrl = getServerUrl ?? (() => SupabaseConfig.url),
        _clock = clock ?? DateTime.now;

  /// Production wiring: the real PostgREST client.
  static Future<void> Function(String table) clientProbe(
          SupabaseClient Function() getClient) =>
      (table) async {
        await getClient().from(table).select('currency').limit(0);
      };

  static const String budgetsTable = 'user_budgets';
  static const String goalsTable = 'user_goals';
  static const List<String> tables = [budgetsTable, goalsTable];

  static Future<bool> _deny() async => false;

  final Future<String?> Function() _getAuthUserId;
  final Future<void> Function(String table) _probeColumn;
  final void Function(ExactTransportCapability combined) _onChanged;
  final Future<bool> Function() _mayEgress;
  final SyncHealth? _health;
  final String Function() _getServerUrl;
  final DateTime Function() _clock;

  /// Minimum gap between probes while an answer is still [unknown].
  final Duration unknownRetryAfter;

  final Map<String, ExactTransportCapability> _state = {};
  final Map<String, DateTime> _probedAt = {};
  Future<ExactTransportCapability>? _inFlight;

  String _key(String uid, String table) => '${_getServerUrl()}|$uid|$table';

  ExactTransportCapability _cached(String uid, String table) =>
      _state[_key(uid, table)] ?? ExactTransportCapability.unknown;

  /// Cached combined answer for [uid] with no network.
  ExactTransportCapability cachedCombined(String uid) =>
      weakerCapability(_cached(uid, budgetsTable), _cached(uid, goalsTable));

  /// Cycle-start entry point: verified/unsupported answers are cached for the
  /// session; an unknown answer is re-probed at most every [unknownRetryAfter]
  /// unless [force]. Never throws.
  Future<ExactTransportCapability> ensure({bool force = false}) {
    final running = _inFlight;
    if (running != null) return running;
    final f = _ensure(force: force).whenComplete(() => _inFlight = null);
    _inFlight = f;
    return f;
  }

  /// Resume: re-probes a cached `unsupported` / `unknown` answer (0077 may have
  /// been deployed while the process kept running), at most once per
  /// [minInterval]. A fully verified answer is never re-probed.
  Future<ExactTransportCapability> reprobeIfStale({
    Duration minInterval = const Duration(minutes: 15),
  }) async {
    final uid = await _getAuthUserId();
    if (uid == null) return _publish(null);
    final combined = cachedCombined(uid);
    if (combined == ExactTransportCapability.verifiedExact) return combined;
    final last = _lastProbe(uid);
    if (last != null && _clock().difference(last) < minInterval) {
      return combined;
    }
    return ensure(force: true);
  }

  /// Resolves the probe (cached / throttled like [ensure]) and returns the answer
  /// for ONE table ([budgetsTable] / [goalsTable]); `unknown` when signed out.
  Future<ExactTransportCapability> ensureTable(String table) async {
    await ensure();
    String? uid;
    try {
      uid = await _getAuthUserId();
    } catch (_) {
      uid = null;
    }
    return uid == null ? ExactTransportCapability.unknown : _cached(uid, table);
  }

  DateTime? _lastProbe(String uid) {
    DateTime? newest;
    for (final t in tables) {
      final at = _probedAt[_key(uid, t)];
      if (at != null && (newest == null || at.isAfter(newest))) newest = at;
    }
    return newest;
  }

  Future<ExactTransportCapability> _ensure({required bool force}) async {
    String? uid;
    try {
      uid = await _getAuthUserId();
    } catch (_) {
      uid = null;
    }
    if (uid == null) return _publish(null);

    // Publish what this user's cache says first, so a user switch never
    // inherits the previous user's verified state while the probe is in flight.
    _publish(uid);

    final due = <String>[];
    for (final t in tables) {
      final key = _key(uid, t);
      final cached = _state[key] ?? ExactTransportCapability.unknown;
      if (!force && cached != ExactTransportCapability.unknown) continue;
      final last = _probedAt[key];
      if (!force &&
          last != null &&
          _clock().difference(last) < unknownRetryAfter) {
        continue;
      }
      if (force && cached == ExactTransportCapability.verifiedExact) continue;
      due.add(t);
    }
    if (due.isEmpty) return cachedCombined(uid);

    // Consent: fresh per probe, fail-closed. Nothing is sent without it.
    bool allowed;
    try {
      allowed = await _mayEgress();
    } catch (_) {
      allowed = false;
    }
    if (!allowed) return cachedCombined(uid);

    for (final t in due) {
      final key = _key(uid, t);
      _probedAt[key] = _clock();
      ExactTransportCapability result;
      try {
        await _probeColumn(t);
        result = ExactTransportCapability.verifiedExact;
      } catch (e) {
        result = isColumnMissing(e)
            ? ExactTransportCapability.unsupported
            : ExactTransportCapability.unknown;
      }
      _state[key] = result;
      _health?.recordCapability('planning currency ($t)', result.name);
    }
    return _publish(uid);
  }

  ExactTransportCapability _publish(String? uid) {
    final combined =
        uid == null ? ExactTransportCapability.unknown : cachedCombined(uid);
    _onChanged(combined);
    _health?.recordCapability('planning currency', combined.name);
    return combined;
  }

  /// The server has no such column / table. Auth, network, 5xx and anything
  /// ambiguous are NOT "missing".
  static bool isColumnMissing(Object e) {
    if (e is! PostgrestException) return false;
    final code = e.code ?? '';
    return code == '42703' ||
        code == 'PGRST204' ||
        code == 'PGRST200' ||
        code == '42P01' ||
        code == 'PGRST205';
  }
}
