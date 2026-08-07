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
}
