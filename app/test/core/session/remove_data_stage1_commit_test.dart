import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/session/admission_authority.dart';
import 'package:money_companion/core/session/app_session.dart';
import 'package:money_companion/core/session/remove_data_flow.dart';

import 'f2_fixture.dart';
import 'recording_secure_storage.dart';

class _SnapshotStorage extends RecordingSecureStorage {
  _SnapshotStorage(Map<String, String> initial) : super(initial);
  final ownerRead = Hold();
  @override
  Future<String?> read(
      {required String key, required Map<String, String> options}) async {
    if (key == kMarkerKey && !ownerRead.used) {
      ownerRead.used = true;
      final captured = data[key];
      ownerRead.reached.complete();
      await ownerRead.release.future;
      return captured;
    }
    return super.read(key: key, options: options);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final session = AppSession.instance;
  late F2Fixture f;
  final publications = <String>[];
  setUp(() async {
    session.configureCaptureOwnerPublish(null);
    f = await F2Fixture.create();
    publications.clear();
  });
  tearDown(() async {
    session.configureCaptureOwnerPublish(null);
    await f.dispose();
  });

  Future<void> removedX() async {
    await f.signIn('uid-x');
    await session.removeDataFromDevice();
    session.configureCaptureOwnerPublish((uid) async => publications.add(uid));
  }

  test(
      'old onboarding callback cannot write or authenticate during held explicit commit',
      () async {
    await removedX();
    final hold = f.storage.holdOnce(
        (op, key) => op == 'delete' && key == RemoveDataFlow.revokedKey);
    final fresh = session.setIdentity(
        method: 'google', email: 'uid-x@example.com', userId: 'uid-x');
    await hold.reached.future;
    final from = f.storage.attempts.length;
    final states = <SessionStatus>[];
    void observe() => states.add(session.status);
    session.addListener(observe);
    try {
      await session.finishOnboarding();
      expect(f.storage.attempts.skip(from), isEmpty);
      expect(states, isNot(contains(SessionStatus.authenticated)));
      expect(session.status, isNot(SessionStatus.authenticated));
    } finally {
      session.removeListener(observe);
      hold.release.complete();
      await fresh;
    }
    await session.finishOnboarding();
    expect(session.status, SessionStatus.authenticated);
  });

  test(
      'explicit capture owner is absent while held and published exactly once after complete commit',
      () async {
    await removedX();
    final hold = f.storage.holdOnce(
        (op, key) => op == 'delete' && key == RemoveDataFlow.revokedKey);
    final fresh = session.setIdentity(
        method: 'google', email: 'uid-x@example.com', userId: 'uid-x');
    await hold.reached.future;
    try {
      expect(publications, isEmpty);
    } finally {
      hold.release.complete();
      await fresh;
    }
    expect(publications, ['uid-x']);
  });

  test('failed explicit final commit never publishes capture owner', () async {
    await removedX();
    f.storage.gate = (op, key) async {
      if (op == 'delete' && key == RemoveDataFlow.revokedKey) {
        throw StateError('commit');
      }
    };
    await expectLater(
        session.setIdentity(
            method: 'google', email: 'uid-x@example.com', userId: 'uid-x'),
        throwsA(anything));
    f.storage.gate = null;
    expect(publications, isEmpty);
    expect(await f.flow.revokedUids(), contains('uid-x'));
  });

  test(
      'synchronous removal listener at final publication revokes capture hook authority',
      () async {
    await removedX();
    Future<void>? removal;
    void removeOnPublication() {
      if (session.status == SessionStatus.authenticated && removal == null) {
        // The async method revokes before returning its future.
        removal = session.removeDataFromDevice();
      }
    }

    session.addListener(removeOnPublication);
    try {
      await session.setIdentity(
          method: 'google', email: 'uid-x@example.com', userId: 'uid-x');
      expect(removal, isNotNull);
      await removal;
      expect(publications, isEmpty);
    } finally {
      session.removeListener(removeOnPublication);
    }
  });

  test(
      'superseded explicit attempt publishes no capture owner, newer Y commits once',
      () async {
    await removedX();
    final hold = f.storage.holdOnce(
        (op, key) => op == 'delete' && key == RemoveDataFlow.revokedKey);
    Object? outcome;
    final stale = session
        .setIdentity(
            method: 'google', email: 'old@example.com', userId: 'uid-x')
        .then<void>((_) {}, onError: (Object error) => outcome = error);
    await hold.reached.future;
    final newer = f.signIn('uid-y');
    hold.release.complete();
    await stale;
    await newer;
    expect(outcome, isA<StaleAdmissionException>());
    expect(publications, ['uid-y']);
  });

  test(
      'consent owner read retained across removal cannot dispatch a late consent write',
      () async {
    await f.signIn('uid-x');
    final snapshot = _SnapshotStorage(Map.of(f.storage.data));
    f.storage = snapshot.install();
    final retained = session.markConsentPromptSeen();
    await snapshot.ownerRead.reached.future;
    var removed = false;
    final removal = session.removeDataFromDevice().then((_) => removed = true);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    final from = snapshot.attempts.length;
    final drainedEarly = removed;
    snapshot.ownerRead.release.complete();
    await retained;
    await removal;
    expect(removed, isTrue);
    expect(drainedEarly, isFalse,
        reason: 'the retained consent operation is drained');
    expect(
        snapshot.attempts
            .skip(from)
            .where((a) => a.startsWith('write:$kConsentAskedKeyPrefix')),
        isEmpty);
    expect(
        snapshot.data.containsKey('${kConsentAskedKeyPrefix}uid-x'), isFalse);
  });

  test(
      'reconcile publication listener accepting removal dispatches no later identity write',
      () async {
    await f.signIn('uid-x');
    final client = await f.clientFor('uid-x');
    session.markSessionInvalid();
    Future<void>? removal;
    int? from;
    void removeOnPublication() {
      if (session.status == SessionStatus.authenticated && removal == null) {
        from = f.storage.attempts.length;
        removal = session.removeDataFromDevice();
      }
    }

    session.addListener(removeOnPublication);
    try {
      await session.revalidateSupabaseSessionOnResume(client);
      expect(removal, isNotNull);
      await removal;
      expect(
          f.storage.attempts.skip(from!).where((a) =>
              a == 'write:auth_email=uid-x@example.com' ||
              a.startsWith('write:onboarding_current_account_v1=')),
          isEmpty);
      expect(session.status, isNot(SessionStatus.authenticated));
    } finally {
      session.removeListener(removeOnPublication);
    }
  });

  test(
      'capture publication stays best effort and does not block explicit commit',
      () async {
    await removedX();
    final pendingHook = Completer<void>();
    session.configureCaptureOwnerPublish((uid) {
      publications.add(uid);
      return pendingHook.future;
    });
    try {
      await session
          .setIdentity(
              method: 'google', email: 'uid-x@example.com', userId: 'uid-x')
          .timeout(const Duration(seconds: 3));
      expect(publications, ['uid-x']);
      expect(session.status, SessionStatus.authenticated);
    } finally {
      pendingHook.complete();
    }
  });
}
