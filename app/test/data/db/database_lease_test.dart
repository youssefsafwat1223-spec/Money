import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/db/database_lease.dart';

// MALI-069n (Batch-4 closure #4) — the cross-isolate lease under Contract B.
// Heartbeat/mtime is NO LONGER an authority: liveness = record existence; runtime
// maintenance never reaps (typed bounded timeout); the only reaping is process-
// start recovery. Records are immutable + atomic. Deterministic timings.

/// Minimal sequential inbox over a ReceivePort (avoids a package:async dep).
class _Inbox {
  _Inbox(ReceivePort port) {
    port.listen((m) {
      _buffer.add(m);
      _drain();
    });
  }
  final List<dynamic> _buffer = [];
  Completer<dynamic>? _waiter;
  void _drain() {
    final w = _waiter;
    if (w != null && _buffer.isNotEmpty) {
      _waiter = null;
      w.complete(_buffer.removeAt(0));
    }
  }

  Future<dynamic> next() {
    final c = Completer<dynamic>();
    _waiter = c;
    _drain();
    return c.future;
  }
}

DatabaseLeaseManager _manager(Directory dir) => DatabaseLeaseManager(
      leaseDir: '${dir.path}/leases',
      intentPath: '${dir.path}/db.maint',
      settleWindow: const Duration(milliseconds: 40),
      pollStep: const Duration(milliseconds: 15),
    );

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('mali_lease_'));
  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  group('no runtime reaping — a live holder is never reaped (heartbeat removed)',
      () {
    test('two secondaries coexist normally', () async {
      final m = _manager(dir);
      final a = await m.acquireShared();
      final b = await m.acquireShared();
      expect(m.debugLiveLeaseCount(), 2);
      await a.release();
      await b.release();
      expect(m.debugLiveLeaseCount(), 0);
    });

    test('a holder that NEVER releases (a blocked/paused isolate) is not reaped; '
        'maintenance returns a typed bounded timeout; releasing lets it proceed',
        () async {
      final m = _manager(dir);
      final lease = await m.acquireShared();
      final started = DateTime.now();
      await expectLater(
        m.acquireExclusive(timeout: const Duration(milliseconds: 150)),
        throwsA(isA<DatabaseLeaseUnavailable>()
            .having((e) => e.reason, 'reason', 'timeout')),
      );
      expect(DateTime.now().difference(started).inMilliseconds, lessThan(3000));
      expect(m.debugLiveLeaseCount(), 1, reason: 'never reaped');
      await lease.release();
      final ok = await m.acquireExclusive(timeout: const Duration(seconds: 2));
      await ok.release();
    });

    test('lease age / clock anomalies never authorize deletion (existence, not '
        'mtime, is liveness)', () async {
      final m = _manager(dir);
      final lease = await m.acquireShared();
      final leaseFile = Directory('${dir.path}/leases')
          .listSync()
          .whereType<File>()
          .firstWhere((f) => f.path.endsWith('.lease'));
      // Forward jump: pretend the record is ancient. Backward jump: pretend future.
      leaseFile.setLastModifiedSync(
          DateTime.now().subtract(const Duration(days: 365)));
      expect(m.debugLiveLeaseCount(), 1);
      leaseFile.setLastModifiedSync(
          DateTime.now().add(const Duration(days: 365)));
      expect(m.debugLiveLeaseCount(), 1);
      // Maintenance still refuses to reap and times out.
      await expectLater(
        m.acquireExclusive(timeout: const Duration(milliseconds: 120)),
        throwsA(isA<DatabaseLeaseUnavailable>()),
      );
      await lease.release();
    });

    test('an empty/partial record is treated as live/unknown — never deleted at '
        'runtime', () async {
      final m = _manager(dir);
      final leaseDir = Directory('${dir.path}/leases')..createSync(recursive: true);
      final partial = File('${leaseDir.path}/p.lease')..writeAsStringSync('');
      // Fencing delete refuses a malformed record.
      await DatabaseLeaseManager.deleteIfTokenForTest(partial, 'anytoken');
      expect(partial.existsSync(), isTrue);
      // Counted as live (existence) → maintenance waits it out → typed timeout.
      expect(m.debugLiveLeaseCount(), 1);
      await expectLater(
        m.acquireExclusive(timeout: const Duration(milliseconds: 120)),
        throwsA(isA<DatabaseLeaseUnavailable>()),
      );
    });

    test('an old cleanup token cannot remove a newer replacement (fencing)',
        () async {
      final f = File('${dir.path}/db.maint');
      await f.writeAsString('NEW-token\n123\ninst');
      await DatabaseLeaseManager.deleteIfTokenForTest(f, 'OLD-token');
      expect(f.existsSync(), isTrue);
      await DatabaseLeaseManager.deleteIfTokenForTest(f, 'NEW-token');
      expect(f.existsSync(), isFalse);
    });

    test('release removes the record — no leaked lease file', () async {
      final m = _manager(dir);
      final lease = await m.acquireShared();
      final path = '${dir.path}/leases';
      expect(Directory(path).listSync().whereType<File>().length, 1);
      await lease.release();
      expect(Directory(path).listSync().whereType<File>().length, 0);
    });
  });

  group('runtime never reaps even an ended-instance leftover; startup recovery '
      'does', () {
    test('a different-pid leftover blocks runtime maintenance (timeout) but is '
        'cleared by process-start recovery', () async {
      final leaseDir = Directory('${dir.path}/leases')..createSync(recursive: true);
      File('${leaseDir.path}/999_0_z.lease')
          .writeAsStringSync('tok\n424242\nended-inst');
      final m = _manager(dir); // ownerPid = current pid (differs from 424242)
      // Runtime maintenance does NOT reap it — even though the pid differs — it
      // times out (safe).
      await expectLater(
        m.acquireExclusive(timeout: const Duration(milliseconds: 120)),
        throwsA(isA<DatabaseLeaseUnavailable>()),
      );
      // Startup recovery (process-lock-gated in production) clears the ended
      // instance's leftover, then maintenance proceeds.
      expect(m.recoverEndedInstances(), 1);
      final ok = await m.acquireExclusive(timeout: const Duration(seconds: 2));
      await ok.release();
    });
  });

  group('shared-acquire vs maintenance-intent race (two-phase)', () {
    test('intent that appears BETWEEN the pre-check and lease creation is caught '
        'by the phase-3 re-check (shared aborts, no lease left)', () async {
      final m = _manager(dir);
      DatabaseFileLease? intent;
      await expectLater(
        m.acquireSharedWithHooks(afterPrecheck: () async {
          intent = await m.publishIntentOnly();
        }),
        throwsA(isA<DatabaseLeaseUnavailable>()),
      );
      addTearDown(() async => intent?.release());
      final leaseDir = Directory('${dir.path}/leases');
      final leftover = leaseDir.existsSync()
          ? leaseDir.listSync().whereType<File>().where((f) => f.path.endsWith('.lease')).length
          : 0;
      expect(leftover, 0);
    });

    test('intent that appears immediately AFTER lease creation is caught by the '
        'phase-3 re-check (shared aborts, no lease left)', () async {
      final m = _manager(dir);
      DatabaseFileLease? intent;
      await expectLater(
        m.acquireSharedWithHooks(afterCreate: () async {
          intent = await m.publishIntentOnly();
        }),
        throwsA(isA<DatabaseLeaseUnavailable>()),
      );
      addTearDown(() async => intent?.release());
      final leaseDir = Directory('${dir.path}/leases');
      final leftover = leaseDir.existsSync()
          ? leaseDir.listSync().whereType<File>().where((f) => f.path.endsWith('.lease')).length
          : 0;
      expect(leftover, 0);
    });

    test('maintenance never enters exclusivity while a live shared lease exists',
        () async {
      final m = _manager(dir);
      final shared = await m.acquireShared();
      var entered = false;
      final fut = m.acquireExclusive(timeout: const Duration(seconds: 2)).then((ex) {
        entered = true;
        expect(m.debugLiveLeaseCount(), 0);
        return ex;
      });
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(entered, isFalse, reason: 'blocked by the live shared lease');
      await shared.release();
      final ex = await fut;
      expect(entered, isTrue);
      await ex.release();
    });

    test('repeated shared-vs-exclusive race across a real isolate has zero overlap',
        () async {
      final m = _manager(dir);
      Directory('${dir.path}/leases').createSync(recursive: true);
      final ctrl = ReceivePort();
      final worker = await Isolate.spawn(_hammerShared, [
        ctrl.sendPort,
        '${dir.path}/leases',
        '${dir.path}/db.maint',
      ]);
      final inbox = _Inbox(ctrl);
      final SendPort stop = await inbox.next() as SendPort;
      for (var i = 0; i < 14; i++) {
        final ex = await m.acquireExclusive(timeout: const Duration(seconds: 3));
        expect(m.debugLiveLeaseCount(), 0,
            reason: 'no shared lease may exist inside exclusivity (round $i)');
        await Future<void>.delayed(const Duration(milliseconds: 12));
        await ex.release();
        await Future<void>.delayed(const Duration(milliseconds: 12));
      }
      stop.send('stop');
      await inbox.next();
      worker.kill(priority: Isolate.immediate);
      ctrl.close();
    });

    test('a shared lease held in ANOTHER isolate blocks exclusive maintenance in '
        'the main isolate (cross-isolate)', () async {
      final m = _manager(dir);
      Directory('${dir.path}/leases').createSync(recursive: true);
      final ctrl = ReceivePort();
      final worker = await Isolate.spawn(_holdShared, [
        ctrl.sendPort,
        '${dir.path}/leases',
        '${dir.path}/db.maint',
      ]);
      final inbox = _Inbox(ctrl);
      final SendPort release = await inbox.next() as SendPort;
      await expectLater(
        m.acquireExclusive(timeout: const Duration(milliseconds: 250)),
        throwsA(isA<DatabaseLeaseUnavailable>()),
      );
      release.send('release');
      await inbox.next();
      final ex = await m.acquireExclusive(timeout: const Duration(seconds: 2));
      await ex.release();
      worker.kill(priority: Isolate.immediate);
      ctrl.close();
    });
  });
}

// ── Isolate entry points ────────────────────────────────────────────────────

DatabaseLeaseManager _isolateManager(String leaseDir, String intentPath) =>
    DatabaseLeaseManager(
      leaseDir: leaseDir,
      intentPath: intentPath,
      settleWindow: const Duration(milliseconds: 40),
      pollStep: const Duration(milliseconds: 15),
    );

Future<void> _hammerShared(List<dynamic> args) async {
  final SendPort out = args[0] as SendPort;
  final m = _isolateManager(args[1] as String, args[2] as String);
  final cmd = ReceivePort();
  var running = true;
  cmd.listen((msg) {
    if (msg == 'stop') running = false;
  });
  out.send(cmd.sendPort);
  while (running) {
    try {
      final lease = await m.acquireShared();
      await Future<void>.delayed(const Duration(milliseconds: 4));
      await lease.release();
    } on DatabaseLeaseUnavailable {
      await Future<void>.delayed(const Duration(milliseconds: 4));
    } catch (_) {
      await Future<void>.delayed(const Duration(milliseconds: 4));
    }
  }
  out.send('stopped');
  cmd.close();
}

Future<void> _holdShared(List<dynamic> args) async {
  final SendPort out = args[0] as SendPort;
  final m = _isolateManager(args[1] as String, args[2] as String);
  final lease = await m.acquireShared();
  final cmd = ReceivePort();
  cmd.listen((msg) async {
    if (msg == 'release') {
      await lease.release();
      out.send('released');
      cmd.close();
    }
  });
  out.send(cmd.sendPort);
}
