import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/session/admission_authority.dart';
import 'package:money_companion/core/session/app_session.dart';
import 'package:money_companion/core/session/remove_data_flow.dart';

import 'f2_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late F2Fixture f;
  final session = AppSession.instance;
  setUp(() async => f = await F2Fixture.create());
  tearDown(() async => f.dispose());

  Future<void> removedX() async {
    await f.signIn('uid-x');
    await session.removeDataFromDevice();
    expect(await f.flow.revokedUids(), contains('uid-x'));
  }

  for (final key in [
    'auth_email',
    'onboarding_current_account_v1',
    RemoveDataFlow.revokedKey
  ]) {
    test(
        'late fresh admission failure at $key clears identity and retains revocation',
        () async {
      await removedX();
      var armed = true;
      f.storage.gate = (op, candidate) async {
        if (armed && candidate == key && (op == 'write' || op == 'delete')) {
          armed = false;
          throw StateError('late commit failure');
        }
      };
      final statuses = <SessionStatus>[];
      void observe() => statuses.add(session.status);
      session.addListener(observe);
      await expectLater(
          session.setIdentity(
              method: 'google', email: 'x@example.com', userId: 'uid-x'),
          throwsA(anything));
      session.removeListener(observe);
      expect(statuses, isNot(contains(SessionStatus.authenticated)));
      f.storage.gate = null;
      expect(await f.flow.revokedUids(), contains('uid-x'));
      expect(await f.artifactsOf('uid-x'), isEmpty);
      expect(f.host.activeUid, isNull);
      expect(session.status, isNot(SessionStatus.authenticated));
      expect(session.authMethod, isNull);
      expect(session.email, isNull);
      expect(f.storage.data.containsKey('auth_method'), isFalse);
      expect(f.storage.data.containsKey('auth_email'), isFalse);
      expect(
          f.storage.data.containsKey('onboarding_current_account_v1'), isFalse);
    });
  }

  test(
      'removal drains a paused revocation commit and cannot lose its durable restriction',
      () async {
    await removedX();
    final hold = f.storage.holdOnce(
        (op, key) => op == 'delete' && key == RemoveDataFlow.revokedKey);
    Object? outcome;
    final fresh = session
        .setIdentity(method: 'google', email: 'x@example.com', userId: 'uid-x')
        .then<void>((_) {}, onError: (Object error) => outcome = error);
    await hold.reached.future;
    var removed = false;
    final removal = session.removeDataFromDevice().then((_) => removed = true);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(removed, isFalse,
        reason: 'final admission commit is part of the drain');
    hold.release.complete();
    await fresh;
    await removal;
    expect(outcome, isA<StaleAdmissionException>());
    expect(await f.flow.revokedUids(), contains('uid-x'));
    expect(await f.artifactsOf('uid-x'), isEmpty);
    expect(session.status, isNot(SessionStatus.authenticated));
  });

  test(
      'a stale rollback cannot delete the same UID newly admitted by a later attempt',
      () async {
    await removedX();
    final hold =
        f.storage.holdOnce((op, key) => op == 'write' && key == 'auth_method');
    Object? outcome;
    final stale = session
        .setIdentity(
            method: 'google', email: 'old@example.com', userId: 'uid-x')
        .then<void>((_) {}, onError: (Object error) => outcome = error);
    await hold.reached.future;
    final hash = await f.hash('uid-x');
    final key = f.storage.data['qirsh.db_key.$hash'];
    final from = f.storage.attempts.length;
    final newer = f.signIn('uid-x');
    hold.release.complete();
    await stale;
    await newer;
    expect(outcome, isA<StaleAdmissionException>());
    expect(await f.artifactsOf('uid-x'), ['dir', 'key', 'registry']);
    expect(f.storage.data['qirsh.db_key.$hash'], key);
    expect(
        f.storage.attempts
            .skip(from)
            .where((a) => a.startsWith('delete:qirsh.db_key.')),
        isEmpty);
    expect(f.host.activeUid, 'uid-x');
    expect(session.status, SessionStatus.authenticated);
    expect(session.email, 'uid-x@example.com');
  });

  test('a newer Y admission survives stale X identity-write failure', () async {
    await removedX();
    final hold = f.storage.holdOnce((op, key) => op == 'write' && key == 'auth_email');
    Object? outcome;
    final stale = session.setIdentity(method: 'google', email: 'old-x@example.com', userId: 'uid-x').then<void>((_) {}, onError: (Object error) => outcome = error);
    await hold.reached.future;
    final newer = f.signIn('uid-y');
    hold.release.complete();
    await stale;
    await newer;
    expect(outcome, isA<StaleAdmissionException>());
    expect(f.host.activeUid, 'uid-y');
    expect(session.status, SessionStatus.authenticated);
    expect(session.email, 'uid-y@example.com');
    expect(f.storage.data['auth_email'], 'uid-y@example.com');
    expect(await f.artifactsOf('uid-y'), ['dir', 'key', 'registry']);
    expect(await f.flow.revokedUids(), contains('uid-x'));
  });

  test('newer same-UID admission queued behind stale revocation commit survives', () async {
    await removedX();
    final hold = f.storage.holdOnce((op, key) => op == 'delete' && key == RemoveDataFlow.revokedKey);
    Object? outcome;
    final stale = session.setIdentity(method: 'google', email: 'old-x@example.com', userId: 'uid-x').then<void>((_) {}, onError: (Object error) => outcome = error);
    await hold.reached.future;
    final newer = f.signIn('uid-x');
    hold.release.complete();
    await stale;
    await newer;
    expect(outcome, isA<StaleAdmissionException>());
    expect(await f.artifactsOf('uid-x'), ['dir', 'key', 'registry']);
    expect(await f.flow.revokedUids(), isEmpty);
    expect(f.host.activeUid, 'uid-x');
    expect(session.email, 'uid-x@example.com');
  });

  test('authenticated Y cannot authorize shell work while fresh removed X awaits final commit', () async {
    await removedX();
    await f.signIn('uid-y');
    final clientY = await f.clientFor('uid-y');
    final hold = f.storage.holdOnce((op, key) => op == 'delete' && key == RemoveDataFlow.revokedKey);
    final fresh = session.setIdentity(method: 'google', email: 'uid-x@example.com', userId: 'uid-x');
    final statusAtAcceptance = session.status;
    await hold.reached.future;
    try {
      expect(f.host.activeUid, 'uid-x', reason: 'X scope is already published');
      expect(statusAtAcceptance, SessionStatus.needsOnboarding, reason: 'before first yield');
      expect(session.status, isNot(SessionStatus.authenticated));
      expect(await session.revalidateForShell(clientY), isFalse);
      expect(await f.flow.revokedUids(), contains('uid-x'));
    } finally {
      hold.release.complete();
      await fresh;
    }
    expect(session.status, SessionStatus.authenticated);
    expect(f.host.activeUid, 'uid-x');
    expect(await f.flow.revokedUids(), isEmpty);
  });

  test('durable removal record precedes generation invalidation and admission drain', () async {
    await f.signIn('uid-x');
    final hold = f.storage.holdOnce((op, key) => op == 'delete' && key == kGenerationKey);
    final removal = session.removeDataFromDevice();
    await hold.reached.future;
    expect(f.storage.data[RemoveDataFlow.barrierKey], contains('"uid":"uid-x"'));
    expect(f.storage.data[RemoveDataFlow.barrierKey], contains('"revoke":true'));
    expect(f.order, isNot(contains('begin:uid-x')));
    hold.release.complete();
    await removal;
    expect(await f.flow.revokedUids(), contains('uid-x'));
  });

  test('server purge fences admission paused at revoked-list read and permits maintenance readmit after completion', () async {
    await f.signIn('uid-x');
    final client = await f.clientFor('uid-x');
    final authority = await session.maintenanceAuthority('uid-x');
    final hold = f.storage.holdOnce((op, key) => op == 'read' && key == RemoveDataFlow.revokedKey);
    final retained = session.revalidateSupabaseSessionOnResume(client);
    await hold.reached.future;
    final nativeReached = Completer<void>();
    final nativeRelease = Completer<void>();
    f.barrier.onCall = (call) async {
      if (call == 'begin:uid-x') {
        nativeReached.complete();
        await nativeRelease.future;
      }
    };
    final purge = f.flow.remove('uid-x', revokeAdmission: false);
    await nativeReached.future;
    expect(authority.isCurrent, isFalse);
    final from = f.storage.attempts.length;
    final activations = f.scope.calls.where((c) => c.startsWith('activate')).length;
    hold.release.complete();
    await retained;
    expect(f.scope.calls.where((c) => c.startsWith('activate')).length, activations);
    expect(f.storage.attempts.skip(from).where((a) => a.startsWith('write:')), isEmpty);
    nativeRelease.complete();
    await purge;
    expect(f.flow.isRunning, isFalse);
    expect(authority.isCurrent, isTrue);
    await session.revalidateSupabaseSessionOnResume(client, authority: authority);
    expect(f.host.activeUid, 'uid-x');
    expect(await f.flow.revokedUids(), isEmpty);
  });

  for (final pauseOn in ['write', 'delete']) {
    test(
        'duplicate owner-marker repair rechecks authority after paused $pauseOn',
        () async {
      await f.signIn('uid-x');
      final reached = Completer<void>();
      final release = Completer<void>();
      var firstWrite = true;
      f.storage.gate = (op, key) async {
        if (key != kMarkerKey) return;
        if (op == 'write' && firstWrite) {
          firstWrite = false;
          if (pauseOn == 'write') {
            reached.complete();
            await release.future;
          }
          throw PlatformException(code: '-25299');
        }
        if (op == 'delete' && pauseOn == 'delete' && !reached.isCompleted) {
          reached.complete();
          await release.future;
        }
      };
      Object? outcome;
      final stale = session
          .setIdentity(
              method: 'google', email: 'y@example.com', userId: 'uid-y')
          .then<void>((_) {}, onError: (Object error) => outcome = error);
      await reached.future;
      final removal = session.removeDataFromDevice();
      final from = f.storage.attempts.length;
      release.complete();
      await stale;
      await removal;
      f.storage.gate = null;
      expect(outcome, isA<StaleAdmissionException>());
      expect(
          f.storage.attempts
              .skip(from)
              .where((a) => a.startsWith('write:$kMarkerKey=')),
          isEmpty,
          reason: 'no newly dispatched marker retry after revocation');
      expect(await f.artifactsOf('uid-x'), isEmpty);
      expect(await f.artifactsOf('uid-y'), isEmpty);
    });
  }
}
