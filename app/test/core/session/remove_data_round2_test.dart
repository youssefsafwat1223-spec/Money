import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/session/account_scope.dart'
    show AccountScopeInit;
import 'package:money_companion/core/session/admission_authority.dart';
import 'package:money_companion/core/session/app_session.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/creation_policy.dart';
import 'package:money_companion/data/db/replica_store.dart';

import 'f2_fixture.dart';

// F2 round 2 — the session-level requirements:
//
//   R2-1  Remove data removes EXACTLY the uid authorized when it was accepted.
//   R2-5  The admission is one transaction: revocation is lifted only by the
//         successful commit of a whole fresh admission; every continuation
//         re-checks its authority immediately before its final mutation;
//         sign-out and account switches invalidate authorities too.
//
// Every interleaving is driven with held storage operations and Completers.

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final session = AppSession.instance;
  late F2Fixture f;

  List<String> admissionWritesSince(int from) => [
        for (final a in f.storage.attempts.skip(from))
          if (a.startsWith('write:$kMarkerKey=') ||
              a.startsWith('write:$kGenerationKey=') ||
              a.startsWith('write:qirsh.db_key.'))
            a,
      ];

  /// Real time, because the removal's file I/O needs the event loop: a removal
  /// that should be blocked gets the chance to (wrongly) complete.
  Future<void> pump() =>
      Future<void>.delayed(const Duration(milliseconds: 150));

  group('R2-1 remove exactly the authorized uid', () {
    setUp(() async => f = await F2Fixture.create());
    tearDown(() async => f.dispose());

    test('R2-1 ownership moving to Y while X is being removed: the removal '
        'stays scoped to X; Y, its replica, key, registry entry and marker are '
        'untouched', () async {
      await f.signIn('uid-y');
      await f.signIn('uid-x'); // Y locked, X active and admitted
      final hashY = await f.hash('uid-y');
      final keyY = f.storage.data['qirsh.db_key.$hashY'];
      final entryY = (await f.registryEntry('uid-y'))!.toJson();
      final clientY = await f.clientFor('uid-y');

      // Y's reconcile claims the owner marker and pauses before minting its
      // generation: ownership has moved to Y, but X is still the admitted uid.
      final hold =
          f.storage.holdOnce((op, key) => op == 'read' && key == kGenerationKey);
      final retained = session.revalidateSupabaseSessionOnResume(clientY);
      await hold.reached.future;
      expect(await session.readLocalDataOwnerUid(), 'uid-y',
          reason: 'the marker already names Y');

      // The user, looking at X's Settings, removes X's data.
      final removal = session.removeDataFromDevice();
      hold.release.complete();
      await retained;
      await removal;

      expect(f.order, contains('begin:uid-x'));
      expect(f.order, contains('finish:uid-x'));
      expect(f.order, isNot(contains('begin:uid-y')),
          reason: 'Y was never the removal target');
      expect(await f.artifactsOf('uid-x'), isEmpty);
      expect(f.replicaDir(hashY).existsSync(), isTrue);
      expect(f.storage.data['qirsh.db_key.$hashY'], keyY);
      expect((await f.registryEntry('uid-y'))!.toJson(), entryY);
      expect(await session.readLocalDataOwnerUid(), 'uid-y',
          reason: 'Y\'s ownership marker is not X\'s to delete');
      expect(f.storage.deletes.where((d) => d.contains(hashY)), isEmpty);
    });

    test('R2-1 no synchronously-known admitted uid: fail closed, NOTHING is '
        'removed (not even the uid the owner marker names)', () async {
      await f.signIn('uid-z');
      final hashZ = await f.hash('uid-z');
      await f.restart(); // a new process: no scope, no admitted uid in memory
      session.debugResetAdmissionState();
      session.removalNoticePending.value = false;
      expect(await session.readLocalDataOwnerUid(), 'uid-z');

      await session.removeDataFromDevice();

      expect(
        f.order.where((c) => c.startsWith('begin:') || c.startsWith('finish:')),
        isEmpty,
        reason: 'no barrier, no sweep',
      );
      expect(f.replicaDir(hashZ).existsSync(), isTrue);
      expect(f.storage.data.containsKey('qirsh.db_key.$hashZ'), isTrue);
      expect(await f.registryEntry('uid-z'), isNotNull);
      expect(await session.readLocalDataOwnerUid(), 'uid-z');
      expect(session.status, isNot(SessionStatus.authenticated),
          reason: 'the device is still signed out locally');
      expect(session.removalNoticePending.value, isFalse,
          reason: 'nothing was removed, so no completion is claimed');
    });

    test('R2-1 the active scope\'s uid is the synchronously-known uid when no '
        'admission completed in this process', () async {
      await f.signIn('uid-z');
      // A process whose launch opened Z's existing replica without admitting Z
      // (no Supabase session): the scope is published, no admission completed.
      session.debugResetAdmissionState();
      expect(f.host.activeUid, 'uid-z');

      await session.removeDataFromDevice();

      expect(f.order, contains('begin:uid-z'));
      expect(await f.artifactsOf('uid-z'), isEmpty);
    });
  });

  group('R2-5 the admission is one transaction', () {
    setUp(() async => f = await F2Fixture.create());
    tearDown(() async => f.dispose());

    test('R2-5 a setIdentity continuation paused at an identity write is part '
        'of the quiescence: it cannot restore identity or status after Remove '
        'data', () async {
      final hold =
          f.storage.holdOnce((op, key) => op == 'write' && key == 'auth_method');
      Object? outcome;
      final signIn = session
          .setIdentity(method: 'google', email: 'x@example.com', userId: 'uid-x')
          .then<void>((_) {}, onError: (Object e) => outcome = e);
      await hold.reached.future;

      final removal = session.removeDataFromDevice();
      await pump();
      hold.release.complete();
      await signIn;
      await removal;

      expect(outcome, isA<StaleAdmissionException>());
      expect(session.authMethod, isNull);
      expect(session.status, isNot(SessionStatus.authenticated));
      expect(f.storage.data.containsKey('auth_method'), isFalse);
      expect(f.storage.data.containsKey('onboarding_current_account_v1'), isFalse);
      expect(await f.artifactsOf('uid-x'), isEmpty);
    });

    test('R2-5 an automatic reconcile paused at its identity write cannot '
        'leave identity behind a completed Remove data', () async {
      await f.signIn('uid-x');
      final client = await f.clientFor('uid-x');
      final hold = f.storage.holdOnce(
          (op, key) => op == 'write' && key == 'onboarding_current_account_v1');
      final retained = session.revalidateSupabaseSessionOnResume(client);
      await hold.reached.future;

      final removal = session.removeDataFromDevice();
      await pump();
      hold.release.complete();
      await retained;
      await removal;

      expect(f.storage.data.containsKey('onboarding_current_account_v1'), isFalse,
          reason: 'no identity key survives the removal');
      expect(session.status, isNot(SessionStatus.authenticated));
      expect(session.authMethod, isNull);
      expect(await f.artifactsOf('uid-x'), isEmpty);
    });

    test('R2-5 finishOnboarding paused at its first write cannot publish an '
        'authenticated status after Remove data', () async {
      await session.setIdentity(
          method: 'google', email: 'x@example.com', userId: 'uid-x');
      final hold =
          f.storage.holdOnce((op, key) => op == 'write' && key == 'onboarding_done');
      final finishing = session.finishOnboarding();
      await hold.reached.future;

      final removal = session.removeDataFromDevice();
      await pump();
      hold.release.complete();
      await finishing;
      await removal;

      expect(session.status, isNot(SessionStatus.authenticated));
      expect(session.hasCompletedOnboarding, isFalse,
          reason: 'the overtaken continuation must not mark onboarding done');
    });

    test('R2-5 sign-out invalidates the authorities captured before it: a '
        'reconcile in flight cannot re-admit the signed-out uid', () async {
      await f.signIn('uid-x');
      final client = await f.clientFor('uid-x');
      final hold = f.storage.holdOnce((op, key) => op == 'read' && key == kMarkerKey);
      final retained = session.revalidateSupabaseSessionOnResume(client);
      await hold.reached.future;

      await session.signOut();
      final from = f.storage.attempts.length;
      hold.release.complete();
      await retained;
      await session.drainAdmissions();

      expect(admissionWritesSince(from), isEmpty);
      expect(await session.readLocalDataOwnerUid(), isNull);
      expect(f.host.current!.uid, isNull);
      expect(session.status, isNot(SessionStatus.authenticated));
    });

    test('R2-5 an explicit account switch invalidates the authorities captured '
        'before it: a retained authority for X cannot flip the device back',
        () async {
      await f.signIn('uid-x');
      final clientX = await f.clientFor('uid-x');
      final authorityX = await session.maintenanceAuthority('uid-x');

      await f.signIn('uid-y'); // explicit switch X -> Y
      expect(authorityX.isCurrent, isFalse);
      final from = f.storage.attempts.length;

      await session.revalidateSupabaseSessionOnResume(clientX,
          authority: authorityX);
      await session.drainAdmissions();

      expect(await session.readLocalDataOwnerUid(), 'uid-y');
      expect(f.host.current!.uid, 'uid-y');
      expect(
        admissionWritesSince(from).where((a) => a.contains('uid-x')),
        isEmpty,
      );
    });
  });

  group('R2-5 failure at every admission stage after a removal', () {
    var failOpen = false;
    var failPublish = false;

    setUp(() async {
      failOpen = false;
      failPublish = false;
      f = await F2Fixture.create(
        initialize: (db, uid) async {
          if (failPublish && uid == 'uid-x') throw StateError('publication');
          return const AccountScopeInit();
        },
        opener: ({
          location,
          runMigrations = true,
          creation = const CreationPolicy.unrestricted(),
        }) async {
          final db = await AppDatabase.open(
              location: location,
              runMigrations: runMigrations,
              creation: creation);
          if (failOpen) {
            await db.close();
            throw StateError('open');
          }
          return db;
        },
      );
    });
    tearDown(() async => f.dispose());

    /// Fails the FIRST storage operation matching [match], then behaves.
    void failOnce(bool Function(String op, String key) match) {
      var armed = true;
      f.storage.gate = (op, key) async {
        if (armed && match(op, key)) {
          armed = false;
          throw StateError('injected');
        }
      };
    }

    Future<void> expectRolledBack(String stage, void Function(String hashX) arm) async {
      await f.signIn('uid-x');
      await session.removeDataFromDevice();
      final hashX = await f.hash('uid-x');
      expect(await f.flow.revokedUids(), contains('uid-x'));
      final client = await f.clientFor('uid-x');

      arm(hashX);
      final fresh = session.beginAuthAttempt();
      await expectLater(
        session.setIdentity(
            method: 'google',
            email: 'x@example.com',
            userId: 'uid-x',
            attempt: fresh),
        throwsA(anything),
        reason: stage,
      );
      f.storage.gate = null;
      failOpen = false;
      failPublish = false;

      expect(await f.flow.revokedUids(), contains('uid-x'),
          reason: '$stage: revocation stays in force');
      expect(await f.artifactsOf('uid-x'), isEmpty,
          reason: '$stage: partial side effects are rolled back');
      expect(await session.readLocalDataOwnerUid(), isNull, reason: stage);
      expect(f.storage.data.containsKey(kGenerationKey), isFalse, reason: stage);
      expect(session.status, isNot(SessionStatus.authenticated), reason: stage);

      // An automatic auth event cannot continue the admission.
      final from = f.storage.attempts.length;
      await session.revalidateSupabaseSessionOnResume(client);
      await session.drainAdmissions();
      expect(admissionWritesSince(from), isEmpty, reason: stage);
      expect(await f.artifactsOf('uid-x'), isEmpty, reason: stage);

      // A fresh explicit sign-in then succeeds, exactly once.
      await f.signIn('uid-x');
      expect(await f.artifactsOf('uid-x'), ['dir', 'key', 'registry'],
          reason: stage);
      expect(await f.flow.revokedUids(), isEmpty, reason: stage);
    }

    test('R2-5 stage: owner marker write', () async {
      await expectRolledBack('marker', (_) => failOnce(
          (op, key) => op == 'write' && key == kMarkerKey));
    });

    test('R2-5 stage: admission generation write', () async {
      await expectRolledBack('generation', (_) => failOnce(
          (op, key) => op == 'write' && key == kGenerationKey));
    });

    test('R2-5 stage: registry activation', () async {
      await expectRolledBack('registry', (_) => failOnce(
          (op, key) => op == 'write' && key == ReplicaStore.registryKey));
    });

    test('R2-5 stage: database key creation', () async {
      await expectRolledBack('key', (hash) => failOnce(
          (op, key) => op == 'write' && key == 'qirsh.db_key.$hash'));
    });

    test('R2-5 stage: database create/open (key and file already created)',
        () async {
      await expectRolledBack('open', (_) => failOpen = true);
    });

    test('R2-5 stage: scope publication', () async {
      await expectRolledBack('publication', (_) => failPublish = true);
    });

    test('R2-5 stage: identity commit after the scope was published', () async {
      await expectRolledBack('identity', (_) => failOnce(
          (op, key) => op == 'write' && key == 'auth_method'));
    });
  });
}
