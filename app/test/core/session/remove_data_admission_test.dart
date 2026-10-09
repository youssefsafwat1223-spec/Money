import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/session/account_scope.dart' show AccountScopeInit;
import 'package:money_companion/core/session/admission_authority.dart';
import 'package:money_companion/core/session/app_session.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'f2_fixture.dart';
import 'recording_secure_storage.dart';

// F2 — "Remove data from this device" must not be undone by the admission path.
//
// Observed on device: within milliseconds of a removal for X, in the same
// process, X's owner marker was re-written, a new DB key minted and a new
// encrypted replica created, because the remounted AppShell's first-frame
// revalidation still saw a live Supabase session for X. These tests assert
// ATTEMPTED effects (marker/generation/key writes, replica artifacts), not only
// the final state: a recreated artifact that a later step deletes again would be
// invisible otherwise. Interleavings are driven with held operations and
// Completers, never sleeps.

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late F2Fixture f;
  final session = AppSession.instance;

  setUp(() async => f = await F2Fixture.create());
  tearDown(() async => f.dispose());

  /// The attempts made since [from] that would (re)admit a uid: owner marker,
  /// admission generation, any database key. Removal's own deletes are fine.
  List<String> admissionWritesSince(int from) => [
        for (final a in f.storage.attempts.skip(from))
          if (a.startsWith('write:$kMarkerKey=') ||
              a.startsWith('write:$kGenerationKey=') ||
              a.startsWith('write:qirsh.db_key.'))
            a,
      ];

  group('the core race', () {
    test('a remounted shell revalidating while Supabase still holds X cannot '
        're-admit X (no marker, generation, key or replica is attempted)',
        () async {
      await f.signIn('uid-x');
      final hashX = await f.hash('uid-x');
      expect(f.replicaDir(hashX).existsSync(), isTrue);
      expect(session.status, SessionStatus.authenticated);
      final client = await f.clientFor('uid-x');

      f.scope.holdAfterDetach = Hold();
      final from = f.storage.attempts.length;
      final removal = session.removeDataFromDevice();
      await f.scope.holdAfterDetach!.reached.future;
      expect(f.host.current!.uid, isNull, reason: 'signed-out scope published');

      // The generation-keyed ProviderScope remounted; AppShell's first frame runs
      // the revalidation while the Supabase session is still live.
      expect(await session.revalidateForShell(client), isFalse);
      await session.revalidateSupabaseSessionOnResume(client);

      f.scope.holdAfterDetach!.release.complete();
      await removal;

      expect(admissionWritesSince(from), isEmpty);
      expect(await session.readLocalDataOwnerUid(), isNull);
      expect(await f.artifactsOf('uid-x'), isEmpty);
      expect(f.host.current!.uid, isNull);
      expect(session.status, isNot(SessionStatus.authenticated));
    });

    test('acceptance revokes admission synchronously, before the first await',
        () async {
      await f.signIn('uid-x');
      final stale = session.beginAuthAttempt();
      final removal = session.removeDataFromDevice();
      // No microtask has run: everything below observes the state at acceptance.
      expect(session.status, SessionStatus.needsOnboarding);
      expect(session.authMethod, isNull);
      await expectLater(
        session.setIdentity(method: 'google', userId: 'uid-x', attempt: stale),
        throwsA(isA<StaleAdmissionException>()),
      );
      await removal;
    });

    test('admission of EVERY uid is withheld while the sweep runs', () async {
      await f.signIn('uid-y');
      await f.signIn('uid-x'); // Y locked, X active
      f.scope.holdAfterDetach = Hold();
      final removal = session.removeDataFromDevice();
      await f.scope.holdAfterDetach!.reached.future;

      final hashZ = await f.hash('uid-z');
      final from = f.storage.attempts.length;
      await expectLater(
        session.setIdentity(method: 'google', userId: 'uid-z'),
        throwsA(isA<StaleAdmissionException>()),
        reason: 'a sign-in during the destructive sweep is refused',
      );
      expect(admissionWritesSince(from), isEmpty);
      expect(f.replicaDir(hashZ).existsSync(), isFalse);

      f.scope.holdAfterDetach!.release.complete();
      await removal;
    });

    test('removal leaves unrelated replicas, keys and registry untouched',
        () async {
      await f.signIn('uid-y');
      await f.signIn('uid-x');
      final hashY = await f.hash('uid-y');
      final keyY = f.storage.data['qirsh.db_key.$hashY'];
      final entryY = (await f.registryEntry('uid-y'))!.toJson();

      await session.removeDataFromDevice();

      expect(await f.artifactsOf('uid-x'), isEmpty);
      expect(f.replicaDir(hashY).existsSync(), isTrue);
      expect(f.storage.data['qirsh.db_key.$hashY'], keyY);
      expect((await f.registryEntry('uid-y'))!.toJson(), entryY);
    });

    test('a missing owner marker does not skip the known admitted uid',
        () async {
      await f.signIn('uid-x');
      f.storage.data.remove(kMarkerKey); // cleared by some other interleaving
      await session.removeDataFromDevice();
      expect(await f.artifactsOf('uid-x'), isEmpty);
      expect(f.order, contains('begin:uid-x'));
    });
  });

  group('retained work paused at every ownership await, then Remove data',
      () {
    // The shell's revalidation (or any automatic reconcile) is already inside
    // the ownership resolution when Remove data is accepted. The marker was
    // cleared by another interleaving, so it takes the claim branch: exactly the
    // path that re-wrote it on the device.
    Future<void> acceptRemovalAndRelease(
        Hold hold, Future<void> retained, int from) async {
      final removal = session.removeDataFromDevice();
      hold.release.complete();
      await retained;
      await removal;
      expect(admissionWritesSince(from), isEmpty,
          reason: 'no write for X after Remove data was accepted');
      expect(await session.readLocalDataOwnerUid(), isNull);
      expect(await f.artifactsOf('uid-x'), isEmpty);
      expect(f.host.current!.uid, isNull);
    }

    test('held at the marker read', () async {
      await f.signIn('uid-x');
      f.storage.data.remove(kMarkerKey);
      final client = await f.clientFor('uid-x');
      final hold = f.storage.holdOnce((op, key) => op == 'read' && key == kMarkerKey);
      final retained = session.revalidateSupabaseSessionOnResume(client);
      await hold.reached.future;
      await acceptRemovalAndRelease(hold, retained, f.storage.attempts.length);
    });

    test('held inside the residue purge hook (before the claim)', () async {
      await f.signIn('uid-x');
      f.storage.data.remove(kMarkerKey);
      final client = await f.clientFor('uid-x');
      final reached = Completer<void>();
      final release = Completer<void>();
      session.configureCaptureOwnerClear(() async {
        if (!reached.isCompleted) {
          reached.complete();
          await release.future;
        }
        return true;
      });
      final retained = session.revalidateSupabaseSessionOnResume(client);
      await reached.future;
      final hold = Hold()..release.future.then((_) => release.complete());
      await acceptRemovalAndRelease(hold, retained, f.storage.attempts.length);
    });

    test('held between the generation read and its write', () async {
      await f.signIn('uid-x');
      f.storage.data
        ..remove(kMarkerKey)
        ..remove(kGenerationKey);
      final client = await f.clientFor('uid-x');
      final hold =
          f.storage.holdOnce((op, key) => op == 'read' && key == kGenerationKey);
      final retained = session.revalidateSupabaseSessionOnResume(client);
      await hold.reached.future;
      // The marker write was dispatched before acceptance; the generation was not.
      final from = f.storage.attempts.length;
      expect(f.storage.attemptsTo('$kMarkerKey='), hasLength(2),
          reason: 'sign-in claim + the retained claim, both before acceptance');
      await acceptRemovalAndRelease(hold, retained, from);
    });

    test('a marker write already dispatched drains before deletion and the '
        'continuation then publishes nothing', () async {
      await f.signIn('uid-x');
      f.storage.data.remove(kMarkerKey);
      final client = await f.clientFor('uid-x');
      final hold =
          f.storage.holdOnce((op, key) => op == 'write' && key == kMarkerKey);
      final retained = session.revalidateSupabaseSessionOnResume(client);
      await hold.reached.future;

      final from = f.storage.attempts.length; // the marker write is BEFORE this
      var removalDone = false;
      final removal = session.removeDataFromDevice().then((_) => removalDone = true);
      for (var i = 0; i < 20; i++) {
        await Future<void>.value(); // let the removal run as far as it can
      }
      expect(removalDone, isFalse,
          reason: 'removal must wait for the dispatched write to drain');
      expect(f.order, isNot(contains('begin:uid-x')),
          reason: 'nothing destructive before the drain');

      hold.release.complete();
      await retained;
      await removal;
      expect(admissionWritesSince(from), isEmpty);
      expect(await session.readLocalDataOwnerUid(), isNull,
          reason: 'the drained marker write was swept by the removal');
      expect(await f.artifactsOf('uid-x'), isEmpty);
    });

    test('an explicit sign-in paused before scope publication is stale once '
        'Remove data is accepted: X is removed and Y stays unpublished and unchanged',
        () async {
      final gate = Completer<void>();
      final reached = Completer<void>();
      await f.dispose();
      f = await F2Fixture.create(initialize: (db, uid) async {
        if (uid == 'uid-y') {
          reached.complete();
          await gate.future;
        }
        return const AccountScopeInit();
      });
      await f.signIn('uid-x');
      final signInY = session.setIdentity(method: 'google', userId: 'uid-y');
      final signInOutcome =
          expectLater(signInY, throwsA(isA<StaleAdmissionException>()));
      await reached.future; // Y claimed the marker; its replica is opening
      final hashY = await f.hash('uid-y');
      final keyY = f.storage.data['qirsh.db_key.$hashY'];
      final entryY = (await f.registryEntry('uid-y'))!.toJson();
      final from = f.storage.attempts.length;
      final removal = session.removeDataFromDevice(); // immutable admitted X
      gate.complete();
      await signInOutcome;
      await removal;
      expect(f.host.current!.uid, isNull, reason: 'Y was not published');
      expect(await session.readLocalDataOwnerUid(), 'uid-y');
      expect(await f.artifactsOf('uid-x'), isEmpty);
      expect(await f.artifactsOf('uid-y'), ['dir', 'key', 'registry']);
      expect(f.storage.data['qirsh.db_key.$hashY'], keyY);
      expect((await f.registryEntry('uid-y'))!.toJson(), entryY);
      expect(f.order, contains('begin:uid-x'));
      expect(f.order, isNot(contains('begin:uid-y')));
      expect(f.storage.attempts.skip(from).where((a) =>
          a.startsWith('delete:qirsh.db_key.$hashY') ||
          a.startsWith('write:$kMarkerKey=uid-y')), isEmpty);
      expect(session.status, isNot(SessionStatus.authenticated));
    });
  });

  group('automatic auth events after Remove data', () {
    test('stale initialSession / signedIn / resume revalidation for X do not '
        'admit X even once another uid is signed in explicitly', () async {
      await f.signIn('uid-x');
      final client = await f.clientFor('uid-x'); // the stale live session
      await session.removeDataFromDevice();
      await session.bindSupabaseAuth(client); // initialSession for X

      // An explicit sign-in of Y makes the session machinery live again...
      await session.setIdentity(method: 'google', userId: 'uid-y');
      final from = f.storage.attempts.length;
      // ...and every automatic callback still carrying X is refused.
      await session.revalidateSupabaseSessionOnResume(client);
      final events = <AuthChangeEvent>[];
      final sub = client.auth.onAuthStateChange.listen((s) => events.add(s.event));
      await client.auth.signInWithPassword(
          email: 'uid-x@example.com', password: 'pw'); // signedIn
      await client.auth.refreshSession(); // tokenRefreshed
      await client.auth.updateUser(UserAttributes(data: {'k': 'v'})); // userUpdated
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await sub.cancel();
      expect(events, containsAll([
        AuthChangeEvent.signedIn,
        AuthChangeEvent.tokenRefreshed,
        AuthChangeEvent.userUpdated,
      ]), reason: 'real SDK events reach the bound listener: $events');
      await session.drainAdmissions();

      expect(admissionWritesSince(from), isEmpty);
      expect(await session.readLocalDataOwnerUid(), 'uid-y');
      expect(await f.artifactsOf('uid-x'), isEmpty);
    });

    test('events delivered while the removal runs authorize nothing',
        () async {
      await f.signIn('uid-x');
      final client = await f.clientFor('uid-x');
      await session.bindSupabaseAuth(client);
      f.scope.holdAfterDetach = Hold();
      final from = f.storage.attempts.length;
      final removal = session.removeDataFromDevice();
      await f.scope.holdAfterDetach!.reached.future;

      await client.auth.refreshSession(); // tokenRefreshed
      await session.revalidateSupabaseSessionOnResume(client);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      f.scope.holdAfterDetach!.release.complete();
      await removal;
      expect(admissionWritesSince(from), isEmpty);
      expect(await f.artifactsOf('uid-x'), isEmpty);
    });
  });

  group('one removal execution', () {
    test('two Remove data requests and a resume share ONE execution',
        () async {
      await f.signIn('uid-x');
      f.scope.holdAfterDetach = Hold();
      final first = session.removeDataFromDevice();
      await f.scope.holdAfterDetach!.reached.future;
      final second = session.removeDataFromDevice();
      final resume = f.flow.resumePending();
      f.scope.holdAfterDetach!.release.complete();
      await first;
      await second;
      expect(await resume, isTrue);
      expect(f.order.where((c) => c == 'begin:uid-x'), hasLength(1));
      expect(f.order.where((c) => c == 'finish:uid-x'), hasLength(1));
      expect(await f.artifactsOf('uid-x'), isEmpty);
    });
  });

  group('after a completed removal', () {
    test('a login attempt captured BEFORE the removal cannot recreate X, '
        'a failed login changes nothing, and a fresh explicit sign-in succeeds '
        'exactly once', () async {
      await f.signIn('uid-x');
      final hashX = await f.hash('uid-x');
      final oldGeneration = f.storage.data[kGenerationKey];
      final preRemoval = session.beginAuthAttempt();
      final oldMaintenance = await session.maintenanceAuthority('uid-x');

      await session.removeDataFromDevice();
      final from = f.storage.attempts.length;
      expect(oldMaintenance.isCurrent, isFalse, reason: 'old tokens are invalid');
      expect((await f.flow.revokedUids()), contains('uid-x'));

      // The provider completes for a pre-removal attempt: refused, nothing written.
      await expectLater(
        session.setIdentity(
            method: 'google', userId: 'uid-x', attempt: preRemoval),
        throwsA(isA<StaleAdmissionException>()),
      );
      // A failed login (provider error) never reaches the session at all.
      expect(admissionWritesSince(from), isEmpty);
      expect(await f.artifactsOf('uid-x'), isEmpty);

      // A NEW explicit attempt, started after the removal, succeeds.
      final fresh = session.beginAuthAttempt();
      await session.setIdentity(
          method: 'google', userId: 'uid-x', email: 'x@example.com', attempt: fresh);
      List<String> since(String prefix) => [
            for (final a in f.storage.attempts.skip(from))
              if (a.startsWith('write:$prefix')) a,
          ];
      expect(since('qirsh.db_key.$hashX'), hasLength(1),
          reason: 'exactly one key for exactly one fresh replica');
      expect(since('$kMarkerKey='), hasLength(1));
      expect(await f.artifactsOf('uid-x'), ['dir', 'key', 'registry']);
      expect(f.host.current!.uid, 'uid-x');
      final owner = await f.host.current!.database
          .customSelect('SELECT owner_uid FROM replica_meta;')
          .getSingle();
      expect(owner.read<String>('owner_uid'), 'uid-x');
      expect(f.storage.data[kGenerationKey], isNot(oldGeneration),
          reason: 'a new admission generation');
      expect(await session.consentPromptSeen(), isFalse,
          reason: 'the fresh replica asks the consent question again');
      expect(await f.flow.revokedUids(), isEmpty,
          reason: 'the explicit admission lifted the revocation');
    });

    test('the revocation survives a restart; an automatic reconcile after the '
        'restart still cannot admit X', () async {
      await f.signIn('uid-x');
      final client = await f.clientFor('uid-x');
      await session.removeDataFromDevice();
      await f.restart();
      final from = f.storage.attempts.length;

      await session.setIdentity(method: 'google', userId: 'uid-y');
      await session.revalidateSupabaseSessionOnResume(client);
      await session.drainAdmissions();

      expect(admissionWritesSince(from).where((a) => a.contains('uid-x')), isEmpty);
      expect(await f.artifactsOf('uid-x'), isEmpty);
      expect(await session.readLocalDataOwnerUid(), 'uid-y');
    });
  });

  group('call-site pins (the guarded boundaries stay guarded)', () {
    String read(String path) =>
        File('${Directory.current.path}/$path').readAsStringSync();

    test('auth_screen captures the attempt BEFORE awaiting the provider and '
        'passes it to setIdentity', () {
      final src = read('lib/features/onboarding/auth_screen.dart');
      final capture = src.indexOf('beginAuthAttempt()');
      final provider = src.indexOf('await method()');
      final admit = src.indexOf('attempt: attempt');
      expect(capture, greaterThan(-1));
      expect(capture, lessThan(provider));
      expect(provider, lessThan(admit));
    });

    test('AppShell revalidates through AppSession.revalidateForShell and no '
        'longer accepts "not sessionExpired"', () {
      final src = read('lib/features/app/app_shell.dart');
      expect(src.contains('revalidateForShell'), isTrue);
      expect(src.contains('!= SessionStatus.sessionExpired'), isFalse);
    });

    test('Settings hands the provider/SDK logout to the session layer instead '
        'of running it after a possibly disposed screen', () {
      final src = read('lib/features/settings/settings_screen.dart');
      expect(src.contains('removeDataFromDevice(signOutRemote'), isTrue);
    });

    test('removeDataFromDevice revokes admission before its first await', () {
      final src = read('lib/core/session/app_session.dart');
      final fn = src.substring(src.indexOf('Future<void> removeDataFromDevice('));
      final body = fn
          .substring(0, fn.indexOf('\n  }\n'))
          .split('\n')
          .where((l) => !l.trimLeft().startsWith('//'))
          .join('\n');
      final firstAwait = body.indexOf('await ');
      for (final needle in [
        '_removalsAccepted++',
        '_admissionEpoch++',
        '_authLossSeq++',
        'authMethod = null',
        'value = SessionStatus.needsOnboarding',
      ]) {
        final at = body.indexOf(needle);
        expect(at, greaterThan(-1), reason: needle);
        expect(at, lessThan(firstAwait), reason: '$needle must precede any await');
      }
    });
  });
}
