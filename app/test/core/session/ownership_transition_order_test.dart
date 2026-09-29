import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/session/app_session.dart';

/// THE OWNERSHIP TRANSITION MUST NEVER DESTROY DATA IT CANNOT FINISH CLAIMING.
///
/// A TestFlight build wiped every user's financial data on EVERY launch. The
/// mechanism was an ordering bug, not a wipe bug:
///
///   1. the Keychain still held a PREVIOUS owner uid (Keychain survives app
///      deletion, so a reinstall or a different account leaves one behind);
///   2. bootstrap saw owner != current uid and ran the transition;
///   3. the transition wiped FIRST, then tried to purge native capture residue;
///   4. the purge calls a method channel that, under the UIScene lifecycle, is
///      not registered yet during `didFinishLaunchingWithOptions` — Dart
///      bootstrap runs inside that window and got MissingPluginException;
///   5. `!residuePurged` returned WITHOUT clearing or re-claiming the owner
///      marker — so the data was gone and the marker still mismatched;
///   6. next launch: identical mismatch, identical wipe. Forever.
///
/// The fix is that nothing destructive runs until the step that must follow it
/// has already succeeded: invalidate → purge → wipe → claim. These tests pin
/// that order and the failure modes around it.

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Every destructive/ownership step appends here, so ORDER is assertable and
  // not just the counts.
  late List<String> calls;
  late bool purgeResult;
  late int purgeFailuresBeforeSuccess;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    calls = <String>[];
    purgeResult = true;
    purgeFailuresBeforeSuccess = 0;

    AppSession.instance.configureCaptureDeviceUnlink(null);
    AppSession.instance.configureLocalDataWipe(() async {
      calls.add('wipe');
    });
    AppSession.instance.configureLocalResiduePurge(() async {
      calls.add('purge');
      if (purgeFailuresBeforeSuccess > 0) {
        purgeFailuresBeforeSuccess--;
        return false;
      }
      return purgeResult;
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

  /// Puts a DIFFERENT previous owner in the Keychain, the way a reinstall or a
  /// previous account does.
  Future<void> seedPreviousOwner(String uid) async {
    await AppSession.instance.setIdentity(method: 'google', userId: uid);
    calls.clear();
  }

  group('1. owner mismatch + purge not ready on the first attempt', () {
    test('nothing is wiped until the purge succeeds, then exactly once',
        () async {
      await seedPreviousOwner('uid-old');
      purgeFailuresBeforeSuccess = 1; // channel not ready on the first try

      // Launch 1 — the purge cannot confirm. This must be a SAFE stop.
      await expectLater(
        AppSession.instance.setIdentity(method: 'google', userId: 'uid-new'),
        throwsA(isA<LocalDataOwnershipException>()),
      );

      expect(calls, ['purge'],
          reason: 'the purge was attempted and NOTHING was destroyed');
      expect(calls.contains('wipe'), isFalse, reason: 'THE regression');
      expect(await owner(), 'uid-old',
          reason: 'the marker is untouched, so the retry still sees the '
              'conflict rather than a half-finished transition');

      // Launch 2 — the channel is up, the purge succeeds.
      calls.clear();
      await AppSession.instance
          .setIdentity(method: 'google', userId: 'uid-new');

      expect(calls, ['purge', 'wipe'], reason: 'purge BEFORE wipe');
      expect(calls.where((c) => c == 'wipe').length, 1, reason: 'exactly once');
      expect(await owner(), 'uid-new', reason: 'ownership claimed exactly once');
    });
  });

  group('2. owner mismatch + purge permanently fails', () {
    test('no wipe, no claim, previous owner intact', () async {
      await seedPreviousOwner('uid-old');
      purgeResult = false;

      for (var launch = 0; launch < 3; launch++) {
        await expectLater(
          AppSession.instance.setIdentity(method: 'google', userId: 'uid-new'),
          throwsA(isA<LocalDataOwnershipException>()),
        );
      }

      expect(calls.contains('wipe'), isFalse,
          reason: 'a purge that never confirms must never cost the user data');
      expect(await owner(), 'uid-old', reason: 'no claim on a failed purge');
      expect(calls.where((c) => c == 'purge').length, 3,
          reason: 'it retries across launches, it does not give up silently');
    });
  });

  group('3. owner mismatch + purge succeeds first try', () {
    test('exact ordering: purge -> wipe -> claim', () async {
      await seedPreviousOwner('uid-old');

      await AppSession.instance
          .setIdentity(method: 'google', userId: 'uid-new');

      expect(calls, ['purge', 'wipe']);
      expect(await owner(), 'uid-new');
    });
  });

  group('4. second launch after a successful transition', () {
    test('owner matches: no purge, no wipe', () async {
      await seedPreviousOwner('uid-old');
      await AppSession.instance
          .setIdentity(method: 'google', userId: 'uid-new');
      expect(await owner(), 'uid-new');

      calls.clear();
      await AppSession.instance
          .setIdentity(method: 'google', userId: 'uid-new');

      expect(calls, isEmpty,
          reason: 'the loop this whole fix exists to break');
      expect(await owner(), 'uid-new');
    });
  });

  group('5. fresh install (no stored owner)', () {
    test('claims without wiping; clean-install path unchanged', () async {
      expect(await owner(), isNull);

      await AppSession.instance
          .setIdentity(method: 'google', userId: 'uid-first');

      expect(calls.contains('wipe'), isFalse,
          reason: 'a fresh install has no previous owner to displace');
      expect(await owner(), 'uid-first');
    });
  });

  group('6. same owner', () {
    test('zero destructive work', () async {
      await AppSession.instance
          .setIdentity(method: 'google', userId: 'uid-a');
      calls.clear();

      await AppSession.instance
          .setIdentity(method: 'google', userId: 'uid-a');

      expect(calls, isEmpty);
      expect(await owner(), 'uid-a');
    });
  });

  group('ordering is pinned in the source, not only in behaviour', () {
    test('the wipe cannot be moved back above the purge', () async {
      // Behavioural tests above would still pass if a refactor reintroduced the
      // old order behind a condition these fixtures happen not to hit. This
      // reads the transition itself.
      final src = File(
        '${Directory.current.path}/lib/core/session/app_session.dart',
      ).readAsStringSync();

      final fn = src.substring(
          src.indexOf('Future<LocalDataOwnership> _resolveLocalDataOwnership'));
      final body = fn.substring(0, fn.indexOf('\n  }'));

      final purgeAt = body.indexOf('_runResiduePurge()');
      // The pre-wipe proof: the transition sentinel written and read back.
      final sentinelAt = body.indexOf('_kOwnerTransitionPrefix');
      final wipeAt = body.indexOf('await wipe();');
      // LAST occurrence: the unowned branch claims earlier in the same
      // function, and that one is legitimately above the wipe.
      final claimAt = body.lastIndexOf('_writeOwnerMarkerVerified(uid)');

      expect(purgeAt, greaterThan(-1));
      expect(sentinelAt, greaterThan(-1));
      expect(wipeAt, greaterThan(-1));
      expect(claimAt, greaterThan(-1));

      expect(purgeAt, lessThan(sentinelAt),
          reason: 'PURGE MUST PRECEDE WIPE — reversing these is the exact bug '
              'that wiped every TestFlight user on every launch');
      expect(sentinelAt, lessThan(wipeAt),
          reason: 'the marker must be proven writable before anything is '
              'destroyed');
      expect(wipeAt, lessThan(claimAt),
          reason: 'the claim records a transition that already happened');
    });
  });
}
