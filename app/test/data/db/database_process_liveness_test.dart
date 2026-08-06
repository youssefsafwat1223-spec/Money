import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/db/database_lease.dart';
import 'package:money_companion/data/db/database_process_liveness.dart';

// MALI-069n (Batch-4 closure #4) — Contract B process liveness. The reaping
// authority is a process-lifetime OS advisory lock, NOT a heartbeat. Includes a
// REAL multi-process proof via `Process.start`.

DatabaseProcessLiveness _liveness(Directory dir) => DatabaseProcessLiveness(
      lockPath: '${dir.path}/db.plock',
      instancePath: '${dir.path}/db.instance',
    );

DatabaseLeaseManager _manager(Directory dir, {int? ownerPid}) =>
    DatabaseLeaseManager(
      leaseDir: '${dir.path}/leases',
      intentPath: '${dir.path}/db.maint',
      ownerPid: ownerPid,
      settleWindow: const Duration(milliseconds: 40),
      pollStep: const Duration(milliseconds: 15),
    );

/// A self-contained (dart:io-only) external process: it takes the OS advisory lock
/// on the plock, writes a lease record tagged with ITS pid, signals readiness, then
/// stays alive (holding the lock) until killed.
const String _helperSource = r'''
import 'dart:io';
Future<void> main(List<String> args) async {
  final plock = args[0], leasePath = args[1], ready = args[2];
  final raf = File(plock).openSync(mode: FileMode.write);
  raf.lockSync(FileLock.exclusive);
  File(leasePath).parent.createSync(recursive: true);
  File(leasePath).writeAsStringSync('helpertoken\n$pid\nhelperinstance');
  File(ready).writeAsStringSync('$pid');
  await Future<void>.delayed(const Duration(hours: 1));
}
''';

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('mali_live_'));
  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  group('process-liveness handle', () {
    test('acquire takes the exclusive lock and yields a fresh instance token',
        () {
      final h = _liveness(dir).acquire();
      addTearDown(h.debugReleaseForTest);
      expect(h.acquiredExclusive, isTrue);
      expect(h.ownerPid, pid);
      expect(h.instanceToken, isNotEmpty);
    });

    test('the instance record contains no financial content', () {
      final h = _liveness(dir).acquire();
      addTearDown(h.debugReleaseForTest);
      final record = File('${dir.path}/db.instance').readAsStringSync();
      expect(record, contains('$pid'));
      expect(record, contains(h.instanceToken));
      // Only pid + opaque token — no amounts/accounts/keys.
      expect(record, isNot(matches(RegExp(r'\d+\.\d{2}')))); // no money amounts
    });
  });

  group('startup recovery keyed on owner pid (same-process safety)', () {
    test('a leftover lease tagged with a DIFFERENT pid is recovered; a CURRENT-pid '
        'lease is left untouched', () async {
      final leaseDir = Directory('${dir.path}/leases')..createSync(recursive: true);
      // A leftover from an ENDED instance (different pid).
      final ended = File('${leaseDir.path}/999_0_a.lease');
      ended.writeAsStringSync('tok\n999999\ninst-old');
      // A live lease belonging to THIS process (current pid) — e.g. a background
      // isolate that opened just before bootstrap ran recovery.
      final live = await _manager(dir).acquireShared();
      addTearDown(live.release);

      final cleared = _manager(dir).recoverEndedInstances();
      expect(cleared, 1, reason: 'only the different-pid leftover is recovered');
      expect(ended.existsSync(), isFalse);
      expect(_manager(dir).debugLiveLeaseCount(), 1,
          reason: 'the current-pid live lease is never reaped at startup');
    });

    test('a malformed leftover record is recovered under the lock', () {
      final leaseDir = Directory('${dir.path}/leases')..createSync(recursive: true);
      File('${leaseDir.path}/x.lease').writeAsStringSync(''); // empty/partial
      final cleared = _manager(dir).recoverEndedInstances();
      expect(cleared, 1);
    });
  });

  group('REAL multi-process (Process.start) — cross-process death recovery', () {
    test('a live external process holding the lock is NOT reaped; after it is '
        'killed its leftover is recovered and a new instance token is minted',
        () async {
      final helperFile = File('${dir.path}/helper.dart')
        ..writeAsStringSync(_helperSource);
      final plock = '${dir.path}/db.plock';
      final leasePath = '${dir.path}/leases/ext.lease';
      final ready = '${dir.path}/ready';

      Process helper;
      try {
        helper = await Process.start(
            'dart', [helperFile.path, plock, leasePath, ready]);
      } on ProcessException catch (e) {
        markTestSkipped('dart executable unavailable for Process.start: $e');
        return;
      }
      addTearDown(() {
        try {
          helper.kill(ProcessSignal.sigkill);
        } catch (_) {}
      });

      // Wait for the external process to hold the lock + write its lease.
      for (var i = 0; i < 100 && !File(ready).existsSync(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(File(ready).existsSync(), isTrue, reason: 'helper did not start');
      expect(File(leasePath).existsSync(), isTrue);

      // (1) While the external process is ALIVE, this process CANNOT acquire the
      // exclusive lock — proof of cross-process mutual exclusion — so recovery is
      // withheld and the live process's lease is never reaped.
      final blocked = _liveness(dir).acquire();
      addTearDown(blocked.debugReleaseForTest);
      expect(blocked.acquiredExclusive, isFalse,
          reason: 'external process holds the lock');
      // Recovery is gated on exclusivity, so we do NOT run it here; the lease stays.
      expect(File(leasePath).existsSync(), isTrue,
          reason: 'a live external holder is never reaped');
      blocked.debugReleaseForTest();

      // (2) Kill the external process WITHOUT cleanup. The OS releases its lock.
      helper.kill(ProcessSignal.sigkill);
      await helper.exitCode;

      // (3) A later process start now acquires the exclusive lock (proof the old
      // instance ended) and recovers the leftover; the new instance token differs.
      ProcessLivenessHandle recovered;
      for (var i = 0;; i++) {
        recovered = _liveness(dir).acquire();
        if (recovered.acquiredExclusive || i >= 40) break;
        recovered.debugReleaseForTest();
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      addTearDown(recovered.debugReleaseForTest);
      expect(recovered.acquiredExclusive, isTrue,
          reason: 'the killed process released its OS lock');
      expect(recovered.instanceToken, isNot(blocked.instanceToken),
          reason: 'a restarted process receives a different instance token');

      final cleared = _manager(dir).recoverEndedInstances();
      expect(cleared, greaterThanOrEqualTo(1));
      expect(File(leasePath).existsSync(), isFalse,
          reason: 'the ended instance leftover is recovered at process start');
    });
  });
}
