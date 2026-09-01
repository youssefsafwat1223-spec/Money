/// PHASE 7 — the proof-v1 SHADOW call.
///
/// ## Why this is a second class and not a flag inside the existing client
///
/// The Phase-7 guarantee is that legacy behaviour is *untouched*, and the
/// approved plan is explicit that this cannot be assumed — it has to be
/// structurally true. A boolean inside `SupabaseAiParserClient` would put the
/// shadow on the same code path, the same timeout, the same retry loop and the
/// same failure handling as the production call, and "untouched" would then be
/// a claim about branches rather than a property of the design.
///
/// So the shadow is a separate object with its own transport. It has no
/// reference to the production client, and the production client has no
/// reference to it. `parse()` is byte-identical to what it was before Phase 7.
///
/// ## What this result may do
///
/// NOTHING. [ProofShadowOutcome] is a telemetry record. It carries no
/// transaction, no amount, no status, no id — deliberately, so there is nothing
/// for a caller to persist even by accident. The only sink is a counter.
///
/// ## Operational isolation
///
/// Authority isolation is not sufficient: a shadow call can still harm the
/// production call indirectly through shared quota, rate limits, provider
/// concurrency and device pressure. Hence, in the order the plan requires:
///
///   1. a DEDICATED shadow credential/quota — configured server-side, and
///      until it exists this arm stays off (see [ProofShadowConfig.enabled]);
///   2. a hard client-side sample rate, default 0;
///   3. an INDEPENDENT timeout, strictly shorter than the production call's;
///   4. LOWER PRIORITY — the shadow is only dispatched after the production
///      call has already completed;
///   5. a CIRCUIT BREAKER that disables the arm on consecutive failures.
///
/// > The shadow must never consume the last unit of capacity production needs.
library;

import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;

/// What a shadow attempt did. Telemetry only — there is nothing here to commit.
enum ProofShadowOutcome {
  /// The arm is off, or this message was not sampled.
  skipped,

  /// The circuit breaker is open after repeated failures.
  breakerOpen,

  /// A verdict came back and was counted.
  completed,

  /// Timed out on its own independent, shorter deadline.
  timedOut,

  /// Transport or server error. Never surfaced to the user.
  failed,
}

/// Remote-tunable shadow settings. Every default is the safe one.
class ProofShadowConfig {
  const ProofShadowConfig({
    this.enabled = false,
    this.sampleRate = 0.0,
    this.timeout = const Duration(seconds: 6),
    this.breakerThreshold = 3,
  });

  /// DEFAULT OFF. The plan requires dedicated shadow quota before this arm may
  /// run at all, and that quota does not exist yet. Turning this on without it
  /// would put shadow traffic on production's capacity — the one thing the
  /// isolation requirements forbid.
  final bool enabled;

  /// Fraction of messages shadowed. Default 0 so that even an accidental
  /// `enabled: true` shadows nothing until a rate is set deliberately.
  final double sampleRate;

  /// INDEPENDENT and strictly shorter than the production call's 12s, so a slow
  /// shadow can never be the reason a capture is late.
  final Duration timeout;

  /// Consecutive failures before the arm disables itself.
  final int breakerThreshold;

  ProofShadowConfig copyWith({bool? enabled, double? sampleRate}) =>
      ProofShadowConfig(
        enabled: enabled ?? this.enabled,
        sampleRate: sampleRate ?? this.sampleRate,
        timeout: timeout,
        breakerThreshold: breakerThreshold,
      );
}

/// Fire-and-forget proof-v1 shadow caller.
class ProofShadowClient {
  ProofShadowClient({
    required String edgeFunctionUrl,
    required Future<String?> Function() getAnonJwt,
    Future<String?> Function()? loadDeviceSecret,
    ProofShadowConfig config = const ProofShadowConfig(),
    http.Client? httpClient,
    Random? random,
  })  : _url = edgeFunctionUrl,
        _getAnonJwt = getAnonJwt,
        _loadDeviceSecret = loadDeviceSecret,
        _config = config,
        _http = httpClient ?? http.Client(),
        _random = random ?? Random();

  final String _url;
  final Future<String?> Function() _getAnonJwt;
  final Future<String?> Function()? _loadDeviceSecret;
  final ProofShadowConfig _config;
  final http.Client _http;
  final Random _random;

  int _consecutiveFailures = 0;
  bool _breakerOpen = false;

  /// True once the arm has disabled itself. Exposed for telemetry and tests.
  bool get isBreakerOpen => _breakerOpen;

  /// Counters. Privacy-safe by construction: they count outcomes, never text.
  final Map<ProofShadowOutcome, int> counters = {
    for (final o in ProofShadowOutcome.values) o: 0,
  };

  void _count(ProofShadowOutcome o) => counters[o] = (counters[o] ?? 0) + 1;

  /// Run a shadow call. NEVER throws, NEVER returns anything committable.
  ///
  /// The caller is expected to invoke this only AFTER the production call has
  /// finished, and to ignore the future. Both are enforced by tests rather than
  /// left to convention.
  Future<ProofShadowOutcome> shadow({
    required String sanitizedSms,
    required String senderId,
    required String installId,
  }) async {
    if (!_config.enabled) return _done(ProofShadowOutcome.skipped);
    if (_breakerOpen) return _done(ProofShadowOutcome.breakerOpen);
    if (_random.nextDouble() >= _config.sampleRate) {
      return _done(ProofShadowOutcome.skipped);
    }

    try {
      final jwt = await _getAnonJwt();
      if (jwt == null || jwt.isEmpty) return _fail();
      final deviceSecret = await _loadDeviceSecret?.call();

      final response = await _http
          .post(
            Uri.parse(_url),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $jwt',
            },
            body: jsonEncode({
              'sanitized_sms': sanitizedSms,
              'sender_id': senderId,
              'install_id': installId,
              if (deviceSecret != null && deviceSecret.isNotEmpty)
                'device_secret': deviceSecret,
              // The additive server mode. A v1 request is byte-identical to
              // what it was; this key is what selects the shadow path.
              'contract': 'proof-v1',
              'schema_version': 1,
            }),
          )
          .timeout(_config.timeout);

      if (response.statusCode >= 200 && response.statusCode < 300) {
        _consecutiveFailures = 0;
        return _done(ProofShadowOutcome.completed);
      }
      return _fail();
    } catch (e) {
      // A timeout is distinguished only for telemetry; both paths are
      // swallowed, because a shadow failure is not an event the user or the
      // ledger may ever learn about.
      final timedOut = e.toString().contains('TimeoutException');
      return _fail(timedOut ? ProofShadowOutcome.timedOut : null);
    }
  }

  ProofShadowOutcome _done(ProofShadowOutcome o) {
    _count(o);
    return o;
  }

  ProofShadowOutcome _fail([ProofShadowOutcome? as]) {
    _consecutiveFailures++;
    if (_consecutiveFailures >= _config.breakerThreshold) _breakerOpen = true;
    return _done(as ?? ProofShadowOutcome.failed);
  }
}
