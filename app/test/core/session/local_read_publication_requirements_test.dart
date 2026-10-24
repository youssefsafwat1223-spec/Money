// SDK event injection uses the real GoTrue broadcast; no production use.
// ignore_for_file: invalid_use_of_internal_member, invalid_use_of_protected_member

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/session/account_scope.dart';
import 'package:money_companion/core/session/app_session.dart';
import 'package:money_companion/core/session/local_read_authority.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/creation_policy.dart';
import 'package:money_companion/data/db/database_access_broker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../support/uncoordinated_local_read.dart';
import 'f2_fixture.dart';

// Astra R45 R8 — production publication of a local-read scope requires the
// coordinator AND the exact exclusion-backed reservation under which the
// read-only handle was opened. A verified restore that carries no reservation,
// another coordinator's reservation, or a handle the coordinator does not track
// never becomes the published scope.

const _uid = 'uid-publication';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late F2Fixture f;
  late LocalReadAuthority authority;
  late DatabaseAccessBroker coordinator;
  late List<SupabaseClient> clients;

  setUp(() async {
    await AppSession.instance.debugResetAuthBinding();
    clients = [];
    coordinator = DatabaseAccessBroker.debugUnregistered();
    f = await F2Fixture.create(
      coordinator: coordinator,
      opener: (
          {location,
          runMigrations = true,
          creation = const CreationPolicy.unrestricted()}) {
        return AppDatabase.open(
            location: location,
            runMigrations: runMigrations,
            creation: creation);
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

  /// Signed in once (grant committed), then a "new process" over the same files.
  Future<void> seededAndRestarted() async {
    final sdk = await f.clientFor(_uid);
    clients.add(sdk);
    await f.session.bindSupabaseAuth(sdk);
    await f.session.setIdentity(
        method: 'google', email: '$_uid@example.com', userId: _uid);
    await f.session.finishOnboarding(client: sdk);
    await f.restartWithoutLock();
    f.session.configureAccountScope(f.host);
    f.session.configureLocalRead(authority);
  }

  /// A verified restore obtained WITHOUT the coordinator seam (the shape R8
  /// forbids in production; only the explicit testing API may produce it).
  Future<LocalReadRestore> uncoordinatedRestore() =>
      authority.restoreUncoordinated(f.store);

  Future<void> expectRefusedAndClosed(LocalReadRestore verified) async {
    expect(verified.isGranted, isTrue);
    final db = verified.replica!.database;
    await expectLater(f.host.restoreLocalRead(verified),
        throwsA(isA<StaleLocalReadException>()));
    expect(f.host.current, isNull, reason: 'nothing was published');
    expect(db.lifecycleState, DatabaseLifecycleState.closed,
        reason: 'the refused handle is closed through its close path');
  }

  group('R8 publication requires the exact exclusion-backed reservation', () {
    test('a restore with no reservation cannot be published', () async {
      await seededAndRestarted();
      await expectRefusedAndClosed(await uncoordinatedRestore());
    });

    test("another coordinator's exclusion candidate cannot be published",
        () async {
      await seededAndRestarted();
      final foreign = DatabaseAccessBroker.debugUnregistered();
      addTearDown(foreign.debugDispose);
      final exclusion = foreign.beginLocalReadExclusion();
      await exclusion.awaitDrained();
      final verified = await authority.restore(
        f.store,
        reserve: (uid) => exclusion.reserveLocalReadCandidate(uid: uid),
        verifyExclusion: (_) =>
            exclusion.verifyLegacyHolders(LegacyHolderEvidence.clear),
      );
      addTearDown(() => exclusion.release(published: false));
      await expectRefusedAndClosed(verified);
    });

    test('a reservation that is no longer current cannot be published',
        () async {
      await seededAndRestarted();
      final exclusion = coordinator.beginLocalReadExclusion();
      await exclusion.awaitDrained();
      final verified = await authority.restore(
        f.store,
        reserve: (uid) => exclusion.reserveLocalReadCandidate(uid: uid),
        verifyExclusion: (_) =>
            exclusion.verifyLegacyHolders(LegacyHolderEvidence.clear),
      );
      exclusion.release(published: false); // the fence is gone before publish
      await expectRefusedAndClosed(verified);
    });

    test('a host with no coordinator (explicit fixture) publishes nothing',
        () async {
      await seededAndRestarted();
      final bare = AccountScopeHost.uncoordinatedForTesting(
          store: f.store,
          initialize: (db, uid) async => const AccountScopeInit());
      addTearDown(bare.dispose);
      final exclusion = coordinator.beginLocalReadExclusion();
      await exclusion.awaitDrained();
      addTearDown(() => exclusion.release(published: false));
      expect(() => bare.localReadReserver(exclusion: exclusion),
          throwsA(isA<DatabaseAccessUnavailable>()),
          reason: 'no coordinator, no local-read reservation');
      final verified = await authority.restore(
        f.store,
        reserve: f.host.localReadReserver(exclusion: exclusion),
        verifyExclusion: (_) =>
            exclusion.verifyLegacyHolders(LegacyHolderEvidence.clear),
      );
      final db = verified.replica!.database;
      await expectLater(bare.restoreLocalRead(verified),
          throwsA(isA<StaleLocalReadException>()));
      expect(bare.current, isNull);
      expect(db.lifecycleState, DatabaseLifecycleState.closed);
    });

    test('the genuine exclusion-backed reservation publishes and is tracked',
        () async {
      await seededAndRestarted();
      final baseline = coordinator.openHolders;
      final exclusion = coordinator.beginLocalReadExclusion();
      await exclusion.awaitDrained();
      final verified = await authority.restore(
        f.store,
        reserve: f.host.localReadReserver(exclusion: exclusion),
        verifyExclusion: (_) =>
            exclusion.verifyLegacyHolders(LegacyHolderEvidence.clear),
      );
      final scope = await f.host.restoreLocalRead(verified);
      exclusion.release(published: true);
      expect(scope.isLocalRead, isTrue);
      expect(coordinator.mode, DatabaseAccessMode.localRead);
      expect(coordinator.openHolders, baseline + 1,
          reason: 'the handle is tracked');
    });
  });
}
