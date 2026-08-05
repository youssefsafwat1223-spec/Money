import 'dart:io';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/db/database_lease.dart';

// MALI-069n (Batch-4 closure) — the cross-isolate database-use lease (atomic
// intent marker + a file registry of per-secondary leases). Uses a real temp
// directory (no path_provider) and one true cross-isolate test with Isolate.spawn.
void main() {
  late Directory dir;
  late DatabaseLeaseManager mgr;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('mali_lease_');
    mgr = DatabaseLeaseManager(
      leaseDir: '${dir.path}/leases',
      intentPath: '${dir.path}/db.maint',
    );
  });
  tearDown(() => dir.deleteSync(recursive: true));

  test('two shared leases coexist', () async {
    final a = await mgr.acquireShared();
    final b = await mgr.acquireShared();
    addTearDown(() async {
      await a.release();
      await b.release();
    });
    expect(a.isExclusive, isFalse);
    expect(b.isExclusive, isFalse);
    expect(Directory('${dir.path}/leases').listSync().length, 2);
  });

  test('file-exclusive maintenance WAITS for an active shared lease, then proceeds',
      () async {
    final shared = await mgr.acquireShared();
    // Cannot begin file-exclusive maintenance while a shared lease is active.
    await expectLater(
      mgr.acquireExclusive(timeout: const Duration(milliseconds: 150)),
      throwsA(predicate((e) =>
          e is DatabaseLeaseUnavailable && e.reason == 'timeout')),
    );
    await shared.release();
    final exclusive =
        await mgr.acquireExclusive(timeout: const Duration(seconds: 2));
    expect(exclusive.isExclusive, isTrue);
    await exclusive.release();
  });

  test('a NEW shared lease is REFUSED while maintenance intent is active',
      () async {
    final exclusive = await mgr.acquireExclusive();
    addTearDown(exclusive.release);
    await expectLater(
      mgr.acquireShared(),
      throwsA(predicate((e) =>
          e is DatabaseLeaseUnavailable &&
          e.reason == 'maintenance_in_progress')),
    );
  });

  test('releasing exclusive clears intent so shared works again', () async {
    final exclusive = await mgr.acquireExclusive();
    await exclusive.release();
    expect(File('${dir.path}/db.maint').existsSync(), isFalse);
    final shared = await mgr.acquireShared();
    addTearDown(shared.release);
    expect(shared.isExclusive, isFalse);
  });

  test('a STALE lease file does not block maintenance forever', () async {
    Directory('${dir.path}/leases').createSync(recursive: true);
    final stale = File('${dir.path}/leases/crashed.lease')..writeAsStringSync('x');
    stale.setLastModifiedSync(
        DateTime.now().subtract(const Duration(minutes: 5)));
    // The stale lease is recovered → maintenance proceeds.
    final exclusive =
        await mgr.acquireExclusive(timeout: const Duration(seconds: 2));
    addTearDown(exclusive.release);
    expect(exclusive.isExclusive, isTrue);
    expect(stale.existsSync(), isFalse);
  });

  test('a STALE intent marker does not block shared access forever', () async {
    final intent = File('${dir.path}/db.maint')..writeAsStringSync('crashed');
    intent.setLastModifiedSync(
        DateTime.now().subtract(const Duration(minutes: 5)));
    final shared = await mgr.acquireShared();
    addTearDown(shared.release);
    expect(shared.isExclusive, isFalse);
    expect(intent.existsSync(), isFalse);
  });

  test('CROSS-ISOLATE: a shared lease held in ANOTHER isolate blocks exclusive here',
      () async {
    final ready = ReceivePort();
    final done = ReceivePort();
    final isolate = await Isolate.spawn(
      _holdSharedLease,
      ['${dir.path}/leases', '${dir.path}/db.maint', ready.sendPort, done.sendPort],
    );
    final control = await ready.first as SendPort;
    // While the OTHER isolate holds a shared lease, file-exclusive maintenance
    // here cannot proceed (it drains and times out).
    await expectLater(
      mgr.acquireExclusive(timeout: const Duration(milliseconds: 300)),
      throwsA(isA<DatabaseLeaseUnavailable>()),
    );
    control.send('release');
    await done.first;
    // Now maintenance succeeds cross-isolate.
    final exclusive =
        await mgr.acquireExclusive(timeout: const Duration(seconds: 2));
    expect(exclusive.isExclusive, isTrue);
    await exclusive.release();
    ready.close();
    done.close();
    isolate.kill(priority: Isolate.immediate);
  });
}

Future<void> _holdSharedLease(List<Object> args) async {
  final mgr = DatabaseLeaseManager(
      leaseDir: args[0] as String, intentPath: args[1] as String);
  final readyPort = args[2] as SendPort;
  final donePort = args[3] as SendPort;
  final lease = await mgr.acquireShared();
  final control = ReceivePort();
  readyPort.send(control.sendPort);
  await control.first;
  await lease.release();
  control.close();
  donePort.send('released');
}
