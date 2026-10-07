import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/session/app_session.dart';
import 'fake_account_scope.dart';

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
    AppSession.instance.configureAccountScope(FakeAccountScope(calls));
    AppSession.instance.configureCaptureOwnerClear(() async {
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
    AppSession.instance.configureCaptureOwnerClear(null);
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
          reason: 'the purge was attempted and NOTHING was changed');
      expect(calls.contains('activate:uid-new'), isFalse,
          reason: 'the new replica is not opened on an unconfirmed purge');
      expect(await owner(), 'uid-old',
          reason: 'the marker is untouched, so the retry still sees the '
              'conflict rather than a half-finished transition');

      // Launch 2 — the channel is up, the purge succeeds.
      calls.clear();
      await AppSession.instance
          .setIdentity(method: 'google', userId: 'uid-new');

      expect(calls, ['purge', 'activate:uid-new'],
          reason: 'purge BEFORE the new replica is opened');
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

      expect(calls.contains('activate:uid-new'), isFalse,
          reason: 'a purge that never confirms never admits the new uid');
      expect(await owner(), 'uid-old', reason: 'no claim on a failed purge');
      expect(calls.where((c) => c == 'purge').length, 3,
          reason: 'it retries across launches, it does not give up silently');
    });
  });

  group('3. owner mismatch + purge succeeds first try', () {
    test('exact ordering: purge -> claim -> open the new replica', () async {
      await seedPreviousOwner('uid-old');

      await AppSession.instance
          .setIdentity(method: 'google', userId: 'uid-new');

      expect(calls, ['purge', 'activate:uid-new']);
      expect(await owner(), 'uid-new');
    });
  });

  group('4. second launch after a successful transition', () {
    test('owner matches: no purge', () async {
      await seedPreviousOwner('uid-old');
      await AppSession.instance
          .setIdentity(method: 'google', userId: 'uid-new');
      expect(await owner(), 'uid-new');

      calls.clear();
      await AppSession.instance
          .setIdentity(method: 'google', userId: 'uid-new');

      expect(calls, ['activate:uid-new'],
          reason: 'no purge and no switch: the loop this whole fix exists to break');
      expect(await owner(), 'uid-new');
    });
  });

  group('5. fresh install (no stored owner)', () {
    test('claims without wiping; clean-install path unchanged', () async {
      expect(await owner(), isNull);

      await AppSession.instance
          .setIdentity(method: 'google', userId: 'uid-first');

      expect(calls.contains('activate:uid-first'), isTrue);
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

      expect(calls, ['activate:uid-a']);
      expect(await owner(), 'uid-a');
    });
  });

  group('ordering is pinned in the source, not only in behaviour', () {
    test('the claim cannot move above the purge, and nothing is wiped', () async {
      final src = File(
        '${Directory.current.path}/lib/core/session/app_session.dart',
      ).readAsStringSync();

      final fn = src.substring(
          src.indexOf('Future<LocalDataOwnership> _resolveLocalDataOwnership'));
      final body = fn.substring(0, fn.indexOf('\n  }'));

      // The CHANGED-OWNER branch is the last one in the function.
      final purgeAt = body.lastIndexOf('_runOwnerClear()');
      final claimAt = body.lastIndexOf('_writeOwnerMarkerVerified(uid)');
      final admitAt = body.lastIndexOf('_admitReplica(uid)');

      expect(purgeAt, greaterThan(-1));
      expect(purgeAt, lessThan(claimAt),
          reason: 'the residue release must be confirmed before ownership moves');
      expect(claimAt, lessThan(admitAt),
          reason: 'the new replica opens only after the claim is read back');
      expect(body.contains('wipe'), isFalse,
          reason: 'WP-3b: there is no wipe-and-reclaim any more');
    });
  });
}
