import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/session/app_session.dart';
import 'package:money_companion/core/session/remove_data_flow.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../session/f2_fixture.dart';

// F2 — a Remove data that completed (or died half-way) must stay removed across
// a cold launch, whatever the owner marker, the registry and a stale Supabase
// session say. Every case reconstructs the session/store/host/flow from
// persisted state (`F2Fixture.restart`) and runs the launch steps in the order
// `BootstrapRunner._runSteps` runs them (pinned against the source below).
//
// GAP: `BootstrapRunner.run()` itself needs Supabase, notifications and the
// native capture queue and is not constructed here; `_launch` mirrors its
// removal/admission calls, and the last test pins their order in the source.

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late F2Fixture f;
  final session = AppSession.instance;

  setUp(() async => f = await F2Fixture.create());
  tearDown(() async => f.dispose());

  /// The launch sequence of `BootstrapRunner._runSteps`, minus plugins:
  /// removal recovery -> legacy recovery -> auth bind -> launch admission ->
  /// open-existing at launch -> unusable owner => not authenticated.
  Future<String?> launch({SupabaseClient? staleClient}) async {
    await session.load();
    await session.prepareLaunchAdmission(); // 'removal_recovery'
    await f.host.recoverAtLaunch(); // 'replica_recovery'
    if (staleClient != null) await session.bindSupabaseAuth(staleClient);
    final launchUid = (await session.prepareLaunchAdmission()).uid;
    await f.host.openAtLaunch(launchUid); // 'database_open'
    if (launchUid != null && f.host.current?.uid == null) {
      session.markSessionInvalid();
    }
    return launchUid;
  }

  List<String> admissionWritesSince(int from) => [
        for (final a in f.storage.attempts.skip(from))
          if (a.startsWith('write:$kMarkerKey=') ||
              a.startsWith('write:$kGenerationKey=') ||
              a.startsWith('write:qirsh.db_key.'))
            a,
      ];

  group('after a COMPLETED removal', () {
    test('cold launch with no SDK session opens nothing for X', () async {
      await f.signIn('uid-x');
      await session.removeDataFromDevice();
      await f.restart();
      final from = f.storage.attempts.length;

      expect(await launch(), isNull);

      expect(f.host.current!.uid, isNull, reason: 'signed-out scope');
      expect(await session.readLocalDataOwnerUid(), isNull);
      expect(await f.artifactsOf('uid-x'), isEmpty);
      expect(admissionWritesSince(from), isEmpty);
      expect(session.status, SessionStatus.needsOnboarding);
    });

    test('cold launch with the STALE persisted Supabase session of X still '
        'opens nothing and stays signed out', () async {
      await f.signIn('uid-x');
      final stale = await f.clientFor('uid-x');
      await session.removeDataFromDevice();
      await f.restart();
      final from = f.storage.attempts.length;

      expect(await launch(staleClient: stale), isNull);
      await session.revalidateSupabaseSessionOnResume(stale);
      await session.drainAdmissions();

      expect(admissionWritesSince(from), isEmpty);
      expect(await session.readLocalDataOwnerUid(), isNull);
      expect(await f.artifactsOf('uid-x'), isEmpty);
      expect(f.host.current!.uid, isNull);
      expect(session.status, isNot(SessionStatus.authenticated));
    });

    test('a STALE owner marker naming X (the keychain delete missed it) with '
        'no registry entry, file or key is never opened and is cleared',
        () async {
      await f.signIn('uid-x');
      await session.removeDataFromDevice();
      f.storage.data[kMarkerKey] = 'uid-x'; // the marker survived
      await f.restart();
      final from = f.storage.attempts.length;

      expect(await launch(), isNull);

      expect(f.storage.data.containsKey(kMarkerKey), isFalse,
          reason: 'verified absent, not trusted');
      expect(await f.artifactsOf('uid-x'), isEmpty);
      expect(admissionWritesSince(from), isEmpty);
      expect(f.host.current!.uid, isNull);
    });

    test('a launch for a stale marker that was NEVER removed but whose replica '
        'is gone opens the signed-out scope, creates nothing, and is routed to '
        'sign-in', () async {
      await f.signIn('uid-x');
      final h = await f.hash('uid-x');
      f.replicaDir(h).deleteSync(recursive: true);
      f.storage.data.remove('qirsh.db_key.$h');
      f.storage.data.remove('qirsh.replicas.v1');
      await f.restart();
      final from = f.storage.attempts.length;

      expect(await launch(), 'uid-x');

      expect(f.host.current!.uid, isNull);
      expect(admissionWritesSince(from), isEmpty);
      expect(await f.artifactsOf('uid-x'), isEmpty);
      expect(session.status, SessionStatus.sessionExpired);
    });

    test('an unreadable revoked-uid record fails the launch closed', () async {
      await f.signIn('uid-y');
      f.storage.data[RemoveDataFlow.revokedKey] = '{broken';
      await f.restart();
      expect(await launch(), isNull);
      expect(f.host.current!.uid, isNull);
    });
  });

  group('R2-6 the crash window after the durable record is deleted', () {
    test('R2-6 a completed removal whose identity cleanup never ran: the next '
        'launch forces signed-out status even though no active record exists',
        () async {
      await f.signIn('uid-x');
      // The process dies right after the removal deleted its durable record,
      // before the session cleared the persisted identity: only the flow ran.
      await f.flow.remove('uid-x');
      expect(await f.flow.hasPending(), isFalse);
      await f.restart();
      expect(session.status, SessionStatus.authenticated,
          reason: 'precondition: the leftover identity routes authenticated');

      await session.prepareLaunchAdmission();

      expect(session.status, isNot(SessionStatus.authenticated));
      expect(session.authMethod, isNull);
      expect(f.storage.data.containsKey('auth_method'), isFalse);
      expect(f.storage.data.containsKey('onboarding_current_account_v1'), isFalse);
    });

    test('R2-6 the same crash window with the leftover identity of ANOTHER '
        'account: that account is not signed out', () async {
      await f.signIn('uid-x');
      await session.removeDataFromDevice();
      await f.signIn('uid-y');
      await f.restart();
      await session.prepareLaunchAdmission();
      expect(session.status, SessionStatus.authenticated);
      expect(await session.readLocalDataOwnerUid(), 'uid-y');
    });
  });

  group('process death at every removal step', () {
    for (final step in kRemovalSteps) {
      test('after "$step": the next launch finishes the removal BEFORE it '
          'authenticates or opens anything', () async {
        await f.signIn('uid-y');
        await f.signIn('uid-x');
        final hashY = await f.hash('uid-y');
        f.crashAfterStep = step;
        await expectLater(session.removeDataFromDevice(),
            throwsA(isA<RemoveDataIncompleteException>()));
        f.crashAfterStep = null;
        final stale = await f.clientFor('uid-x');
        await f.restart(); // new store, host, flow: nothing in memory survives
        final from = f.storage.attempts.length;

        expect(await launch(staleClient: stale), isNull);
        await session.drainAdmissions();

        expect(await f.artifactsOf('uid-x'), isEmpty);
        expect(await session.readLocalDataOwnerUid(), isNull);
        expect(f.barrier.unknownBarrier, isFalse);
        expect(f.barrier.pending, isNull);
        expect(await f.flow.hasPending(), isFalse);
        expect(await f.flow.revokedUids(), {'uid-x'});
        expect(admissionWritesSince(from), isEmpty);
        expect(f.host.current!.uid, isNull);
        expect(session.authMethod, isNull, reason: 'identity cleaned up too');
        expect(f.replicaDir(hashY).existsSync(), isTrue,
            reason: 'the unrelated replica is untouched');
      });
    }
  });

  group('the native barrier', () {
    test('a barrier whose uid is unknown blocks the launch: no admission, no '
        'owner opened, no uid invented, nothing deleted', () async {
      await f.signIn('uid-y');
      f.barrier.unknownBarrier = true;
      await f.restart();
      final hashY = await f.hash('uid-y');

      expect(await launch(), isNull);

      expect(f.host.current!.uid, isNull);
      expect(f.barrier.unknownBarrier, isTrue, reason: 'left in place');
      expect(f.order.where((c) => c.startsWith('begin:') || c.startsWith('finish:')),
          isEmpty);
      expect(f.replicaDir(hashY).existsSync(), isTrue);
      expect(await session.readLocalDataOwnerUid(), 'uid-y',
          reason: 'the marker is not touched, just not opened');
    });

    test('an unreadable Dart record blocks the launch the same way', () async {
      await f.signIn('uid-y');
      f.storage.data[RemoveDataFlow.barrierKey] = '{broken';
      await f.restart();
      expect(await launch(), isNull);
      expect(f.host.current!.uid, isNull);
    });
  });

  test('the launch order in BootstrapRunner is pinned: removal state before '
      'legacy recovery, auth binding and the launch open', () {
    final src = File(
            '${Directory.current.path}/lib/core/startup/bootstrap_runner.dart')
        .readAsStringSync();
    int at(String needle) {
      final i = src.indexOf(needle);
      expect(i, greaterThan(-1), reason: needle);
      return i;
    }

    final removal = at("_step('removal_recovery'");
    final legacy = at("_step('replica_recovery'");
    final bind = at('bindSupabaseAuth(client)');
    final open = at("_step('database_open'");
    expect(removal, lessThan(legacy), reason: 'no adoption before removal state');
    expect(removal, lessThan(bind), reason: 'no auth binding before removal state');
    expect(bind, lessThan(open));
    expect(src.indexOf('prepareLaunchAdmission()', removal), lessThan(legacy));
    expect(src.lastIndexOf('prepareLaunchAdmission()'), lessThan(open),
        reason: 'the launch uid is filtered by the removal state');
    expect(src.contains('markSessionInvalid'), isTrue);
  });
}
