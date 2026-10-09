import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/session/app_session.dart';
import 'package:money_companion/core/session/remove_data_flow.dart';

import '../session/f2_fixture.dart';

// F2 round 2 (R2-6) — the recovery result is not advisory: a BLOCKED launch is
// distinguishable from an ordinary signed-out launch, and while it is blocked
// the session is held signed out.

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late F2Fixture f;
  final session = AppSession.instance;

  setUp(() async => f = await F2Fixture.create());
  tearDown(() async => f.dispose());

  group('R2-6 prepareLaunchAdmission distinguishes blocked from signed out', () {
    test('R2-6 no marker: an ordinary signed-out launch (not blocked)',
        () async {
      await session.load();
      final r = await session.prepareLaunchAdmission();
      expect(r.blocked, isFalse);
      expect(r.uid, isNull);
    });

    test('R2-6 a valid marker: open that existing replica', () async {
      await f.signIn('uid-y');
      await f.restart();
      final r = await session.prepareLaunchAdmission();
      expect(r.blocked, isFalse);
      expect(r.uid, 'uid-y');
    });

    test('R2-6 a stale marker naming a removed uid: signed out, marker cleared',
        () async {
      await f.signIn('uid-x');
      await session.removeDataFromDevice();
      f.storage.data[kMarkerKey] = 'uid-x';
      await f.restart();
      final r = await session.prepareLaunchAdmission();
      expect(r.blocked, isFalse);
      expect(r.uid, isNull);
      expect(f.storage.data.containsKey(kMarkerKey), isFalse);
    });

    test('revoked marker that cannot be cleared keeps legacy recovery blocked',
        () async {
      await f.signIn('uid-x');
      await session.removeDataFromDevice();
      await f.restart();
      f.storage.data[kMarkerKey] = 'uid-x';
      f.storage.gate = (op, key) async {
        // A mismatched keychain item survives reported deletion.
        if (op == 'read' && key == kMarkerKey) {
          f.storage.data[kMarkerKey] = 'uid-x';
        }
      };
      final launch = await session.prepareLaunchAdmission();
      f.storage.gate = null;
      expect(launch.blocked, isTrue);
      expect(launch.uid, isNull);
      expect(session.status, isNot(SessionStatus.authenticated));
      expect(await session.readLocalDataOwnerUid(), 'uid-x');
    });

    test(
        'R2-6 a removal that cannot be completed: BLOCKED, and the session is '
        'held signed out', () async {
      await f.signIn('uid-x');
      // The process died inside the removal: the flow ran, the session's own
      // sign-out never did, so the persisted identity is intact.
      f.crashAfterStep = 'afterBarrierRecord';
      await expectLater(f.flow.remove('uid-x'),
          throwsA(isA<RemoveDataIncompleteException>()));
      f.crashAfterStep = null;
      f.barrier.failFinish = true;
      await f.restart();
      expect(session.status, SessionStatus.authenticated,
          reason: 'precondition: persisted identity would route authenticated');

      final r = await session.prepareLaunchAdmission();

      expect(r.blocked, isTrue);
      expect(r.uid, isNull);
      expect(session.status, isNot(SessionStatus.authenticated));
      expect(session.authMethod, isNull);
    });

    test('R2-6 an unreadable Dart record: BLOCKED', () async {
      await f.signIn('uid-y');
      f.storage.data[RemoveDataFlow.barrierKey] = '{broken';
      await f.restart();
      expect((await session.prepareLaunchAdmission()).blocked, isTrue);
      expect(session.status, isNot(SessionStatus.authenticated));
    });

    test('R2-6 a native barrier of unknown uid: BLOCKED', () async {
      await f.signIn('uid-y');
      f.barrier.unknownBarrier = true;
      await f.restart();
      final r = await session.prepareLaunchAdmission();
      expect(r.blocked, isTrue);
      expect(f.barrier.unknownBarrier, isTrue, reason: 'left in place');
    });

    test('R2-6 an unreadable revoked-uid record: BLOCKED', () async {
      await f.signIn('uid-y');
      f.storage.data[RemoveDataFlow.revokedKey] = '{broken';
      await f.restart();
      expect((await session.prepareLaunchAdmission()).blocked, isTrue);
    });

    test('R2-6 an owner-marker read failure: BLOCKED (not "no owner")',
        () async {
      await f.signIn('uid-y');
      await f.restart();
      f.storage.gate = (op, key) async {
        if (op == 'read' && key == kMarkerKey) throw StateError('keychain');
      };
      final r = await session.prepareLaunchAdmission();
      f.storage.gate = null;
      expect(r.blocked, isTrue);
    });
  });
}
