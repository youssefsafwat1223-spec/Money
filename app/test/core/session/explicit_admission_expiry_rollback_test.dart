import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/session/admission_authority.dart';
import 'package:money_companion/core/session/app_session.dart';
import 'package:money_companion/core/session/remove_data_flow.dart';

import 'f2_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late F2Fixture f;
  setUp(() async => f = await F2Fixture.create());
  tearDown(() async => f.dispose());

  for (final boundary in [
    'marker write',
    'marker readback',
    'generation read',
    'identity write',
    'revocation clear',
  ]) {
    test('expiry during $boundary rolls back removed UID admission', () async {
      await f.signIn('uid-x');
      await f.session.removeDataFromDevice();
      expect(await f.flow.revokedUids(), contains('uid-x'));
      var fresh = true;
      final from = f.storage.attempts.length;
      final scopeFrom = f.scope.calls.length;
      final hold = f.storage.holdOnce((op, key) {
        switch (boundary) {
          case 'marker write':
            return op == 'write' && key == kMarkerKey;
          case 'marker readback':
            return op == 'read' &&
                key == kMarkerKey &&
                f.storage.attempts
                    .skip(from)
                    .contains('write:$kMarkerKey=uid-x');
          case 'generation read':
            return op == 'read' && key == kGenerationKey;
          case 'identity write':
            return op == 'write' && key == 'auth_method';
          case 'revocation clear':
            return op == 'delete' && key == RemoveDataFlow.revokedKey;
        }
        return false;
      });
      final pending = f.session.setIdentity(
          method: 'google', userId: 'uid-x', sessionCurrent: () => fresh);
      final rejected =
          expectLater(pending, throwsA(isA<StaleAdmissionException>()));
      await hold.reached.future;
      expect(
          f.storage.attempts.skip(from), contains('write:$kMarkerKey=uid-x'));
      if (boundary == 'identity write' || boundary == 'revocation clear') {
        expect(f.scope.calls.skip(scopeFrom), contains('activate:uid-x'));
        expect(await f.artifactsOf('uid-x'),
            containsAll(['dir', 'key', 'registry']));
      } else {
        expect(f.scope.calls.skip(scopeFrom), isEmpty);
        expect(await f.artifactsOf('uid-x'), isEmpty);
      }
      final expiredFrom = f.storage.attempts.length;
      fresh = false;
      hold.release.complete();
      await rejected;

      // Already-dispatched writes may land; no further creation is authorized.
      final afterExpiry = f.storage.attempts.skip(expiredFrom).toList();
      expect(
          afterExpiry.where((a) =>
              a.startsWith('write:$kMarkerKey=') ||
              a.startsWith('write:$kGenerationKey=') ||
              a.startsWith('write:qirsh.db_key.')),
          isEmpty);
      expect(afterExpiry, contains('delete:$kMarkerKey'));
      expect(await f.session.readLocalDataOwnerUid(), isNull);
      expect(f.storage.data[kGenerationKey], isNull);
      expect(await f.artifactsOf('uid-x'), isEmpty);
      expect(f.scope.activeUid, isNull);
      expect(await f.flow.revokedUids(), contains('uid-x'));
      expect(f.session.status, isNot(SessionStatus.authenticated));
    });
  }

  test('expired rollback cannot erase newer explicit same UID admission',
      () async {
    await f.signIn('uid-x');
    await f.session.removeDataFromDevice();
    var oldFresh = true;
    final hold =
        f.storage.holdOnce((op, key) => op == 'write' && key == 'auth_method');
    final oldAdmission = f.session.setIdentity(
        method: 'google', userId: 'uid-x', sessionCurrent: () => oldFresh);
    final oldRejected =
        expectLater(oldAdmission, throwsA(isA<StaleAdmissionException>()));
    await hold.reached.future;
    final from = f.storage.attempts.length;
    oldFresh = false;
    final newerAdmission = f.session.setIdentity(
        method: 'google', userId: 'uid-x', sessionCurrent: () => true);
    hold.release.complete();
    await oldRejected;
    await newerAdmission;
    expect(
        f.storage.attempts.skip(from).where((a) =>
            a == 'delete:$kMarkerKey' || a.startsWith('delete:qirsh.db_key.')),
        isEmpty);
    expect(await f.session.readLocalDataOwnerUid(), 'uid-x');
    expect(
        await f.artifactsOf('uid-x'), containsAll(['dir', 'key', 'registry']));
    expect(f.scope.activeUid, 'uid-x');
    expect(await f.flow.revokedUids(), isNot(contains('uid-x')));
  });
}
