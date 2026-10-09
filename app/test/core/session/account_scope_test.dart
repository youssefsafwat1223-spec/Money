import 'dart:async';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/session/account_scope.dart';
import 'package:money_companion/core/session/admission_authority.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/replica_location.dart';
import 'package:money_companion/data/db/replica_store.dart';
import 'package:path/path.dart' as p;

import 'recording_secure_storage.dart';

// WP-3b — the account-scope host over real SQLCipher replicas in temp dirs.

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory support;
  late FlutterSecureStorage storage;
  late List<String?> initialized;
  String? marker;

  ReplicaStore newStore() => ReplicaStore(requireCreationAuthority: false, 
        appSupportDirectory: support.path,
        readOwnerMarker: () async => marker,
      );

  AccountScopeHost newHost(ReplicaStore store) => AccountScopeHost(
        store: store,
        initialize: (db, uid) async {
          initialized.add(uid);
          return const AccountScopeInit();
        },
      );

  ReplicaLocation legacyLoc() => ReplicaLocation(
        directory: support.path,
        dbFileName: ReplicaLocation.legacyDbFileName,
        keyName: ReplicaLocation.legacyKeyName,
      );

  /// A legacy shared DB as build 50 left it, with one distinctive row.
  Future<void> makeLegacy() async {
    final db = await AppDatabase.open(location: legacyLoc());
    await db.customStatement('DROP TABLE replica_meta;');
    await db.customStatement('PRAGMA user_version = 38;');
    await db.customStatement('CREATE TABLE probe(v TEXT);');
    await db.customStatement("INSERT INTO probe(v) VALUES ('legacy-row');");
    await db.close();
  }

  setUp(() {
    support = Directory.systemTemp.createTempSync('account_scope_');
    FlutterSecureStorage.setMockInitialValues({});
    storage = const FlutterSecureStorage();
    initialized = [];
    marker = null;
  });

  tearDown(() {
    if (support.existsSync()) support.deleteSync(recursive: true);
  });

  test('launch with no uid opens the signed-out scope (in memory, no file)',
      () async {
    final host = newHost(newStore());
    final scope = await host.openAtLaunch(null);

    expect(scope.uid, isNull);
    expect(scope.location, isNull);
    expect(Directory(p.join(support.path, 'replicas')).existsSync(), isFalse);
    await host.lock();
    host.dispose();
  });

  test('sign-out locks: the same uid cannot be reopened offline at launch '
      '(SYNC-Q3), and only a successful admission unlocks it', () async {
    final store = newStore();
    final host = newHost(store);
    await host.activate('uid-a');
    final a = host.current!.database;
    await a.customStatement('CREATE TABLE probe(v TEXT);');
    await a.customStatement("INSERT INTO probe VALUES ('mine');");

    await host.lock();
    expect(host.current!.uid, isNull, reason: 'signed-out scope published');
    expect((await store.list()).single.state, ReplicaState.locked);
    await expectLater(store.openReplica('uid-a'),
        throwsA(isA<ReplicaUnavailableException>()));

    // A new process after the sign-out: the launch reopen is refused too.
    final relaunch = newHost(newStore());
    final scope = await relaunch.openAtLaunch('uid-a');
    expect(scope.uid, isNull, reason: 'no offline reopen without auth');

    // The same uid authenticates: unlock + open, data intact.
    await relaunch.activate('uid-a');
    final rows = await relaunch.current!.database
        .customSelect('SELECT v FROM probe;')
        .get();
    expect(rows.single.read<String>('v'), 'mine');
    expect((await newStore().list()).single.state, ReplicaState.active);
    await relaunch.lock();
    relaunch.dispose();
    host.dispose();
  });

  test('once admitted, a relaunch reopens the active replica offline (T1)',
      () async {
    final host = newHost(newStore());
    await host.activate('uid-a');
    await host.current!.database.customStatement('CREATE TABLE probe(v TEXT);');
    await host.current!.database
        .customStatement("INSERT INTO probe VALUES ('kept');");
    await host.detach(); // process "dies" with the replica still active
    final relaunch = newHost(newStore());
    final scope = await relaunch.openAtLaunch('uid-a');

    expect(scope.uid, 'uid-a');
    expect(
        (await scope.database.customSelect('SELECT v FROM probe;').get())
            .single
            .read<String>('v'),
        'kept');
    await relaunch.lock();
    relaunch.dispose();
    host.dispose();
  });

  test('switching uid locks the previous replica and publishes a new '
      'generation; every transition runs the per-account init', () async {
    final store = newStore();
    final host = newHost(store);
    await host.activate('uid-a');
    final g1 = host.current!.generation;
    await host.activate('uid-b');

    expect(host.current!.generation, greaterThan(g1));
    final states = {
      for (final e in await store.list()) e.uidHash: e.state,
    };
    expect(states[await store.uidHash('uid-a')], ReplicaState.locked);
    expect(states[await store.uidHash('uid-b')], ReplicaState.active);
    expect(initialized, ['uid-a', 'uid-b']);
    await host.lock();
    expect(initialized.last, isNull, reason: 'signed-out scope initialised too');
    host.dispose();
  });

  test('the withdrawn scope is announced (current == null) during a switch',
      () async {
    final host = newHost(newStore());
    await host.activate('uid-a');
    final seen = <int?>[];
    host.addListener(() => seen.add(host.current?.generation));
    await host.activate('uid-b');

    expect(seen.first, isNull);
    expect(seen.last, isNotNull);
    await host.lock();
    host.dispose();
  });

  test('legacy adoption at launch: the owner marker is adopted into the owner '
      'replica, which then opens with the legacy data', () async {
    await makeLegacy();
    marker = 'uid-owner';
    final store = newStore();
    final host = newHost(store);

    expect(await host.recoverAtLaunch(), AdoptionOutcome.adopted);
    final scope = await host.openAtLaunch('uid-owner');

    expect(scope.uid, 'uid-owner');
    expect(
        (await scope.database.customSelect('SELECT v FROM probe;').get())
            .single
            .read<String>('v'),
        'legacy-row');
    await host.lock();
    host.dispose();
  });

  test('B4: an unowned legacy DB is quarantined and NEVER adopted by the next '
      'signer-in', () async {
    await makeLegacy();
    marker = null; // no provable owner
    final store = newStore();
    final host = newHost(store);

    expect(await host.recoverAtLaunch(), AdoptionOutcome.quarantined);
    expect(await store.hasQuarantinedLegacyData(), isTrue);

    // Whoever signs in next gets their OWN empty replica.
    await host.activate('uid-next');
    final tables = await host.current!.database
        .customSelect("SELECT name FROM sqlite_master WHERE name = 'probe';")
        .get();
    expect(tables, isEmpty, reason: 'the unowned data is not in their replica');
    expect(File(legacyLoc().dbPath).existsSync(), isFalse);
    await host.lock();
    host.dispose();
  });

  test('a failed adoption leaves the legacy file in use for the owner',
      () async {
    await makeLegacy();
    marker = 'uid-owner';
    // Wipe the legacy key: adoption cannot read it and fails, file untouched.
    final failing = ReplicaStore(requireCreationAuthority: false, 
      appSupportDirectory: support.path,
      readOwnerMarker: () async => marker,
      debugAfterAdoptionStep: (step) async {
        if (step == 'afterCopy') throw const FileSystemException('boom');
      },
    );
    final host = AccountScopeHost(
      store: failing,
      initialize: (db, uid) async => const AccountScopeInit(),
    );
    expect(await host.recoverAtLaunch(), AdoptionOutcome.failed);

    final scope = await host.openAtLaunch('uid-owner');
    expect(scope.uid, 'uid-owner');
    expect(scope.location?.dbFileName, ReplicaLocation.legacyDbFileName);
    expect(
        (await scope.database.customSelect('SELECT v FROM probe;').get())
            .single
            .read<String>('v'),
        'legacy-row');
    await host.detach();
    host.dispose();
    expect(await storage.read(key: ReplicaLocation.legacyKeyName), isNotNull);
  });

  test('activeLocation: background isolates resolve the right replica and '
      'refuse a locked or absent account', () async {
    final store = newStore();
    final host = newHost(store);
    expect(await store.activeLocation(), isNull, reason: 'no marker');

    marker = 'uid-a';
    await host.activate('uid-a');
    final hashA = await store.uidHash('uid-a');
    expect((await store.activeLocation())!.directory,
        p.join(support.path, 'replicas', hashA));

    marker = 'uid-b';
    await host.activate('uid-b');
    final hashB = await store.uidHash('uid-b');
    expect((await store.activeLocation())!.directory,
        p.join(support.path, 'replicas', hashB));

    await host.lock();
    expect(await store.activeLocation(), isNull,
        reason: 'a signed-out (locked) account is never opened by capture');
    host.dispose();
  });

  test('D2/WP-7: a rebootstrap swap publishes NO scope (never the signed-out '
      'one); a real sign-out still publishes it', () async {
    final host = newHost(newStore());
    await host.activate('uid-a');
    final seen = <String>[];
    host.addListener(() => seen.add(host.current == null
        ? 'none'
        : (host.current!.uid ?? 'signed-out')));

    await host.suspendForSwap();
    expect(host.current, isNull);
    expect(host.swapInProgress, isTrue);
    await host.activate('uid-a');
    expect(host.swapInProgress, isFalse);
    expect(seen, ['none', 'uid-a'], reason: 'signed-out never published');

    seen.clear();
    await host.lock();
    expect(seen.last, 'signed-out');
    expect(host.swapInProgress, isFalse);
    host.dispose();
  });

  // ---------------------------------------------------------------- F2 ------
  group('F2: launch opens what exists; activation honors a revoked authority',
      () {
    late RecordingSecureStorage rec;

    ReplicaStore strict() => ReplicaStore(appSupportDirectory: support.path);

    Future<List<String>> artifacts(ReplicaStore s, String uid) async {
      final h = await s.uidHash(uid);
      return [
        if (Directory(p.join(support.path, 'replicas', h)).existsSync()) 'dir',
        if (rec.data.containsKey('qirsh.db_key.$h')) 'key',
        if ((await s.list()).any((e) => e.uidHash == h)) 'registry',
      ];
    }

    setUp(() => rec = RecordingSecureStorage().install());

    test('a launch for a stale owner marker with NO registry entry, file or '
        'key opens the signed-out scope and creates nothing', () async {
      final s = strict();
      final host = newHost(s);
      await s.uidHash('uid-gone'); // device salt only
      final before = rec.attempts.length;

      final scope = await host.openAtLaunch('uid-gone');

      expect(scope.uid, isNull);
      expect(rec.attempts.skip(before), isEmpty);
      expect(await artifacts(s, 'uid-gone'), isEmpty);
      host.dispose();
    });

    test('an activation with a revoked authority changes nothing: the active '
        'uid stays active and unlocked, the target gets no replica', () async {
      final s = strict();
      final host = newHost(s);
      await host.activate('uid-a',
          authority: const AdmissionAuthority.forTest('uid-a'));
      var live = true;
      final authorityB = AdmissionAuthority('uid-b', () => live, canCreate: true);
      live = false;
      final before = rec.attempts.length;

      await expectLater(host.activate('uid-b', authority: authorityB),
          throwsA(isA<StaleAdmissionException>()));

      expect(host.current!.uid, 'uid-a');
      expect(rec.attempts.skip(before), isEmpty, reason: 'no lock, no write');
      expect((await s.list()).single.state, ReplicaState.active);
      expect(await artifacts(s, 'uid-b'), isEmpty);
      await host.lock();
      host.dispose();
    });

    test('an authority revoked WHILE the replica opens and initializes never '
        'publishes; the opened handle is closed', () async {
      final reached = Completer<void>();
      final proceed = Completer<void>();
      final s = strict();
      final host = AccountScopeHost(
        store: s,
        initialize: (db, uid) async {
          if (uid == null) return const AccountScopeInit();
          reached.complete();
          await proceed.future;
          return const AccountScopeInit();
        },
      );
      var live = true;
      final authority = AdmissionAuthority('uid-a', () => live, canCreate: true);
      final activation = host.activate('uid-a', authority: authority);
      final outcome =
          expectLater(activation, throwsA(isA<StaleAdmissionException>()));
      await reached.future;
      live = false; // Remove data accepted
      proceed.complete();
      await outcome;

      expect(host.current!.uid, isNull, reason: 'only the signed-out scope');
      host.dispose();
    });

    test('a queued activation is checked when its turn STARTS, not when it was '
        'queued', () async {
      final reached = Completer<void>();
      final proceed = Completer<void>();
      final s = strict();
      var first = true;
      final host = AccountScopeHost(
        store: s,
        initialize: (db, uid) async {
          if (first) {
            first = false;
            reached.complete();
            await proceed.future;
          }
          return const AccountScopeInit();
        },
      );
      final holding = host.activate('uid-a',
          authority: const AdmissionAuthority.forTest('uid-a'));
      await reached.future;
      var live = true;
      final queued = host.activate('uid-b',
          authority: AdmissionAuthority('uid-b', () => live, canCreate: true));
      final outcome =
          expectLater(queued, throwsA(isA<StaleAdmissionException>()));
      live = false;
      proceed.complete();
      await holding;
      await outcome;
      expect(await artifacts(s, 'uid-b'), isEmpty);
      expect(host.current!.uid, 'uid-a');
      await host.lock();
      host.dispose();
    });

    test('an open-existing authority (automatic reconcile) cannot create',
        () async {
      final s = strict();
      final host = newHost(s);
      await expectLater(
          host.activate('uid-a',
              authority: const AdmissionAuthority.forTest('uid-a',
                  canCreate: false)),
          throwsA(isA<ReplicaMissingException>()));
      expect(await artifacts(s, 'uid-a'), isEmpty);
      host.dispose();
    });
  });
}
