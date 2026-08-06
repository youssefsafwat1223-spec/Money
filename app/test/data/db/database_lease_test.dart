import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/db/database_lease.dart';

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

// MALI-069n (Batch-4 closure #3) — the cross-isolate database-use lease.
//   * Blocker 2: renewable heartbeat/fencing — a live operation is never
//     false-reaped, and only the token owner may remove a file.
//   * Blocker 3: the shared-acquire vs maintenance-intent race is impossible.
// Fast, deterministic timings (real timers, temp filesystem state).

DatabaseLeaseManager _manager(Directory dir) => DatabaseLeaseManager(
      leaseDir: '${dir.path}/leases',
      intentPath: '${dir.path}/db.maint',
      leaseTtl: const Duration(milliseconds: 400),
      heartbeatInterval: const Duration(milliseconds: 90),
      settleWindow: const Duration(milliseconds: 60),
      pollStep: const Duration(milliseconds: 15),
    );

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('mali_lease_'));
  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  group('Blocker 2 — renewable heartbeat / fencing', () {
    test('two secondaries coexist normally', () async {
      final m = _manager(dir);
      final a = await m.acquireShared();
      final b = await m.acquireShared();
      expect(m.debugLiveLeaseCount(), 2);
      await a.release();
      await b.release();
      expect(m.debugLiveLeaseCount(), 0);
    });

    test('a long secondary operation exceeds the old stale threshold but stays '
        'protected by its heartbeat (maintenance keeps waiting)', () async {
      final m = _manager(dir);
      final lease = await m.acquireShared();
      // Hold well past leaseTtl (400ms) — the heartbeat must keep it live.
      await Future<void>.delayed(const Duration(milliseconds: 700));
      expect(m.debugLiveLeaseCount(), 1, reason: 'heartbeat kept it live');
      // Maintenance still cannot acquire while this live lease exists.
      await expectLater(
        m.acquireExclusive(timeout: const Duration(milliseconds: 200)),
        throwsA(isA<DatabaseLeaseUnavailable>()),
      );
      await lease.release();
      expect(m.debugLiveLeaseCount(), 0);
    });

    test('a long maintenance exceeds the old stale threshold but still blocks '
        'new secondaries', () async {
      final m = _manager(dir);
      final exclusive = await m.acquireExclusive();
      await Future<void>.delayed(const Duration(milliseconds: 700));
      // Intent heartbeat kept it live → a new secondary is still refused.
      await expectLater(
        m.acquireShared(),
        throwsA(isA<DatabaseLeaseUnavailable>()),
      );
      expect(await m.debugIntentLive(), isTrue);
      await exclusive.release();
      expect(await m.debugIntentLive(), isFalse);
    });

    test('maintenance timeout is typed and bounded when a live lease never '
        'drains', () async {
      final m = _manager(dir);
      final lease = await m.acquireShared();
      final started = DateTime.now();
      await expectLater(
        m.acquireExclusive(timeout: const Duration(milliseconds: 150)),
        throwsA(isA<DatabaseLeaseUnavailable>()
            .having((e) => e.reason, 'reason', 'timeout')),
      );
      // Bounded — did not hang far past the timeout.
      expect(DateTime.now().difference(started).inMilliseconds, lessThan(2000));
      await lease.release();
    });

    test('an old cleanup token cannot remove a newer replacement at the same '
        'path (fencing)', () async {
      final f = File('${dir.path}/db.maint');
      await f.writeAsString('NEW-token');
      // A stale holder that still thinks it owns "OLD-token" tries to clean up.
      await DatabaseLeaseManager.deleteIfTokenForTest(f, 'OLD-token');
      expect(f.existsSync(), isTrue, reason: 'wrong token must not delete');
      // Only the true owner removes it.
      await DatabaseLeaseManager.deleteIfTokenForTest(f, 'NEW-token');
      expect(f.existsSync(), isFalse);
    });

    test('release stops the heartbeat and does not resurrect the file '
        '(no leaked timer/lease file)', () async {
      final m = _manager(dir);
      final lease = await m.acquireShared();
      final path = '${dir.path}/leases';
      expect(Directory(path).listSync().whereType<File>().length, 1);
      await lease.release();
      final after = Directory(path).listSync().whereType<File>().length;
      expect(after, 0);
      // Wait > heartbeat: a leaked timer would touch/recreate a file.
      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(Directory(path).listSync().whereType<File>().length, 0,
          reason: 'heartbeat was cancelled — nothing resurrected');
    });

    test('a crashed holder file (heartbeat stopped) is recovered after ttl',
        () async {
      final m = _manager(dir);
      // Simulate a killed holder: a lease file with a stale mtime, no heartbeat.
      final leaseDir = Directory('${dir.path}/leases')..createSync(recursive: true);
      final stale = File('${leaseDir.path}/999_0_0.lease');
      await stale.writeAsString('dead-token');
      stale.setLastModifiedSync(
          DateTime.now().subtract(const Duration(seconds: 5)));
      expect(m.debugLiveLeaseCount(), 0, reason: 'stale is not counted live');
      // Maintenance recovers past the crashed holder.
      final exclusive =
          await m.acquireExclusive(timeout: const Duration(seconds: 2));
      await exclusive.release();
    });
  });

  group('Blocker 3 — no shared-acquire vs maintenance-intent race', () {
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
      // The aborted secondary left no lease behind.
      final leaseDir = Directory('${dir.path}/leases');
      final leftover = leaseDir.existsSync()
          ? leaseDir.listSync().whereType<File>().length
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
          ? leaseDir.listSync().whereType<File>().length
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
        // Invariant: at the moment exclusivity is granted, zero live leases.
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

    test('repeated shared-vs-exclusive race across a real isolate has zero '
        'overlap', () async {
      final m = _manager(dir);
      Directory('${dir.path}/leases').createSync(recursive: true);
      final ctrl = ReceivePort();
      final worker = await Isolate.spawn(_hammerShared, [
        ctrl.sendPort,
        '${dir.path}/leases',
        '${dir.path}/db.maint',
      ]);
      final inbox = _Inbox(ctrl);
      final SendPort stop = await inbox.next() as SendPort; // worker ready

      // Interleave maintenance rounds against the hammering isolate.
      for (var i = 0; i < 14; i++) {
        final ex = await m.acquireExclusive(timeout: const Duration(seconds: 3));
        expect(m.debugLiveLeaseCount(), 0,
            reason: 'no shared lease may exist inside exclusivity (round $i)');
        await Future<void>.delayed(const Duration(milliseconds: 12));
        await ex.release();
        await Future<void>.delayed(const Duration(milliseconds: 12));
      }

      stop.send('stop');
      await inbox.next(); // worker acked stop
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
      final SendPort release = await inbox.next() as SendPort; // "holding"

      // Maintenance cannot proceed while the other isolate holds a shared lease.
      await expectLater(
        m.acquireExclusive(timeout: const Duration(milliseconds: 250)),
        throwsA(isA<DatabaseLeaseUnavailable>()),
      );

      release.send('release');
      await inbox.next(); // "released"
      // Now maintenance succeeds.
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
      leaseTtl: const Duration(milliseconds: 400),
      heartbeatInterval: const Duration(milliseconds: 90),
      settleWindow: const Duration(milliseconds: 60),
      pollStep: const Duration(milliseconds: 15),
    );

/// Continuously acquire+hold+release shared leases until told to stop. Refusals
/// during maintenance are expected and retried.
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

/// Acquire ONE shared lease, hold it (heartbeat alive), release on command.
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
  out.send(cmd.sendPort); // "holding"
}
