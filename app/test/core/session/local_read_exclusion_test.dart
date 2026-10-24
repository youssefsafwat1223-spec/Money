// SDK event injection uses the real GoTrue broadcast; no production use.
// ignore_for_file: invalid_use_of_internal_member, invalid_use_of_protected_member

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/session/app_session.dart';
import 'package:money_companion/core/session/local_read_authority.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/creation_policy.dart';
import 'package:money_companion/data/db/database_access_broker.dart';
import 'package:path/path.dart' as p;
import 'package:supabase_flutter/supabase_flutter.dart';

import 'f2_fixture.dart';

// O-BX (B1/B2) — the host half of the offline local-read unit: grant issuance, auth-origin
// classification, the local-read scope and its two-phase restoration, writer
// denial and reconnect, over the REAL session singleton, a real encrypted replica
// store/scope host and a recording secure storage. Every side effect is observed
// as an ATTEMPT (storage attempts, opener calls, file tree), not as final state.

const _uid = 'uid-read-a';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late F2Fixture f;
  late LocalReadAuthority authority;
  late DatabaseAccessBroker coordinator;
  late List<SupabaseClient> clients;

  Future<SupabaseClient> liveSdk([String uid = _uid]) async {
    final c = await f.clientFor(uid);
    clients.add(c);
    return c;
  }

  setUp(() async {
    await AppSession.instance.debugResetAuthBinding();
    clients = [];
    coordinator = DatabaseAccessBroker.debugUnregistered();
    f = await F2Fixture.create(
      coordinator: coordinator,
      opener: ({location, runMigrations = true, creation = const CreationPolicy.unrestricted()}) {
        return AppDatabase.open(
            location: location, runMigrations: runMigrations, creation: creation);
      },
    );
    f.session.configureAccountScope(f.host);
    authority = LocalReadAuthority(store: SecureLocalReadStore());
    f.session.configureLocalRead(authority);
  });

  tearDown(() async {
    f.session.configureLocalRead(null);
    await f.session.debugLocalReadIdle;
    await f.session.debugResetAuthBinding();
    await f.dispose();
    for (final c in clients) {
      await c.dispose();
    }
    coordinator.debugDispose();
  });

  // ------------------------------------------------------------------ helpers

  Future<void> signInFirstAccount(SupabaseClient sdk, [String uid = _uid]) async {
    await f.session.bindSupabaseAuth(sdk);
    await f.session.setIdentity(
        method: 'google', email: '$uid@example.com', userId: uid);
    await f.session.finishOnboarding(client: sdk);
  }

  Future<void> seedRows(AppDatabase db) async {
    final now = DateTime.now().toUtc().toIso8601String();
    await db.customStatement(
        "INSERT INTO transactions(id, amount, amount_minor, currency, type, "
        "source, occurred_at, raw_message, parse_confidence, status, "
        "created_at, updated_at, raw_merchant, direction) VALUES "
        "('tx-1', 125.5, 12550, 'SAR', 'payment', 'manual', '$now', '', 1, "
        "'confirmed', '$now', '$now', 'Coffee Corner', 'debit');");
  }

  Future<String> replicaIdOf(AppDatabase db) async => (await db
          .customSelect('SELECT replica_id FROM replica_meta;')
          .getSingle())
      .read<String>('replica_id');

  List<String> tree() => [
        for (final e in Directory(f.support.path).listSync(recursive: true))
          p.relative(e.path, from: f.support.path),
      ]..sort();

  /// Signed in as [_uid] (first account, grant issued), one known row, the
  /// replica id; then the process "dies" and a new one starts, replica `active`.
  Future<String> seededAndRestarted() async {
    final sdk = await liveSdk();
    await signInFirstAccount(sdk);
    await seedRows(f.host.current!.database);
    final id = await replicaIdOf(f.host.current!.database);
    await f.restartWithoutLock();
    f.session.configureAccountScope(f.host);
    f.session.configureLocalRead(authority);
    return id;
  }

  // ------------------------------------------------ O-BX: exclusion fence

  /// A physical holder in the coordinator ledger (the stand-in for any holder the
  /// ledger tracks: a primary, a cold-launch open or a registered secondary).
  /// [closeError] makes its physical close fail.
  ({DatabaseOpenReservation reservation, DatabaseOpenHandle? handle}) holder(
      {bool opened = true, Object? closeError, void Function()? onClose}) {
    final r = coordinator.reserveAdmissionOpen(
        uid: 'holder-uid', admissionIdentity: Object(), lossGeneration: 0);
    DatabaseOpenHandle? h;
    if (opened) {
      h = r.registerOpened(Object(), close: () async {
        onClose?.call();
        if (closeError != null) throw closeError;
      });
    }
    return (reservation: r, handle: h);
  }

  Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 120));

  Directory replicaDirOf(String uid) =>
      Directory(p.join(f.support.path, 'replicas'))
          .listSync()
          .whereType<Directory>()
          .single;

  group('O-BX cross-holder exclusion (B1/B2)', () {
    setUp(() {
      f.session.debugLocalReadDrainTimeout = const Duration(seconds: 5);
    });

    test('an open holder blocks local read until its physical close', () async {
      await seededAndRestarted();
      final h = holder();
      var done = false;
      final restore = f.session
          .restoreLocalReadAccess(host: f.host)
          .then((v) => done = v || true);
      await settle();
      expect(done, isFalse, reason: 'must not publish while a holder is open');
      expect(f.host.current, isNull);
      expect(f.store.debugReadOnlyLive, isEmpty,
          reason: 'no candidate was opened before exclusion was verified');
      await h.handle!.close();
      await restore;
      expect(f.session.localReadActive, isTrue);
      expect(coordinator.mode, DatabaseAccessMode.localRead);
    });

    test('an opening (pending) holder blocks; releasing it unblocks', () async {
      await seededAndRestarted();
      final h = holder(opened: false);
      var done = false;
      final restore = f.session
          .restoreLocalReadAccess(host: f.host)
          .then((v) => done = true);
      await settle();
      expect(done, isFalse);
      expect(f.store.debugReadOnlyLive, isEmpty);
      h.reservation.releaseUnopened();
      await restore;
      expect(f.session.localReadActive, isTrue);
    });

    test('a failed close never releases the holder: denied, quiescing',
        () async {
      await seededAndRestarted();
      f.session.debugLocalReadDrainTimeout = const Duration(milliseconds: 200);
      final baseline = coordinator.openHolders;
      final h = holder(closeError: StateError('close failed'));
      await expectLater(h.handle!.close(), throwsStateError);
      expect(await f.session.restoreLocalReadAccess(host: f.host), isFalse);
      expect(f.host.current, isNull);
      expect(f.store.debugReadOnlyLive, isEmpty);
      expect(coordinator.openHolders, baseline + 1,
          reason: 'still tracked: unknown');
      expect(coordinator.mode, DatabaseAccessMode.quiescing);
    });

    test('a holder that never closes (dead/unresponsive) times out and denies',
        () async {
      await seededAndRestarted();
      f.session.debugLocalReadDrainTimeout = const Duration(milliseconds: 200);
      holder();
      expect(await f.session.restoreLocalReadAccess(host: f.host), isFalse);
      expect(f.session.localReadActive, isFalse);
      expect(f.host.current, isNull);
      expect(f.store.debugReadOnlyLive, isEmpty);
      expect(coordinator.mode, DatabaseAccessMode.quiescing);
    });

    test('reservation versus quiesce, quiesce first: every other path refused',
        () async {
      await seededAndRestarted();
      final h = holder();
      final restore = f.session.restoreLocalReadAccess(host: f.host);
      await settle();
      expect(
          () => coordinator.reserveAdmissionOpen(
              uid: 'x', admissionIdentity: Object(), lossGeneration: 0),
          throwsA(isA<DatabaseAccessUnavailable>()));
      expect(
          () => coordinator.reserveColdLaunchOpen(
              uid: 'x', launchIdentity: Object(), lossGeneration: 0),
          throwsA(isA<DatabaseAccessUnavailable>()));
      expect(coordinator.reserveEphemeral, returnsNormally,
          reason: 'the memory-only signed-out database touches no replica');
      await h.handle!.close();
      await restore;
    });

    test('reservation versus quiesce, reservation first: it is drained',
        () async {
      await seededAndRestarted();
      final early = holder(opened: false);
      var done = false;
      final restore = f.session
          .restoreLocalReadAccess(host: f.host)
          .then((v) => done = true);
      await settle();
      expect(done, isFalse, reason: 'the earlier reservation is not ignored');
      early.reservation.releaseUnopened();
      await restore;
    });

    test('a late opener returning after invalidation stays tracked and stale',
        () async {
      await seededAndRestarted();
      final early = holder(opened: false);
      var done = false;
      final restore = f.session
          .restoreLocalReadAccess(host: f.host)
          .then((v) => done = true);
      await settle();
      final db = Object();
      final handle = early.reservation.registerOpened(db, close: () async {});
      expect(early.reservation.isCurrent, isFalse, reason: 'old generation');
      expect(early.reservation.promoteCommitted(db, uid: 'holder-uid'), isFalse);
      await settle();
      expect(done, isFalse, reason: 'its real handle must still be closed');
      await handle.close();
      await restore;
      expect(f.session.localReadActive, isTrue);
    });

    test('a competing sign-out during the drain publishes nothing', () async {
      await seededAndRestarted();
      final h = holder();
      final restore = f.session.restoreLocalReadAccess(host: f.host);
      await settle();
      await f.session.signOut();
      await h.handle!.close();
      expect(await restore, isFalse);
      expect(f.session.localReadActive, isFalse);
      expect(f.store.debugReadOnlyLive, isEmpty);
    });

    group('legacy / unregistered holder evidence', () {
      Future<void> expectEvidenceDenied(void Function(Directory dir) plant,
          {bool plantIsIntent = false}) async {
        await seededAndRestarted();
        final baseline = coordinator.openHolders;
        final dir = replicaDirOf(_uid);
        plant(dir);
        final before = tree();
        final from = f.storage.attempts.length;
        expect(await f.session.restoreLocalReadAccess(host: f.host), isFalse);
        expect(f.host.current, isNull);
        expect(f.store.debugReadOnlyLive, isEmpty);
        expect(tree(), before, reason: 'the check created nothing');
        expect(f.storage.attempts.skip(from), isEmpty);
        expect(coordinator.openHolders, baseline);
        expect(coordinator.pendingOpens, 0);
      }

      test('a live lease record denies', () async {
        await expectEvidenceDenied((dir) {
          Directory(p.join(dir.path, 'db_leases')).createSync();
          File(p.join(dir.path, 'db_leases', '1_0_a.lease'))
              .writeAsStringSync('t\n1\ni');
        });
      });
      test('an unparsable / half-published record denies', () async {
        await expectEvidenceDenied((dir) {
          Directory(p.join(dir.path, 'db_leases')).createSync();
          File(p.join(dir.path, 'db_leases', '1_0_a.lease.tmp'))
              .writeAsStringSync('');
        });
      });
      test('a maintenance intent denies', () async {
        await expectEvidenceDenied((dir) {
          final db = dir.listSync().whereType<File>().firstWhere(
              (e) => e.path.endsWith('.sqlite') || e.path.contains('.sqlite'));
          File('${db.path.split('.sqlite').first}.sqlite.maint')
              .writeAsStringSync('t\n1\ni');
        });
      });
      test('an unreadable lease path (a file where the directory belongs) denies',
          () async {
        await expectEvidenceDenied((dir) {
          File(p.join(dir.path, 'db_leases')).writeAsStringSync('x');
        });
      });
    });

    group('R5 ambiguous lookups and the lease-creator window', () {
      test('a dangling link where the lease directory belongs denies',
          () async {
        await seededAndRestarted();
        Link(p.join(replicaDirOf(_uid).path, 'db_leases'))
            .createSync(p.join(f.support.path, 'nowhere'));
        final before = tree();
        expect(await f.session.restoreLocalReadAccess(host: f.host), isFalse);
        expect(f.host.current, isNull);
        expect(f.store.debugReadOnlyLive, isEmpty);
        expect(tree(), before, reason: 'the check created nothing');
      });

      test('a symlink loop where the maintenance intent belongs denies',
          () async {
        await seededAndRestarted();
        final dir = replicaDirOf(_uid);
        final db = dir
            .listSync()
            .whereType<File>()
            .firstWhere((e) => e.path.contains('.sqlite'));
        final intent = '${db.path.split('.sqlite').first}.sqlite.maint';
        Link(intent).createSync(intent);
        final before = tree();
        expect(await f.session.restoreLocalReadAccess(host: f.host), isFalse);
        expect(f.store.debugReadOnlyLive, isEmpty);
        expect(tree(), before);
      });

      test(
          'a lease creator paused between directory creation and record '
          'publication keeps the grant waiting until it is a closed holder',
          () async {
        await seededAndRestarted();
        // The creator reserved first (pending open) and has made the lease
        // directory, but not yet published its record: the empty-directory
        // window. A directory snapshot alone would call this clear.
        final creator = holder(opened: false);
        final leaseDirectory =
            Directory(p.join(replicaDirOf(_uid).path, 'db_leases'))
              ..createSync();
        var done = false;
        final restore = f.session
            .restoreLocalReadAccess(host: f.host)
            .then((v) => done = true);
        await settle();
        expect(done, isFalse, reason: 'the pending creator is drained first');
        expect(f.store.debugReadOnlyLive, isEmpty);
        // It publishes its record, then the secondary closes: lease released.
        final record = File(p.join(leaseDirectory.path, '1_0_a.lease'))
          ..writeAsStringSync('t\n1\ni');
        await settle();
        expect(done, isFalse);
        record.deleteSync();
        creator.reservation.releaseUnopened();
        await restore;
        expect(f.session.localReadActive, isTrue);
        expect(leaseDirectory.listSync(), isEmpty,
            reason: 'the read path created and removed nothing');
      });

      test('a published lease record whose holder never closed still denies',
          () async {
        await seededAndRestarted();
        final creator = holder(opened: false);
        creator.reservation.releaseUnopened(); // ledger empty ...
        final leaseDirectory =
            Directory(p.join(replicaDirOf(_uid).path, 'db_leases'))
              ..createSync();
        File(p.join(leaseDirectory.path, '1_0_a.lease'))
            .writeAsStringSync('t\n1\ni'); // ... but a record survives
        expect(await f.session.restoreLocalReadAccess(host: f.host), isFalse);
        expect(f.store.debugReadOnlyLive, isEmpty);
        expect(leaseDirectory.listSync(), hasLength(1));
      });
    });

    test('a granted read path creates no lease, key, salt or sidecar',
        () async {
      await seededAndRestarted();
      final from = f.storage.attempts.length;
      final before = tree();
      expect(await f.session.restoreLocalReadAccess(host: f.host), isTrue);
      expect(f.storage.attempts.skip(from), isEmpty);
      expect(tree(), before);
    });

    // Astra R7 — quiescing outlives the exclusion object. The fresh primary
    // reconnect is a CONTROLLED path: refused while an uncertain holder remains,
    // admitted through the explicit recovery transition once it really closed.
    // Setup: a signed-in writable session whose local-read restoration times out
    // on an uncertain holder, so the writable scope was suspended and the
    // coordinator is left quiescing with the exclusion object already released.
    Future<
        (
          ({DatabaseOpenReservation reservation, DatabaseOpenHandle? handle}),
          SupabaseClient
        )> quiescingAfterTimedOutRestore() async {
      final sdk = await liveSdk();
      await signInFirstAccount(sdk);
      await seedRows(f.host.current!.database);
      f.session.debugLocalReadDrainTimeout = const Duration(milliseconds: 200);
      final h = holder();
      expect(await f.session.restoreLocalReadAccess(host: f.host), isFalse);
      expect(coordinator.mode, DatabaseAccessMode.quiescing);
      return (h, sdk);
    }

    test('R7 fresh reconnect is refused while an uncertain holder is open',
        () async {
      final (h, _) = await quiescingAfterTimedOutRestore();
      final holdersWhileQuiescing = coordinator.openHolders;
      try {
        await f.session.setIdentity(
            method: 'google', email: '$_uid@example.com', userId: _uid);
      } catch (_) {
        // Refusal may surface as a typed ownership failure; the point is below.
      }
      expect(coordinator.openHolders, holdersWhileQuiescing,
          reason: 'no persistent primary was opened under the quiescing mode');
      expect(coordinator.pendingOpens, 0);
      expect(f.host.current?.uid, isNull, reason: 'signed-out scope only');
      expect(coordinator.mode, DatabaseAccessMode.quiescing);
      await h.handle!.close();
    });

    test(
        'R7 fresh reconnect after the late physical close goes through the '
        'explicit recovery and never auto-switches to writable', () async {
      final (h, _) = await quiescingAfterTimedOutRestore();
      await h.handle!.close();
      expect(coordinator.mode, DatabaseAccessMode.quiescing,
          reason: 'a late close alone never reopens admission');
      await f.session.setIdentity(
          method: 'google', email: '$_uid@example.com', userId: _uid);
      expect(f.host.current?.uid, _uid);
      expect(f.host.current!.isLocalRead, isFalse);
      expect(f.host.current!.database.isReadOnly, isFalse);
      expect(coordinator.mode, DatabaseAccessMode.closed,
          reason: 'recovered to closed, never auto-switched to writable');
    });

    // Astra R10.1 — the provenance predicate is consulted wherever the
    // restoration validates itself. Flipping it to "lost" just before EACH
    // consultation (and so after every await that precedes it) must end in zero
    // publication: the local-read scope is never visible and the coordinator
    // never enters local-read mode.
    test('R10.1: a provenance loss before ANY consultation publishes nothing',
        () async {
      await seededAndRestarted();
      var total = 0;
      expect(
          await f.session.restoreLocalReadAccess(
              host: f.host, provenanceIntact: () {
            total++;
            return true;
          }),
          isTrue);
      expect(total, greaterThanOrEqualTo(4),
          reason: 'start, drain, reservation currency and publication check');
      for (var k = 1; k <= total; k++) {
        await f.session.debugLocalReadIdle;
        f.session.configureLocalRead(null);
        await f.restartWithoutLock();
        coordinator.debugClearLedgerForTest(); // each pass starts from closed
        f.session.configureAccountScope(f.host);
        f.session.configureLocalRead(authority);
        var seenLocalRead = false;
        void watch() {
          if (f.host.current?.isLocalRead ?? false) seenLocalRead = true;
        }

        f.host.addListener(watch);
        var calls = 0;
        final published = await f.session.restoreLocalReadAccess(
            host: f.host, provenanceIntact: () => ++calls < k);
        f.host.removeListener(watch);
        expect(published, isFalse, reason: 'loss before consultation #$k');
        expect(seenLocalRead, isFalse, reason: 'never visible (#$k)');
        expect(f.session.localReadActive, isFalse, reason: '#$k');
        expect(coordinator.mode, isNot(DatabaseAccessMode.localRead),
            reason: '#$k');
        expect(f.host.current?.isLocalRead ?? false, isFalse, reason: '#$k');
        expect(f.store.debugReadOnlyLive, isEmpty,
            reason: 'any opened candidate was closed (#$k)');
      }
    });

    test('without a coordinator there is no local read (fail closed)',
        () async {
      await seededAndRestarted();
      f.session.configureUncoordinatedForTesting();
      expect(await f.session.restoreLocalReadAccess(host: f.host), isFalse);
      expect(f.host.current, isNull);
      expect(f.store.debugReadOnlyLive, isEmpty);
    });
  });
}
