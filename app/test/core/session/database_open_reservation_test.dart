import 'dart:async';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/session/account_scope.dart';
import 'package:money_companion/core/session/admission_authority.dart';
import 'package:money_companion/core/session/app_session.dart' show LaunchAdmission;
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/creation_policy.dart';
import 'package:money_companion/data/db/database_access_broker.dart';
import 'package:money_companion/data/db/replica_location.dart';
import 'package:money_companion/data/db/replica_store.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'f2_fixture.dart';

// O-H1 — the private single-opener reservation. It is minted inside
// AppSession's private admission turn BEFORE the opener, and the host tracks
// the real handle until it is actually closed. It grants no broker authority.

class _FailingCloseStore extends ReplicaStore {
  _FailingCloseStore(
      {super.appSupportDirectory, super.requireCreationAuthority});
  bool failClose = false;
  @override
  Future<void> closeReplica(String uid) async {
    if (failClose) throw StateError('close failed');
    return super.closeReplica(uid);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AccountScopeHost', () {
    late Directory support;
    late DatabaseAccessBroker broker;
    late List<int> pendingAtOpen;
    late List<int> holdersAtInitialize;
    var openerCalls = 0;
    Object? openerFailure;
    var valid = true;

    ReplicaOpener spyOpener = ({
      ReplicaLocation? location,
      bool runMigrations = true,
      CreationPolicy creation = const CreationPolicy.unrestricted(),
    }) async =>
        throw StateError('replaced in setUp');

    setUp(() {
      support = Directory.systemTemp.createTempSync('open_reservation_');
      FlutterSecureStorage.setMockInitialValues({});
      broker = DatabaseAccessBroker.debugUnregistered();
      pendingAtOpen = [];
      holdersAtInitialize = [];
      openerCalls = 0;
      openerFailure = null;
      valid = true;
      spyOpener = ({
        ReplicaLocation? location,
        bool runMigrations = true,
        CreationPolicy creation = const CreationPolicy.unrestricted(),
      }) async {
        openerCalls++;
        pendingAtOpen.add(broker.pendingOpens);
        final failure = openerFailure;
        if (failure != null) throw failure;
        return AppDatabase.open(
            location: location,
            runMigrations: runMigrations,
            creation: creation);
      };
    });

    tearDown(() {
      broker.debugDispose();
      if (support.existsSync()) support.deleteSync(recursive: true);
    });

    ReplicaStore store({bool requireCreationAuthority = false}) => ReplicaStore(
          appSupportDirectory: support.path,
          requireCreationAuthority: requireCreationAuthority,
          opener: (
                  {location,
                  runMigrations = true,
                  creation = const CreationPolicy.unrestricted()}) =>
              spyOpener(
                  location: location,
                  runMigrations: runMigrations,
                  creation: creation),
        );

    AccountScopeHost host(ReplicaStore s,
            {Future<AccountScopeInit> Function(AppDatabase, String?)?
                initialize}) =>
        AccountScopeHost(
          store: s,
          coordinator: broker,
          initialize: initialize ??
              (db, uid) async {
                holdersAtInitialize.add(broker.openHolders);
                return const AccountScopeInit();
              },
        );

    AdmissionAuthority authorityFor(String uid, DatabaseOpenReservation? r) {
      final base = AdmissionAuthority(uid, () => true, canCreate: true);
      return r == null ? base : base.withOpenReservation(r);
    }

    DatabaseOpenReservation reserve(String uid) => broker.reserveAdmissionOpen(
        uid: uid,
        admissionIdentity: Object(),
        lossGeneration: 0,
        stillValid: () => valid);

    test(
        'reservation exists before the opener; handle is tracked before '
        'initialization and publication', () async {
      final h = host(store());
      final reservation = reserve('uid-a');
      await h.activate('uid-a', authority: authorityFor('uid-a', reservation));
      expect(openerCalls, 1);
      expect(pendingAtOpen, [1], reason: 'reserved before any opener ran');
      expect(holdersAtInitialize, [1],
          reason: 'real handle registered before initialize/publish');
      expect(reservation.hasOpened, isTrue);
      expect(h.current!.uid, 'uid-a');
      expect(broker.pendingOpens, 0);
      expect(broker.openHolders, 1);
      // Scope publication alone never releases the holder.
      expect(broker.client.isHostIssued, isFalse);
      expect(broker.mode, DatabaseAccessMode.closed);
      final db = h.current!.database;
      await h.lock();
      expect(db.lifecycleState, DatabaseLifecycleState.closed);
      // Only the new signed-out ephemeral handle remains tracked.
      expect(broker.openHolders, 1);
      await h.lock();
      h.dispose();
    });

    test('a stale reservation never opens anything', () async {
      final h = host(store());
      final reservation = reserve('uid-a');
      valid = false;
      await expectLater(
          h.activate('uid-a', authority: authorityFor('uid-a', reservation)),
          throwsA(isA<StaleAdmissionException>()));
      expect(openerCalls, 0);
      expect(broker.pendingOpens, 0, reason: 'known: nothing was opened');
      h.dispose();
    });

    test('a reservation for another uid never opens anything', () async {
      final h = host(store());
      final reservation = reserve('uid-a');
      await expectLater(
          h.activate('uid-b', authority: authorityFor('uid-b', reservation)),
          throwsA(isA<StaleAdmissionException>()));
      expect(openerCalls, 0);
      expect(broker.pendingOpens, 0);
      h.dispose();
    });

    test('loss during initialization closes and releases the tracked handle',
        () async {
      final reservation = reserve('uid-a');
      final h = host(store(), initialize: (db, uid) async {
        holdersAtInitialize.add(broker.openHolders);
        valid = false; // SDK / issuer loss while the replica initializes
        return const AccountScopeInit();
      });
      await expectLater(
          h.activate('uid-a', authority: authorityFor('uid-a', reservation)),
          throwsA(isA<StaleAdmissionException>()));
      expect(holdersAtInitialize.first, 1);
      // The failed opener's real handle was closed (actually) and released;
      // only the signed-out ephemeral scope published afterwards is tracked.
      expect(broker.pendingOpens, 0);
      expect(broker.openHolders, 1);
      expect(h.current!.uid, isNull);
      await h.lock();
      h.dispose();
    });

    test('failure after open with a failed close keeps the handle tracked',
        () async {
      final failing = _FailingCloseStore(
          appSupportDirectory: support.path, requireCreationAuthority: false);
      final reservation = reserve('uid-a');
      final h = AccountScopeHost(
        store: failing,
        coordinator: broker,
        initialize: (db, uid) async {
          failing.failClose = true;
          throw StateError('initialize failed');
        },
      );
      await expectLater(
          h.activate('uid-a', authority: authorityFor('uid-a', reservation)),
          throwsA(anything));
      // The close failed: the real handle can never be forgotten.
      expect(broker.openHolders, greaterThanOrEqualTo(1));
      expect(reservation.hasOpened, isTrue);
      await expectLater(
          broker.transition(DatabaseAccessMode.closed,
              timeout: const Duration(milliseconds: 30)),
          throwsA(isA<DatabaseAccessUnavailable>()));
      failing.failClose = false;
      h.dispose();
    });

    test('an unknown opener failure retains the reservation', () async {
      final h = host(store());
      final reservation = reserve('uid-a');
      openerFailure = StateError('native open failed somewhere');
      await expectLater(
          h.activate('uid-a', authority: authorityFor('uid-a', reservation)),
          throwsA(anything));
      expect(broker.pendingOpens, 1,
          reason: 'a possibly-open handle is never forgotten');
      h.dispose();
    });

    test('a failure known to precede any open releases the reservation',
        () async {
      final h = host(store(requireCreationAuthority: true));
      final reservation = broker.reserveAdmissionOpen(
          uid: 'uid-a', admissionIdentity: Object(), lossGeneration: 0);
      // canCreate:false + no replica: ReplicaMissingException before any open.
      final noCreate = AdmissionAuthority('uid-a', () => true)
          .withOpenReservation(reservation);
      await expectLater(h.activate('uid-a', authority: noCreate),
          throwsA(isA<ReplicaMissingException>()));
      expect(openerCalls, 0);
      expect(broker.pendingOpens, 0);
      await h.lock();
      h.dispose();
    });

    test('re-admitting the already-published uid opens nothing and releases',
        () async {
      final h = host(store());
      final first = reserve('uid-a');
      await h.activate('uid-a', authority: authorityFor('uid-a', first));
      final second = reserve('uid-a');
      await h.activate('uid-a', authority: authorityFor('uid-a', second));
      expect(openerCalls, 1);
      expect(second.hasOpened, isFalse);
      expect(broker.pendingOpens, 0);
      expect(broker.openHolders, 1);
      await h.lock();
      await h.lock();
      h.dispose();
    });

    test('signed-out in-memory database gets a tracked ephemeral reservation',
        () async {
      final h = host(store());
      final scope = await h.openAtLaunch(null);
      expect(scope.uid, isNull);
      expect(broker.pendingOpens, 0);
      expect(broker.openHolders, 1);
      expect(broker.client.isHostIssued, isFalse);
      expect(broker.mode, DatabaseAccessMode.closed);
      final db = scope.database;
      await h.lock(); // withdraws (closing it for real) and republishes
      expect(db.lifecycleState, DatabaseLifecycleState.closed);
      expect(broker.openHolders, 1, reason: 'only the new ephemeral handle');
      await h.lock();
      h.dispose();
    });

    test('normal existing cold launch opens without any account reservation',
        () async {
      final seed = host(store());
      await seed.activate('uid-a', authority: authorityFor('uid-a', null));
      await seed.lock();
      seed.dispose();
      openerCalls = 0;
      final h = host(store());
      // A locked replica stays closed at launch (SYNC-Q3); unlock it first.
      await store().setState('uid-a', ReplicaState.active);
      final scope = await h.openAtLaunch('uid-a');
      expect(scope.uid, 'uid-a');
      expect(openerCalls, 1);
      expect(broker.pendingOpens, 0);
      expect(broker.mode, DatabaseAccessMode.closed);
      expect(broker.client.isHostIssued, isFalse,
          reason: 'launch open grants nothing and mints no admission');
      await h.lock();
      await h.lock();
      h.dispose();
    });

    // ---------------- O-H3 item 3: the cold-launch primary open is tracked

    DatabaseOpenReservation? Function(String) launchReserver(
            {bool Function()? stillValid,
            void Function(DatabaseOpenReservation r)? onMint}) =>
        (uid) {
          final r = broker.reserveColdLaunchOpen(
              uid: uid,
              launchIdentity: Object(),
              lossGeneration: 0,
              stillValid: stillValid);
          onMint?.call(r);
          return r;
        };

    Future<void> seedLockedReplica(String uid, {bool unlock = true}) async {
      final seed = host(store());
      await seed.activate(uid, authority: authorityFor(uid, null));
      await seed.lock();
      seed.dispose();
      if (unlock) await store().setState(uid, ReplicaState.active);
      openerCalls = 0;
      pendingAtOpen.clear();
      holdersAtInitialize.clear();
    }

    test('cold launch reserves BEFORE the opener and tracks the handle',
        () async {
      await seedLockedReplica('uid-a');
      final before = broker.openHolders; // the seed host's ephemeral handle
      DatabaseOpenReservation? minted;
      final h = host(store());
      final scope = await h.openAtLaunch('uid-a',
          reserveLaunch: launchReserver(onMint: (r) => minted = r));
      expect(scope.uid, 'uid-a');
      expect(openerCalls, 1);
      expect(pendingAtOpen, [1], reason: 'reserved before any opener ran');
      expect(holdersAtInitialize, [before + 1],
          reason: 'real handle registered before initialize/publication');
      expect(minted!.kind, DatabaseReservationKind.coldLaunchPrimary);
      expect(minted!.hasOpened, isTrue);
      expect(minted!.ownsDatabase(scope.database), isTrue);
      expect(broker.pendingOpens, 0);
      expect(broker.openHolders, before + 1,
          reason: 'tracked for its whole lifetime');
      // Grants nothing: no job client, no mode, not committed authority.
      expect(broker.client.isHostIssued, isFalse);
      expect(broker.mode, DatabaseAccessMode.closed);
      expect(minted!.isPromoted, isFalse);
      final db = scope.database;
      await h.lock();
      expect(db.lifecycleState, DatabaseLifecycleState.closed);
      expect(broker.openHolders, before + 1,
          reason: 'launch handle closed; only the new ephemeral is added');
      await h.lock();
      h.dispose();
    });

    test('a failed launch open whose close also fails stays tracked',
        () async {
      await seedLockedReplica('uid-a');
      final failing = _FailingCloseStore(
          appSupportDirectory: support.path, requireCreationAuthority: false);
      DatabaseOpenReservation? minted;
      final h = AccountScopeHost(
        store: failing,
        coordinator: broker,
        initialize: (db, uid) async {
          failing.failClose = true;
          throw StateError('initialize failed');
        },
      );
      await expectLater(
          h.openAtLaunch('uid-a',
              reserveLaunch: launchReserver(onMint: (r) => minted = r)),
          throwsA(anything));
      expect(minted!.hasOpened, isTrue);
      expect(broker.openHolders, greaterThanOrEqualTo(1));
      await expectLater(
          broker.transition(DatabaseAccessMode.closed,
              timeout: const Duration(milliseconds: 30)),
          throwsA(isA<DatabaseAccessUnavailable>()));
      failing.failClose = false;
      h.dispose();
    });

    test('an unknown launch-open failure retains the pending reservation',
        () async {
      await seedLockedReplica('uid-a');
      openerFailure = StateError('native open failed somewhere');
      final h = host(store());
      await expectLater(
          h.openAtLaunch('uid-a', reserveLaunch: launchReserver()),
          throwsA(anything));
      expect(broker.pendingOpens, 1,
          reason: 'a possibly-open handle is never forgotten');
      h.dispose();
    });

    test('a launch refused before any open releases its reservation',
        () async {
      await seedLockedReplica('uid-a', unlock: false); // stays locked
      DatabaseOpenReservation? minted;
      final h = host(store());
      final scope = await h.openAtLaunch('uid-a',
          reserveLaunch: launchReserver(onMint: (r) => minted = r));
      expect(scope.uid, isNull, reason: 'signed-out scope');
      expect(openerCalls, 0);
      expect(minted, isNotNull);
      expect(minted!.hasOpened, isFalse);
      expect(broker.pendingOpens, 0, reason: 'known: nothing was opened');
      await h.lock();
      h.dispose();
    });

    test('the signed-out launch path is unchanged: no launch reservation',
        () async {
      var mints = 0;
      final h = host(store());
      final scope = await h.openAtLaunch(null,
          reserveLaunch: (uid) {
            mints++;
            return null;
          });
      expect(scope.uid, isNull);
      expect(mints, 0);
      expect(broker.pendingOpens, 0);
      expect(broker.openHolders, 1, reason: 'the ephemeral reservation only');
      await h.lock();
      h.dispose();
    });
  });

  group('AppSession admission turn', () {
    late DatabaseAccessBroker broker;
    late F2Fixture fixture;
    late List<int> pendingAtOpen;
    late List<int> holdersAtInitialize;
    void Function() onInitialize = () {};

    var firstBinding = true;

    Future<void> bind(SupabaseClient sdk) async {
      if (!firstBinding) {
        await fixture.session.bindSupabaseAuth(sdk);
        return;
      }
      // GoTrue replays its cached recovery event on the first subscription.
      final settled = Completer<void>();
      fixture.session.debugAuthEventCompleted = (event) {
        if (event == AuthChangeEvent.tokenRefreshed && !settled.isCompleted) {
          settled.complete();
        }
      };
      try {
        await fixture.session.bindSupabaseAuth(sdk);
        await settled.future;
      } finally {
        fixture.session.debugAuthEventCompleted = null;
      }
      firstBinding = false;
    }

    /// Same publication sequence as the broker / host-admission suites.
    Future<void> publishWithSdk(SupabaseClient sdk) async {
      final actual = sdk.auth.currentSession!;
      bool current() =>
          sdk.auth.currentSession?.accessToken == actual.accessToken &&
          sdk.auth.currentSession?.isExpired == false;
      await fixture.session.setIdentity(
          method: 'apple',
          email: actual.user.email,
          userId: actual.user.id,
          sessionCurrent: current);
      await fixture.session.finishOnboarding(client: sdk);
      await bind(sdk);
    }

    setUp(() async {
      broker = DatabaseAccessBroker.debugUnregistered();
      pendingAtOpen = [];
      holdersAtInitialize = [];
      onInitialize = () {};
      fixture = await F2Fixture.create(
        coordinator: broker,
        initialize: (db, uid) async {
          holdersAtInitialize.add(broker.openHolders);
          onInitialize();
          return const AccountScopeInit();
        },
        opener: (
            {ReplicaLocation? location,
            bool runMigrations = true,
            CreationPolicy creation = const CreationPolicy.unrestricted()}) {
          pendingAtOpen.add(broker.pendingOpens);
          return AppDatabase.open(
              location: location,
              runMigrations: runMigrations,
              creation: creation);
        },
      );
      // The issuer only recognizes the real host (not the gating wrapper).
      fixture.session.configureAccountScope(fixture.host);
    });

    tearDown(() async {
      await fixture.dispose();
      broker.debugDispose();
    });

    test('genuine first admission reserves before any opener', () async {
      await fixture.signIn('uid-first');
      expect(pendingAtOpen, [1]);
      expect(holdersAtInitialize.first, 1);
      final reservation = fixture.session.debugDatabaseOpenReservation;
      expect(reservation, isNotNull);
      expect(reservation!.uid, 'uid-first');
      expect(reservation.kind, DatabaseReservationKind.admissionPrimary);
      expect(reservation.coordinatorNonce, broker.processNonce);
      expect(reservation.hasOpened, isTrue);
      // A reservation is bookkeeping: no issuer, no job client, no mode.
      expect(fixture.session.captureDatabaseHostAdmission(), isNull);
      expect(broker.client.isHostIssued, isFalse);
      expect(broker.mode, DatabaseAccessMode.closed);
      expect(broker.pendingOpens, 0);
      expect(broker.openHolders, 1);
    });

    test('same-UID loss during initialization fails the open and closes it',
        () async {
      onInitialize = fixture.session.markSessionInvalid;
      try {
        await fixture.signIn('uid-loss');
      } catch (_) {}
      expect(holdersAtInitialize, isNotEmpty);
      expect(holdersAtInitialize.first, 1);
      expect(fixture.session.captureDatabaseHostAdmission(), isNull);
      expect(fixture.host.current?.uid, isNull,
          reason: 'the stale open was never published');
      expect(broker.pendingOpens, 0);
    });

    test('a different UID gets its own reservation and the old handle closes',
        () async {
      await fixture.signIn('uid-one');
      final first = fixture.session.debugDatabaseOpenReservation!;
      final firstDb = fixture.host.current!.database;
      onInitialize = () {};
      await fixture.signIn('uid-two');
      final second = fixture.session.debugDatabaseOpenReservation!;
      expect(identical(first, second), isFalse);
      expect(second.uid, 'uid-two');
      expect(firstDb.lifecycleState, DatabaseLifecycleState.closed);
      expect(broker.openHolders, 1, reason: 'only the new primary is tracked');
      expect(pendingAtOpen, [1, 1]);
    });

    test('committed publication promotes the exact tracked handle only',
        () async {
      final sdk = await fixture.clientFor('uid-promote');
      final actual = sdk.auth.currentSession!;
      await fixture.session.setIdentity(
          method: 'apple',
          email: actual.user.email,
          userId: actual.user.id,
          sessionCurrent: () =>
              sdk.auth.currentSession?.accessToken == actual.accessToken);
      final reservation = fixture.session.debugDatabaseOpenReservation!;
      expect(reservation.isPromoted, isFalse,
          reason: 'identity publication alone is not committed authority');
      expect(fixture.session.captureDatabaseHostAdmission(), isNull);
      await fixture.session.finishOnboarding(client: sdk);
      await bind(sdk);
      final receipt = fixture.session.captureDatabaseHostAdmission();
      expect(receipt, isNotNull);
      expect(reservation.isPromoted, isTrue);
      expect(
          identical(receipt!.database, fixture.host.current!.database), isTrue);
      expect(broker.openHolders, 1);
      await sdk.dispose();
    });

    test('genuine cold automatic admission still issues and promotes',
        () async {
      final sdk = await fixture.clientFor('uid-cold');
      await publishWithSdk(sdk);
      expect(fixture.session.captureDatabaseHostAdmission(), isNotNull);

      // Genuine restart over the same storage: the automatic admission opens
      // the existing replica under its own reservation.
      pendingAtOpen.clear();
      await fixture.restart();
      fixture.session.configureAccountScope(fixture.host);
      await fixture.session.bindSupabaseAuth(sdk);
      expect(fixture.host.current!.uid, 'uid-cold');
      expect(pendingAtOpen, [1], reason: 'reserved before the opener');
      final reservation = fixture.session.debugDatabaseOpenReservation!;
      expect(reservation.hasOpened, isTrue);
      expect(fixture.session.captureDatabaseHostAdmission(), isNotNull);
      expect(reservation.isPromoted, isTrue);
      await sdk.dispose();
    });

    // ---------------- O-H3 item 3: the cold-launch reservation (AppSession)

    /// A signed-in account that "died" while active; a NEW process: nothing in
    /// memory survives, so the launch must choose its owner again.
    Future<SupabaseClient> restartedAccount(String uid) async {
      final sdk = await fixture.clientFor(uid);
      await publishWithSdk(sdk);
      await fixture.restartWithoutLock();
      fixture.session.configureAccountScope(fixture.host);
      pendingAtOpen.clear();
      holdersAtInitialize.clear();
      return sdk;
    }

    test('only the launch AppSession itself chose can be reserved', () async {
      final sdk = await restartedAccount('uid-launch');
      final session = fixture.session;
      expect(session.coldLaunchReserver(LaunchAdmission.open('uid-launch')),
          isNull,
          reason: 'a forged launch admission mints nothing');
      expect(session.coldLaunchReserver(const LaunchAdmission.blocked()),
          isNull);
      final launch = await session.prepareLaunchAdmission();
      expect(launch.uid, 'uid-launch');
      final reserver = session.coldLaunchReserver(launch);
      expect(reserver, isNotNull);
      expect(reserver!('someone-else'), isNull,
          reason: 'only the owner the launch chose');
      final first = reserver('uid-launch');
      expect(first, isNotNull);
      expect(first!.kind, DatabaseReservationKind.coldLaunchPrimary);
      expect(first.coordinatorNonce, broker.processNonce);
      expect(reserver('uid-launch'), isNull, reason: 'single use');
      expect(session.coldLaunchReserver(launch), isNull,
          reason: 'already reserved');
      first.releaseUnopened();
      // A later prepare supersedes the earlier launch.
      final later = await session.prepareLaunchAdmission();
      expect(session.coldLaunchReserver(launch), isNull);
      expect(session.coldLaunchReserver(later), isNotNull);
      await sdk.dispose();
    });

    test('a signed-out launch has no cold-launch reservation', () async {
      final launch = await fixture.session.prepareLaunchAdmission();
      expect(launch.uid, isNull);
      expect(fixture.session.coldLaunchReserver(launch), isNull);
    });

    test(
        'cold launch reserves before the opener; the reservation cannot issue '
        'a job and is promoted only by committed publication', () async {
      final sdk = await restartedAccount('uid-launch');
      final launch = await fixture.session.prepareLaunchAdmission();
      final holdersBefore = broker.openHolders;
      final scope = await fixture.host.openAtLaunch('uid-launch',
          reserveLaunch: fixture.session.coldLaunchReserver(launch));
      expect(scope.uid, 'uid-launch');
      expect(pendingAtOpen, [1], reason: 'reserved before the opener');
      expect(holdersAtInitialize.first, holdersBefore + 1);
      final reservation = fixture.session.debugDatabaseOpenReservation!;
      expect(reservation.kind, DatabaseReservationKind.coldLaunchPrimary);
      expect(reservation.ownsDatabase(scope.database), isTrue);
      expect(broker.openHolders, holdersBefore + 1);
      expect(broker.pendingOpens, 0);
      // Opening is not authority: no job client, no mode, no receipt, no promotion.
      expect(broker.client.isHostIssued, isFalse);
      expect(broker.mode, DatabaseAccessMode.closed);
      expect(fixture.session.captureDatabaseHostAdmission(), isNull);
      expect(reservation.isPromoted, isFalse);

      // The fresh matching SDK (committed publication) promotes exactly it.
      await fixture.session.bindSupabaseAuth(sdk);
      expect(fixture.host.current!.uid, 'uid-launch');
      expect(pendingAtOpen, [1], reason: 'the launch open was the only open');
      expect(fixture.session.captureDatabaseHostAdmission(), isNotNull);
      expect(reservation.isPromoted, isTrue);
      expect(broker.openHolders, holdersBefore + 1);
      await sdk.dispose();
    });

    test('a launch reservation goes stale when the session signs out',
        () async {
      final sdk = await restartedAccount('uid-launch');
      final launch = await fixture.session.prepareLaunchAdmission();
      final reserver = fixture.session.coldLaunchReserver(launch)!;
      final reservation = reserver('uid-launch')!;
      expect(reservation.isCurrent, isTrue);
      await fixture.session.signOut();
      expect(reservation.isCurrent, isFalse);
      expect(reservation.promoteCommitted(Object(), uid: 'uid-launch'), isFalse);
      reservation.releaseUnopened();
      await sdk.dispose();
    });
  });
}
