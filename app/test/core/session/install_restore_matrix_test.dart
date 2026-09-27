import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/session/app_session.dart';

/// AUDIT 2 — THE INSTALL / REINSTALL / KEYCHAIN / RESTORE STATE MATRIX.
///
/// Every one of these is a real user state, because the four stores that decide
/// ownership have INDEPENDENT lifetimes:
///
///   * the Keychain survives app deletion entirely;
///   * the Drift database does not;
///   * an iCloud/device restore brings back files but NOT Keychain items marked
///     `first_unlock_this_device`, which is the accessibility this app uses;
///   * the App Group container is separate again.
///
/// The P0 that motivated this audit lived in exactly that gap: a stale Keychain
/// owner marker plus a fresh database produced an ownership transition that
/// wiped and then could not record completion, so it wiped again on every
/// launch forever.
///
/// The property under test throughout is CONVERGENCE: repeated launches from any
/// starting combination must reach a stable state, and must never destroy data
/// they cannot finish claiming.

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<String> calls;
  late bool purgeAvailable;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    calls = <String>[];
    purgeAvailable = true;

    AppSession.instance.configureCaptureDeviceUnlink(null);
    AppSession.instance.configureLocalDataWipe(() async => calls.add('wipe'));
    AppSession.instance.configureLocalResiduePurge(() async {
      calls.add('purge');
      return purgeAvailable;
    });
    await AppSession.instance.wipeAndReset();
    calls.clear();
  });

  tearDown(() async {
    AppSession.instance.configureLocalDataWipe(null);
    AppSession.instance.configureLocalResiduePurge(null);
    await AppSession.instance.wipeAndReset();
  });

  Future<String?> owner() => AppSession.instance.readLocalDataOwnerUid();
  int count(String c) => calls.where((e) => e == c).length;

  /// One "launch": the app reconciles an authenticated identity. Throws
  /// LocalDataOwnershipException when admission is withheld, exactly as the
  /// interactive sign-in path surfaces it.
  Future<Object?> launchAs(String uid) async {
    try {
      await AppSession.instance.setIdentity(method: 'google', userId: uid);
      return null;
    } catch (e) {
      return e;
    }
  }

  group('A. fresh install — keychain empty, DB empty', () {
    test('claims without destroying anything', () async {
      expect(await owner(), isNull);
      expect(await launchAs('uid-a'), isNull);

      expect(count('wipe'), 0, reason: 'nothing existed to displace');
      expect(await owner(), 'uid-a');
    });
  });

  group('B. reinstall — keychain survives, DB is new', () {
    test('the SAME user re-installing does no destructive work', () async {
      await launchAs('uid-a');
      calls.clear();

      // Reinstall: the DB is gone but the Keychain marker is not.
      expect(await launchAs('uid-a'), isNull);
      expect(calls, isEmpty, reason: 'same owner — nothing to transition');
      expect(await owner(), 'uid-a');
    });
  });

  group('D. stale keychain owner + a DIFFERENT authenticated user', () {
    test('transitions once, then converges', () async {
      await launchAs('uid-a'); // the marker the reinstall left behind
      calls.clear();

      expect(await launchAs('uid-b'), isNull);
      expect(calls, ['purge', 'wipe'], reason: 'purge proves, then wipe');
      expect(await owner(), 'uid-b');

      // THE regression: every subsequent launch must be inert.
      for (var launch = 0; launch < 5; launch++) {
        calls.clear();
        expect(await launchAs('uid-b'), isNull);
        expect(calls, isEmpty, reason: 'launch $launch must do nothing');
      }
    });
  });

  group('E/F. App Group residue vs main DB — independent lifetimes', () {
    test('residue that cannot be purged blocks the wipe, not the user',
        () async {
      // F: the main DB is here, the App Group state is not reachable (the
      // channel is down, the container is missing) so the purge cannot confirm.
      await launchAs('uid-a');
      calls.clear();
      purgeAvailable = false;

      for (var launch = 0; launch < 4; launch++) {
        final err = await launchAs('uid-b');
        expect(err, isA<LocalDataOwnershipException>(),
            reason: 'admission withheld, fail closed');
      }

      expect(count('wipe'), 0, reason: 'NOTHING destroyed while blocked');
      expect(await owner(), 'uid-a', reason: 'A still owns their own data');
      expect(count('purge'), 4, reason: 'it keeps trying across launches');
    });

    test('once the residue CAN be purged the transition completes', () async {
      await launchAs('uid-a');
      purgeAvailable = false;
      await launchAs('uid-b'); // blocked
      calls.clear();

      purgeAvailable = true; // channel comes up / container reachable
      expect(await launchAs('uid-b'), isNull);

      expect(calls, ['purge', 'wipe']);
      expect(await owner(), 'uid-b');
    });
  });

  group('G. auth session is user B while the local marker says A', () {
    test('B never sees A\'s data without a completed transition', () async {
      await launchAs('uid-a');
      purgeAvailable = false;

      final err = await launchAs('uid-b');

      expect(err, isA<LocalDataOwnershipException>());
      expect(AppSession.instance.status, isNot(SessionStatus.authenticated),
          reason: 'B is not admitted onto A\'s database');
      expect(await owner(), 'uid-a');
    });
  });

  group('H. logout A then immediate sign-in as B', () {
    test('sign-out wipes and releases; B then claims a clean DB', () async {
      await launchAs('uid-a');
      calls.clear();

      await AppSession.instance.signOut();
      expect(count('wipe'), 1, reason: 'an explicit sign-out DOES wipe');
      expect(await owner(), isNull, reason: 'ownership released on clean purge');

      calls.clear();
      expect(await launchAs('uid-b'), isNull);
      expect(count('wipe'), 0, reason: 'nothing left to displace');
      expect(await owner(), 'uid-b');
    });

    test('a sign-out whose purge fails KEEPS the marker, so B is forced through '
        'the fail-closed path rather than inheriting residue', () async {
      await launchAs('uid-a');
      purgeAvailable = false;

      await AppSession.instance.signOut();
      expect(await owner(), 'uid-a', reason: 'not released without proof');

      final err = await launchAs('uid-b');
      expect(err, isA<LocalDataOwnershipException>());
      expect(await owner(), 'uid-a');
    });
  });

  group('I. process killed during the ownership transition', () {
    test('killed AFTER the wipe but BEFORE the claim still converges',
        () async {
      await launchAs('uid-a');
      calls.clear();

      // Launch 1: purge and wipe succeed, then the process dies before the
      // claim is durable. Simulated by resetting the marker to A afterwards.
      expect(await launchAs('uid-b'), isNull);
      expect(calls, ['purge', 'wipe']);
      // Simulate the process dying before the claim reached the Keychain by
      // putting the OLD marker back through the same storage the session uses.
      // `local_data_owner_uid` is the key AppSession writes (app_session.dart:55).
      await const FlutterSecureStorage()
          .write(key: 'local_data_owner_uid', value: 'uid-a');

      // Launch 2: the same conflict is seen again. The wipe is harmless (the DB
      // is already empty) and this time the claim lands.
      calls.clear();
      expect(await launchAs('uid-b'), isNull);
      expect(calls, ['purge', 'wipe']);
      expect(await owner(), 'uid-b');

      // Launch 3 onward: inert. This is convergence, not a loop.
      calls.clear();
      expect(await launchAs('uid-b'), isNull);
      expect(calls, isEmpty);
    });
  });

  group('convergence is the property, from every starting point', () {
    test('ten launches from a stale marker end in exactly one transition',
        () async {
      await launchAs('uid-a');
      calls.clear();

      for (var i = 0; i < 10; i++) {
        await launchAs('uid-b');
      }

      expect(count('wipe'), 1, reason: 'ONE transition across ten launches');
      expect(count('purge'), 1);
      expect(await owner(), 'uid-b');
    });
  });
}
