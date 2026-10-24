// ignore_for_file: depend_on_referenced_packages
import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/db/database_access_broker.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/session/f2_fixture.dart';

// O-BX (B2): the atomic quiescing transition against REAL, independently
// scheduled Dart isolates that hold a REAL encrypted (sqlite3mc) database file
// through the broker's genuine `client.open` path. All coordination is by
// SendPort; no shared flag stands in for cross-isolate exclusion.
//
// Not covered here (needs a platform run): Flutter engine recreation and
// foreground/background engine overlap. The encrypted file is sqlite3mc keyed with
// a test key; the application's own SQLCipher key store is not involved.

/// Worker: `[client, report, dbPath, failClose]`. Commands arrive on its control
/// port as strings: finishOpen, beginTx, commitTx, close, finishClose.
Future<void> _holderIsolate(List<dynamic> args) async {
  final client = args[0] as DatabaseBrokerClient;
  final report = args[1] as SendPort;
  final path = args[2] as String;
  final failClose = args[3] as bool;
  final holdOpen = args[4] as bool;
  final control = ReceivePort();
  final commands = StreamIterator<dynamic>(control);
  report.send(['control', control.sendPort]);
  Future<void> expect(String command) async {
    while (await commands.moveNext()) {
      if (commands.current == command) return;
    }
  }

  try {
    final holder = await client.open<Database>(
      open: () async {
        report.send(['openAttempt']);
        if (holdOpen) await expect('finishOpen');
        final db = sqlite3.open(path, mode: OpenMode.readWrite);
        db.execute("PRAGMA key = 'o-bx-test-key';");
        db.execute('SELECT count(*) FROM sqlite_master;');
        report.send(['opened']);
        return db;
      },
      close: (db) async {
        report.send(['closeAttempt']);
        await expect('finishClose');
        if (failClose) {
          report.send(['closeFailed']);
          throw StateError('close failed');
        }
        db.dispose();
        report.send(['physicalClosed']);
      },
    );
    report.send(['published']);
    while (true) {
      await commands.moveNext();
      final command = commands.current;
      if (command == 'beginTx') {
        holder.value.execute('BEGIN IMMEDIATE;');
        holder.value.execute("INSERT INTO t(v) VALUES ('held');");
        report.send(['txOpen']);
      } else if (command == 'commitTx') {
        holder.value.execute('COMMIT;');
        report.send(['txCommitted']);
      } else if (command == 'close') {
        break;
      }
    }
    try {
      await holder.close();
      report.send(['closed']);
    } catch (_) {
      report.send(['closeThrew']);
    }
  } catch (error) {
    report.send(['refused', error.toString()]);
  } finally {
    await commands.cancel();
    control.close();
  }
}

class _Worker {
  _Worker(this.isolate, this.reports, this.events, this.control);
  final Isolate isolate;
  final ReceivePort reports;
  final StreamIterator<dynamic> events;
  final SendPort control;

  static Future<_Worker> spawn(DatabaseBrokerClient client, String path,
      {bool failClose = false, bool holdOpen = false}) async {
    final reports = ReceivePort();
    final events = StreamIterator<dynamic>(reports);
    final isolate = await Isolate.spawn(
        _holderIsolate, [client, reports.sendPort, path, failClose, holdOpen]);
    await events.moveNext();
    return _Worker(isolate, reports, events, events.current[1] as SendPort);
  }

  void send(String command) => control.send(command);

  /// Waits for the next report named [name] (others are skipped).
  Future<List<dynamic>> until(String name) async {
    while (await events.moveNext().timeout(const Duration(seconds: 20))) {
      final event = events.current as List<dynamic>;
      if (event[0] == name) return event;
    }
    throw StateError('worker ended before $name');
  }

  Future<void> dispose() async {
    isolate.kill(priority: Isolate.immediate);
    await events.cancel();
    reports.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late F2Fixture fixture;
  late SupabaseClient sdk;
  late DatabaseAccessBroker broker;
  late Directory scratch;
  var firstSdkBinding = true;
  final workers = <_Worker>[];

  Future<void> publishSdkAdmission() async {
    final admissionSdk = sdk.auth.currentSession;
    expect(admissionSdk, isNotNull,
        reason: 'SDK session exists before admission');
    expect(admissionSdk!.isExpired, isFalse, reason: 'SDK admission is fresh');
    bool current() {
      final actual = sdk.auth.currentSession;
      return actual != null &&
          !actual.isExpired &&
          actual.user.id == admissionSdk.user.id &&
          actual.accessToken == admissionSdk.accessToken;
    }

    await fixture.session.setIdentity(
      method: 'apple',
      email: admissionSdk.user.email,
      userId: admissionSdk.user.id,
      sessionCurrent: current,
    );
    await fixture.session.finishOnboarding(client: sdk);
    if (firstSdkBinding) {
      // GoTrue replays its cached recovery event on subscription. The direct
      // bind reconcile can finish before that real event's ownership lane.
      // Wait its actual completion; neither a delay nor authenticated status
      // alone establishes that the removal/admission checks have settled.
      final cachedEventSettled = Completer<void>();
      fixture.session.debugAuthEventCompleted = (event) {
        if (event == AuthChangeEvent.tokenRefreshed &&
            !cachedEventSettled.isCompleted) {
          cachedEventSettled.complete();
        }
      };
      try {
        await fixture.session.bindSupabaseAuth(sdk);
        await cachedEventSettled.future;
      } finally {
        fixture.session.debugAuthEventCompleted = null;
      }
      firstSdkBinding = false;
    } else {
      await fixture.session.bindSupabaseAuth(sdk);
    }
    expect(fixture.flow.isRunning, isFalse,
        reason: 'Real removal admission checks settled');
    expect(current(), isTrue,
        reason: 'Actual SDK remains current after publication');
    expect(fixture.session.status.name, 'authenticated',
        reason: 'Committed status');
    expect(fixture.session.hasCompletedOnboarding, isTrue,
        reason: 'Committed onboarding');
    expect(fixture.session.isGuest, isFalse,
        reason: 'Authenticated host is not a guest');
    final scope = fixture.host.current;
    expect(scope, isNotNull, reason: 'Actual scope is published');
    expect(scope!.uid == admissionSdk.user.id, isTrue,
        reason: 'Exact scope owner');
    expect(scope.database.isReadOnly, isFalse, reason: 'Writable scope');
    expect(scope.database.admitsSecondary, isTrue,
        reason: 'Actual database is usable');
  }

  setUpAll(() async {
    fixture = await F2Fixture.create();
    fixture.session.configureAccountScope(fixture.host);
    sdk = await fixture.clientFor('exclusion-owner');
    await publishSdkAdmission();
    final receipt = fixture.session.captureDatabaseHostAdmission();
    expect(receipt, isNotNull);
    broker = DatabaseAccessBroker.start(receipt!);
    scratch = Directory.systemTemp.createTempSync('o_bx_exclusion_');
  });

  tearDownAll(() async {
    await fixture.dispose();
    await sdk.dispose();
    scratch.deleteSync(recursive: true);
  });

  late String dbPath;
  late Directory replicaDir;
  var n = 0;

  setUp(() async {
    broker.debugClearLedgerForTest();
    final receipt = fixture.session.captureDatabaseHostAdmission();
    await broker.transition(DatabaseAccessMode.writable, admission: receipt);
    replicaDir = Directory(p.join(scratch.path, 'replica${n++}'))..createSync();
    dbPath = p.join(replicaDir.path, 'replica.sqlite');
    final db = sqlite3.open(dbPath);
    db.execute("PRAGMA key = 'o-bx-test-key';");
    db.execute('CREATE TABLE t(v TEXT);');
    db.dispose();
  });

  tearDown(() async {
    for (final w in workers) {
      await w.dispose();
    }
    workers.clear();
  });

  Future<_Worker> holderWorker({
    DatabaseBrokerClient? client,
    bool failClose = false,
    bool holdOpen = false,
  }) async {
    final w = await _Worker.spawn(client ?? broker.client, dbPath,
        failClose: failClose, holdOpen: holdOpen);
    workers.add(w);
    return w;
  }

  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 150));

  test('a secondary writer held open in another isolate blocks until its '
      'PHYSICAL close; only then is exclusion verifiable', () async {
    final w = await holderWorker();
    await w.until('published');
    expect(broker.openHolders, 1);
    final exclusion = broker.beginLocalReadExclusion();
    expect(broker.mode, DatabaseAccessMode.quiescing);
    var drained = false;
    final drain = exclusion.awaitDrained().then((_) => drained = true);
    await settle();
    expect(drained, isFalse);
    expect(() => exclusion.verifyLegacyHolders(LegacyHolderEvidence.clear),
        throwsA(isA<DatabaseAccessUnavailable>()),
        reason: 'not drained: evidence is not even considered');
    expect(
        () => exclusion.reserveLocalReadCandidate(uid: 'u'),
        throwsA(isA<DatabaseAccessUnavailable>()));
    w.send('close');
    await w.until('closeAttempt');
    await settle();
    expect(drained, isFalse, reason: 'close started but is not acknowledged');
    expect(broker.openHolders, 1);
    w.send('finishClose');
    await w.until('physicalClosed');
    await w.until('closed');
    await drain;
    expect(broker.openHolders, 0);
    exclusion.release(published: false);
  });

  test('an opening secondary (pending open) is drained; its late publication '
      'is refused and its handle must still be closed', () async {
    final w = await holderWorker(holdOpen: true);
    await w.until('openAttempt');
    expect(broker.pendingOpens, 1);
    final exclusion = broker.beginLocalReadExclusion();
    var drained = false;
    final drain = exclusion.awaitDrained().then((_) => drained = true);
    w.send('finishOpen');
    await w.until('opened');
    await w.until('closeAttempt'); // publication denied -> the loser closes
    await settle();
    expect(drained, isFalse, reason: 'the loser handle is still open');
    expect(broker.openHolders, 1);
    w.send('finishClose');
    await w.until('physicalClosed');
    final refused = await w.until('refused');
    expect(refused[1], contains('publication_denied'));
    await drain;
    exclusion.release(published: false);
  });

  test('an active transaction in another isolate is a real writer: drain waits '
      'for its end and close', () async {
    final w = await holderWorker();
    await w.until('published');
    w.send('beginTx');
    await w.until('txOpen');
    final probe = sqlite3.open(dbPath, mode: OpenMode.readWrite);
    probe.execute("PRAGMA key = 'o-bx-test-key';");
    probe.execute('PRAGMA busy_timeout = 0;');
    expect(() => probe.execute("INSERT INTO t(v) VALUES ('x');"),
        throwsA(isA<SqliteException>()),
        reason: 'the other isolate really holds the write lock');
    probe.dispose();
    final exclusion = broker.beginLocalReadExclusion();
    var drained = false;
    final drain = exclusion.awaitDrained().then((_) => drained = true);
    await settle();
    expect(drained, isFalse);
    w.send('commitTx');
    await w.until('txCommitted');
    await settle();
    expect(drained, isFalse, reason: 'ending the transaction is not closing');
    w.send('close');
    await w.until('closeAttempt');
    w.send('finishClose');
    await w.until('closed');
    await drain;
    exclusion.release(published: false);
  });

  test('a failed close never acknowledges: timeout, holder kept, quiescing, '
      'no candidate', () async {
    final w = await holderWorker(failClose: true);
    await w.until('published');
    final exclusion = broker.beginLocalReadExclusion();
    final drain = exclusion.awaitDrained(
        timeout: const Duration(milliseconds: 400));
    final expectation = expectLater(drain,
        throwsA(isA<DatabaseAccessUnavailable>().having(
            (e) => e.reason, 'reason', 'cleanup_incomplete')));
    w.send('close');
    await w.until('closeAttempt');
    w.send('finishClose');
    await w.until('closeFailed');
    await expectation;
    expect(broker.openHolders, 1, reason: 'unknown physical state is kept');
    expect(() => exclusion.reserveLocalReadCandidate(uid: 'u'),
        throwsA(isA<DatabaseAccessUnavailable>()));
    exclusion.release(published: false);
    expect(broker.mode, DatabaseAccessMode.quiescing,
        reason: 'an uncertain holder never returns to closed');
  });

  test('R7: after a timed-out restoration released its exclusion, a real '
      'holder keeps the coordinator quiescing for every persistent path until '
      'it physically closes AND the explicit recovery runs', () async {
    final issued = broker.client; // a job issued BEFORE the transition
    final w = await holderWorker();
    await w.until('published');
    final exclusion = broker.beginLocalReadExclusion();
    await expectLater(
        exclusion.awaitDrained(timeout: const Duration(milliseconds: 200)),
        throwsA(isA<DatabaseAccessUnavailable>()));
    exclusion.release(published: false);
    expect(broker.mode, DatabaseAccessMode.quiescing);

    void expectDenied() {
      expect(
          () => broker.reserveAdmissionOpen(
              uid: 'u', admissionIdentity: Object(), lossGeneration: 0),
          throwsA(isA<DatabaseAccessUnavailable>()));
      expect(
          () => broker.reserveColdLaunchOpen(
              uid: 'u', launchIdentity: Object(), lossGeneration: 0),
          throwsA(isA<DatabaseAccessUnavailable>()));
    }

    Future<void> expectJobsRefused() async {
      var attempts = 0;
      for (final client in [issued, broker.client]) {
        await expectLater(
            client.open<int>(
                open: () async {
                  attempts++;
                  return 1;
                },
                close: (_) async {}),
            throwsA(isA<DatabaseAccessUnavailable>()));
      }
      expect(attempts, 0, reason: 'stale or new job: no opener ran');
    }

    expectDenied();
    await expectJobsRefused();
    expect(broker.recoverFromQuiescing(), isFalse,
        reason: 'the real holder is still open');

    // The late physical close with its own generation acknowledges the holder.
    w.send('close');
    await w.until('closeAttempt');
    w.send('finishClose');
    await w.until('physicalClosed');
    await w.until('closed');
    expect(broker.openHolders, 0);
    expect(broker.mode, DatabaseAccessMode.quiescing,
        reason: 'the late close alone never reopens admission');
    expectDenied();
    await expectJobsRefused();

    expect(broker.recoverFromQuiescing(), isTrue);
    expect(broker.mode, DatabaseAccessMode.closed,
        reason: 'recovered to closed, never to writable');
    await expectJobsRefused(); // the old job stays stale; no writer was granted
  });

  test('a dead / unresponsive holder is never assumed gone', () async {
    final w = await holderWorker();
    await w.until('published');
    w.isolate.kill(priority: Isolate.immediate);
    final exclusion = broker.beginLocalReadExclusion();
    await expectLater(
        exclusion.awaitDrained(timeout: const Duration(milliseconds: 300)),
        throwsA(isA<DatabaseAccessUnavailable>()));
    expect(broker.openHolders, 1);
    exclusion.release(published: false);
    expect(broker.mode, DatabaseAccessMode.quiescing);
  });

  test('reservation versus quiesce: an issued job client is refused once the '
      'transition is owned, and in-process reservations too', () async {
    final issued = broker.client; // issued BEFORE the transition
    final exclusion = broker.beginLocalReadExclusion();
    var attempts = 0;
    await expectLater(
        issued.open<int>(
            open: () async {
              attempts++;
              return 1;
            },
            close: (_) async {}),
        throwsA(isA<DatabaseAccessUnavailable>()));
    expect(attempts, 0);
    for (final reserve in <void Function()>[
      () => broker.reserveAdmissionOpen(
          uid: 'u', admissionIdentity: Object(), lossGeneration: 0),
      () => broker.reserveColdLaunchOpen(
          uid: 'u', launchIdentity: Object(), lossGeneration: 0),
    ]) {
      expect(reserve, throwsA(isA<DatabaseAccessUnavailable>()));
    }
    expect(broker.reserveEphemeral, returnsNormally);
    expect(() => broker.beginLocalReadExclusion(),
        throwsA(isA<DatabaseAccessUnavailable>()),
        reason: 'one owner at a time');
    await expectLater(
        broker.transition(DatabaseAccessMode.closed),
        throwsA(isA<DatabaseAccessUnavailable>()));
    exclusion.release(published: false);
  });

  test('forged or other-generation close acknowledgements are refused and '
      'release nothing', () async {
    final w = await holderWorker();
    await w.until('published');
    final exclusion = broker.beginLocalReadExclusion();
    final reply = ReceivePort();
    for (final generation in [0, 1, 999]) {
      broker.endpoint.send([
        'closed',
        broker.processNonce,
        generation,
        'not-a-holder-token',
        Capability(),
        reply.sendPort
      ]);
    }
    final answers = await reply.take(3).toList();
    expect(answers.every((a) => (a as List).first == 'denied'), isTrue);
    reply.close();
    expect(broker.openHolders, 1);
    // The real holder, issued before the generation change, can still prove its
    // own cleanup with exactly its own generation.
    w.send('close');
    await w.until('closeAttempt');
    w.send('finishClose');
    await w.until('closed');
    await exclusion.awaitDrained();
    exclusion.release(published: false);
  });

  test('legacy / unknown holder evidence denies; missing evidence is not '
      'clear; the check creates nothing', () async {
    List<String> tree() => [
          for (final e in replicaDir.listSync(recursive: true))
            p.relative(e.path, from: replicaDir.path),
        ]..sort();
    final lease = p.join(replicaDir.path, 'db_leases');
    final intent = '$dbPath.maint';
    LegacyHolderEvidence inspect() => LegacyHolderEvidence.inspect(
        replicaDirectory: replicaDir.path, leaseDir: lease, intentPath: intent);
    final before = tree();
    expect(inspect().isClear, isTrue, reason: 'no lease directory ever made');
    expect(tree(), before, reason: 'zero lease/key/salt/sidecar creation');

    Directory(lease).createSync();
    expect(inspect().isClear, isTrue, reason: 'present but empty');
    File(p.join(lease, '1_0_x.lease')).writeAsStringSync('t\n1\ni');
    expect(inspect().isClear, isFalse, reason: 'a lease exists');
    File(p.join(lease, '1_0_x.lease')).deleteSync();
    File(p.join(lease, '1_0_y.lease.tmp')).writeAsStringSync('');
    expect(inspect().isClear, isFalse, reason: 'half-published record');
    File(p.join(lease, '1_0_y.lease.tmp')).deleteSync();
    File(intent).writeAsStringSync('t\n1\ni');
    expect(inspect().isClear, isFalse, reason: 'maintenance intent');
    File(intent).deleteSync();
    Directory(lease).deleteSync();
    File(lease).writeAsStringSync('x');
    expect(inspect().isClear, isFalse, reason: 'a file where a directory belongs');
    File(lease).deleteSync();
    expect(
        LegacyHolderEvidence.inspect(
                replicaDirectory: p.join(scratch.path, 'nonexistent'),
                leaseDir: lease,
                intentPath: intent)
            .isClear,
        isFalse,
        reason: 'no replica directory: unknown, not clear');
    expect(tree(), before);
  });

  test('the candidate reservation exists only after drain AND clear evidence, '
      'once, and survives publication until the next generation', () async {
    final exclusion = broker.beginLocalReadExclusion();
    expect(() => exclusion.reserveLocalReadCandidate(uid: 'u'),
        throwsA(isA<DatabaseAccessUnavailable>()), reason: 'not drained');
    await exclusion.awaitDrained();
    expect(() => exclusion.reserveLocalReadCandidate(uid: 'u'),
        throwsA(isA<DatabaseAccessUnavailable>()), reason: 'no evidence');
    expect(() => exclusion.verifyLegacyHolders(LegacyHolderEvidence.unknown),
        throwsA(isA<DatabaseAccessUnavailable>()));
    expect(() => exclusion.reserveLocalReadCandidate(uid: 'u'),
        throwsA(isA<DatabaseAccessUnavailable>()),
        reason: 'unknown evidence denies');
    exclusion.verifyLegacyHolders(LegacyHolderEvidence.clear);
    expect(exclusion.isVerified, isTrue);
    final candidate = exclusion.reserveLocalReadCandidate(uid: 'u');
    expect(candidate.kind, DatabaseReservationKind.localReadCandidate);
    expect(candidate.isCurrent, isTrue);
    expect(() => exclusion.reserveLocalReadCandidate(uid: 'u'),
        throwsA(isA<DatabaseAccessUnavailable>()));
    final handle = candidate.registerOpened(Object(), close: () async {});
    exclusion.release(published: true);
    expect(broker.mode, DatabaseAccessMode.localRead);
    expect(candidate.isCurrent, isTrue, reason: 'published read scope');
    await handle.close();
    // The next transition supersedes it.
    final next = broker.beginLocalReadExclusion();
    expect(candidate.isCurrent, isFalse);
    next.release(published: false);
    expect(broker.mode, DatabaseAccessMode.closed);
  });

  test('a failed transition leaves its candidate stale and the mode closed '
      'only when the ledger is empty', () async {
    final exclusion = broker.beginLocalReadExclusion();
    await exclusion.awaitDrained();
    exclusion.verifyLegacyHolders(LegacyHolderEvidence.clear);
    final candidate = exclusion.reserveLocalReadCandidate(uid: 'u');
    exclusion.release(published: false);
    expect(candidate.isCurrent, isFalse);
    expect(broker.mode, DatabaseAccessMode.quiescing,
        reason: 'the candidate reservation is still pending: uncertain');
    candidate.releaseUnopened();
  });
}
