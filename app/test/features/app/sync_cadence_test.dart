// Phase-7 Batch-2 (MALI-029 cadence) — deterministic cadence/coalescing tests.
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/features/app/sync_cadence.dart';

void main() {
  group('SyncCadence backoff', () {
    test('base interval when active', () {
      final c = SyncCadence();
      expect(c.nextDelay(), const Duration(seconds: 30));
    });

    test('doubles per consecutive idle poll, capped at max', () {
      final c = SyncCadence(
        base: const Duration(seconds: 30),
        max: const Duration(seconds: 300),
      );
      c.recordIdlePoll(); // 1 → x2
      expect(c.nextDelay(), const Duration(seconds: 60));
      c.recordIdlePoll(); // 2 → x4
      expect(c.nextDelay(), const Duration(seconds: 120));
      c.recordIdlePoll(); // 3 → x8 = 240
      expect(c.nextDelay(), const Duration(seconds: 240));
      c.recordIdlePoll(); // 4 → x16 = 480 → capped at 300
      expect(c.nextDelay(), const Duration(seconds: 300));
      c.recordIdlePoll(); // stays capped
      expect(c.nextDelay(), const Duration(seconds: 300));
    });

    test('activity resets to base (responsive again)', () {
      final c = SyncCadence();
      c.recordIdlePoll();
      c.recordIdlePoll();
      expect(c.idleStreak, 2);
      c.recordActivity();
      expect(c.idleStreak, 0);
      expect(c.nextDelay(), const Duration(seconds: 30));
    });

    test('user-triggered sync overrides backoff', () {
      final c = SyncCadence();
      c.recordIdlePoll();
      c.recordIdlePoll();
      c.recordUserTriggered();
      expect(c.nextDelay(), const Duration(seconds: 30));
    });
  });

  group('SyncCoalescer', () {
    test('first request starts a run', () {
      final co = SyncCoalescer();
      expect(co.requestRun(), isTrue);
      expect(co.isRunning, isTrue);
    });

    test('a request during a run is coalesced, not dropped, and fires once', () {
      final co = SyncCoalescer();
      expect(co.requestRun(), isTrue); // start run 1
      // three overlapping requests during the run
      expect(co.requestRun(), isFalse);
      expect(co.requestRun(), isFalse);
      expect(co.requestRun(), isFalse);
      // finishing run 1 → EXACTLY one coalesced follow-up
      expect(co.finishRun(), isTrue);
      // finishing the follow-up → nothing further pending
      expect(co.finishRun(), isFalse);
      expect(co.isRunning, isFalse);
    });

    test('no overlap → no phantom follow-up', () {
      final co = SyncCoalescer();
      expect(co.requestRun(), isTrue);
      expect(co.finishRun(), isFalse);
    });
  });

  group('SyncGate — offline / recovery', () {
    test('starts online: background triggers run', () {
      final g = SyncGate();
      expect(g.isOnline, isTrue);
      expect(g.shouldRun(), isTrue);
      expect(g.hasPendingIntent, isFalse);
    });

    test('an offline attempt suppresses later background triggers + coalesces '
        'ONE pending intent', () {
      final g = SyncGate();
      // A completed attempt that could not reach the server → offline.
      g.recordReachability(reachedNetwork: false);
      expect(g.isOnline, isFalse);
      expect(g.hasPendingIntent, isTrue);

      // Repeated local-activity/background triggers while offline do NOT run and
      // do NOT stack up — exactly one pending intent, no retry burn.
      expect(g.shouldRun(), isFalse);
      expect(g.shouldRun(), isFalse);
      expect(g.shouldRun(), isFalse);
      expect(g.hasPendingIntent, isTrue);
    });

    test('manual + recovery-probe triggers always run, even offline', () {
      final g = SyncGate();
      g.recordReachability(reachedNetwork: false);
      expect(g.shouldRun(manual: true), isTrue); // user priority
      g.recordReachability(reachedNetwork: false);
      expect(g.shouldRun(recoveryProbe: true), isTrue); // resume/periodic probe
    });

    test('reaching the network after offline fires exactly ONE recovery', () {
      final g = SyncGate();
      g.recordReachability(reachedNetwork: false); // offline, intent queued
      // The probe run reaches the network → recovery fires once...
      expect(g.recordReachability(reachedNetwork: true), isTrue);
      expect(g.isOnline, isTrue);
      expect(g.hasPendingIntent, isFalse);
      // ...and not again on the next reachable attempt.
      expect(g.recordReachability(reachedNetwork: true), isFalse);
    });

    test('empty online attempts never fabricate a recovery', () {
      final g = SyncGate();
      expect(g.recordReachability(reachedNetwork: true), isFalse);
      expect(g.recordReachability(reachedNetwork: true), isFalse);
    });
  });

  group('SyncGate — sign-out / ownership', () {
    test('invalidate bumps the generation and drops the pending intent', () {
      final g = SyncGate();
      final gen0 = g.generation;
      g.recordReachability(reachedNetwork: false); // queue an offline intent
      expect(g.hasPendingIntent, isTrue);

      final gen1 = g.invalidate();
      expect(gen1, greaterThan(gen0));
      expect(g.hasPendingIntent, isFalse, reason: 'old intent dropped');
      expect(g.isOnline, isTrue, reason: 'fresh owner starts optimistic');
    });

    test('a run captured under the old generation is no longer admitted', () {
      final g = SyncGate();
      final captured = g.generation; // a run/timer captured this owner gen
      expect(g.admits(captured), isTrue);

      g.invalidate(); // sign-out / owner change
      expect(g.admits(captured), isFalse,
          reason: 'old-owner run cannot execute under the new owner');
    });

    test('same-UID relogin (new admission generation) invalidates old work', () {
      final g = SyncGate();
      final gen0 = g.generation;
      // sign-out then sign back in as the SAME uid → a new admission generation.
      g.invalidate();
      final gen2 = g.invalidate();
      expect(gen2, greaterThan(gen0));
      expect(g.admits(gen0), isFalse);
      expect(g.admits(gen2), isTrue);
    });
  });
}
