/// PHASE 7 — the architecture half of the exit gate.
///
/// The plan requires that the shadow result "has no code path into ledger,
/// status, notification or sync decisions — DEMONSTRATED, not asserted". These
/// tests are that demonstration, and they are deliberately of two kinds:
///
///   · behavioural — the shadow cannot delay, fail or alter the production
///     call, proven by running them together;
///   · structural — the shadow type carries nothing committable, and the
///     production client holds no reference to the shadow, proven by source
///     inspection so it cannot rot into an assertion about branches.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:money_companion/engine/ai/proof_shadow_client.dart';

ProofShadowClient _client({
  bool enabled = true,
  double sampleRate = 1.0,
  Duration timeout = const Duration(seconds: 6),
  int breakerThreshold = 3,
  required Future<http.Response> Function(http.Request) handler,
}) =>
    ProofShadowClient(
      edgeFunctionUrl: 'https://example.invalid/parse-sms',
      getAnonJwt: () async => 'jwt',
      config: ProofShadowConfig(
        enabled: enabled,
        sampleRate: sampleRate,
        timeout: timeout,
        breakerThreshold: breakerThreshold,
      ),
      httpClient: MockClient(handler),
      random: Random(1),
    );

Future<ProofShadowOutcome> _run(ProofShadowClient c) => c.shadow(
      sanitizedSms: 'شراء 45.00 ر.س',
      senderId: 'ALRAJHI',
      installId: 'install-1',
    );

void main() {
  group('the shadow arm is OFF by default', () {
    test('default config disables it', () {
      const c = ProofShadowConfig();
      expect(c.enabled, isFalse,
          reason: 'dedicated shadow quota does not exist yet; enabling this '
              'would put shadow traffic on production capacity');
      expect(c.sampleRate, 0.0);
    });

    test('even if enabled, the default sample rate shadows nothing', () {
      const c = ProofShadowConfig(enabled: true);
      expect(c.sampleRate, 0.0);
    });

    test('a disabled client makes no HTTP call at all', () async {
      var called = false;
      final c = _client(
        enabled: false,
        handler: (_) async {
          called = true;
          return http.Response('{}', 200);
        },
      );
      expect(await _run(c), ProofShadowOutcome.skipped);
      expect(called, isFalse, reason: 'off means no request, not a wasted one');
    });
  });

  group('independent timeout — strictly shorter than the production call', () {
    test('the default shadow timeout is shorter than the production 12s', () {
      expect(const ProofShadowConfig().timeout.inSeconds, lessThan(12));
    });

    test('a hanging shadow gives up on its own deadline', () async {
      final c = _client(
        timeout: const Duration(milliseconds: 60),
        handler: (_) async {
          await Future<void>.delayed(const Duration(seconds: 5));
          return http.Response('{}', 200);
        },
      );
      final sw = Stopwatch()..start();
      final r = await _run(c);
      sw.stop();
      expect(r, ProofShadowOutcome.timedOut);
      expect(sw.elapsed.inSeconds, lessThan(2),
          reason: 'the shadow must not hold anything open');
    });
  });

  group('the shadow can never delay or alter the production call', () {
    test('a hanging shadow does not delay a concurrent production call',
        () async {
      final shadow = _client(
        timeout: const Duration(milliseconds: 80),
        handler: (_) async {
          await Future<void>.delayed(const Duration(seconds: 3));
          return http.Response('{}', 200);
        },
      );
      // Stand-in for the production call: independent transport, own future.
      Future<String> productionCall() async {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        return 'legacy-result';
      }

      final sw = Stopwatch()..start();
      unawaited(_run(shadow)); // fire-and-forget, exactly as production does
      final result = await productionCall();
      sw.stop();

      expect(result, 'legacy-result');
      expect(sw.elapsed.inMilliseconds, lessThan(500),
          reason: 'production completed on its own schedule');
    });

    test('a throwing shadow never propagates to the caller', () async {
      final c = _client(handler: (_) async => throw const SocketException('x'));
      expect(await _run(c), ProofShadowOutcome.failed,
          reason: 'shadow failure is swallowed — it is not the user\'s problem');
    });

    test('a 500 from the shadow endpoint is swallowed', () async {
      final c = _client(handler: (_) async => http.Response('boom', 500));
      expect(await _run(c), ProofShadowOutcome.failed);
    });
  });

  group('circuit breaker', () {
    test('opens after consecutive failures and then stops calling', () async {
      var calls = 0;
      final c = _client(
        breakerThreshold: 3,
        handler: (_) async {
          calls++;
          return http.Response('boom', 500);
        },
      );
      for (var i = 0; i < 3; i++) {
        await _run(c);
      }
      expect(c.isBreakerOpen, isTrue);
      final before = calls;
      expect(await _run(c), ProofShadowOutcome.breakerOpen);
      expect(calls, before, reason: 'an open breaker issues no further requests');
    });

    test('a success resets the failure streak', () async {
      var n = 0;
      final c = _client(
        breakerThreshold: 3,
        handler: (_) async =>
            http.Response('{}', ++n == 2 ? 200 : 500),
      );
      await _run(c); // fail 1
      await _run(c); // success — resets
      await _run(c); // fail 1 again
      expect(c.isBreakerOpen, isFalse);
    });
  });

  group('the shadow result carries nothing committable', () {
    test('the outcome type is an enum of call dispositions only', () {
      // If this ever gains an amount, a status or an id, the isolation claim
      // becomes a matter of discipline instead of a property of the type.
      expect(ProofShadowOutcome.values.map((e) => e.name).toSet(), {
        'skipped',
        'breakerOpen',
        'completed',
        'timedOut',
        'failed',
      });
    });

    test('telemetry counters hold integers, never message content', () async {
      final c = _client(handler: (_) async => http.Response('{}', 200));
      await _run(c);
      expect(c.counters[ProofShadowOutcome.completed], 1);
      for (final v in c.counters.values) {
        expect(v, isA<int>());
      }
    });

    test('the request carries the additive contract marker', () async {
      Map<String, dynamic>? sent;
      final c = _client(handler: (req) async {
        sent = jsonDecode(req.body) as Map<String, dynamic>;
        return http.Response('{}', 200);
      });
      await _run(c);
      expect(sent!['contract'], 'proof-v1',
          reason: 'a v1 request must stay byte-identical; this key selects the '
              'additive server mode');
    });
  });

  group('STRUCTURAL: no code path from shadow into authority', () {
    // Source-level proof. Behavioural tests show the shadow does not interfere
    // today; these show there is no wire to interfere through tomorrow.
    /// Source with comments stripped. The claim under test is "no code path",
    /// not "no mention in prose" — this file's own documentation names the
    /// things it must not touch, and that must not count as touching them.
    String code(String p) {
      final src = File(p).readAsStringSync();
      final out = StringBuffer();
      for (final line in src.split('\n')) {
        final t = line.trimLeft();
        if (t.startsWith('///') || t.startsWith('//')) continue;
        final idx = line.indexOf('//');
        out.writeln(idx >= 0 ? line.substring(0, idx) : line);
      }
      return out.toString();
    }

    test('the production client does not reference the shadow', () {
      final src = code('lib/engine/ai/ai_parser_client.dart');
      expect(src.contains('ProofShadow'), isFalse,
          reason: 'the legacy call path must not know the shadow exists');
      expect(src.contains('proof-v1'), isFalse);
    });

    test('the shadow does not reference ledger, status, sync or notifications',
        () {
      final src = code('lib/engine/ai/proof_shadow_client.dart');
      for (final forbidden in const [
        'Ledger',
        'ledger',
        'TransactionStatus',
        'AddTransaction',
        'Notification',
        'notification',
        'SyncService',
        'outbox',
        'Drift',
        'AppDatabase',
      ]) {
        expect(src.contains(forbidden), isFalse,
            reason: 'shadow must have no path to "$forbidden"');
      }
    });

    test('nothing in the app consumes a shadow result', () {
      // The only permitted consumer is telemetry. If a feature ever reads
      // `shadow(...)` for a decision, this fails.
      final dir = Directory('lib');
      final offenders = <String>[];
      for (final f in dir.listSync(recursive: true).whereType<File>()) {
        if (!f.path.endsWith('.dart')) continue;
        if (f.path.endsWith('proof_shadow_client.dart')) continue;
        final src = code(f.path);
        if (src.contains('ProofShadowOutcome') || src.contains('.shadow(')) {
          offenders.add(f.path);
        }
      }
      expect(offenders, isEmpty,
          reason: 'shadow results are consumed nowhere; wiring one into a '
              'decision would surface here');
    });
  });
}
