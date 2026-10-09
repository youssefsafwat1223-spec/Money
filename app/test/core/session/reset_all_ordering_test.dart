import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/session/app_session.dart';
import 'package:money_companion/core/session/remove_data_flow.dart';
import 'package:money_companion/data/db/replica_store.dart';
import 'fake_account_scope.dart';
import 'fake_remove_barrier.dart';

const String _kGen = 'local_data_owner_generation';

/// B15 — "erase all data" / account deletion must (1) invalidate the admission
/// generation BEFORE removing, so an in-flight drain cannot write into the DB
/// being deleted, then (2) run the §4.4 Remove-data flow (WP-3b), then (3) sign
/// out of the remote auth session.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory support;
  late List<String> order;
  late FakeRemoveBarrier barrier;

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    support = Directory.systemTemp.createTempSync('reset_all_');
    order = [];
    barrier = FakeRemoveBarrier(order);
    final scope = FakeAccountScope(order);
    AppSession.instance.configureAccountScope(scope);
    AppSession.instance.configureRemoveData(RemoveDataFlow(
      store: ReplicaStore(appSupportDirectory: support.path),
      scope: scope,
      barrier: barrier,
      clearOwnerMarker: AppSession.instance.clearLocalDataOwnerMarker,
      invalidateAdmissionGeneration: (uid) async {
        await AppSession.instance.invalidateRemovalGeneration(uid);
        order.add('generation');
      },
      quiesce: AppSession.instance.drainAdmissions,
      debugAfterStep: (step) async {
        if (step == 'afterBarrierRecord') order.add('record');
      },
    ));
  });

  tearDown(() {
    AppSession.instance.configureCaptureOwnerClear(null);
    AppSession.instance.configureAccountScope(null);
    AppSession.instance.configureRemoveData(null);
    support.deleteSync(recursive: true);
  });

  test(
      'generation is invalidated before the removal; remote sign-out runs last',
      () async {
    const store = FlutterSecureStorage();
    final session = AppSession.instance;
    session.configureCaptureOwnerClear(() async => true);
    await session.setIdentity(method: 'google', email: 'a@x.com', userId: 'A');
    expect(await store.read(key: _kGen), isNotNull);

    order.clear();
    var generationAtBegin = 'unset';
    barrier.onCall = (c) async {
      if (c.startsWith('begin')) {
        generationAtBegin = (await store.read(key: _kGen)) ?? 'absent';
      }
    };
    await session.resetAllLocalData(
      signOutRemote: () async => order.add('signOut'),
    );

    expect(generationAtBegin, 'absent',
        reason: 'invalidated BEFORE the removal began');
    expect(order,
        ['record', 'generation', 'begin:A', 'detach', 'finish:A', 'signOut']);
    expect(session.isGuest || session.authMethod == null, isTrue,
        reason: 'wipeAndReset ran');
  });

  test(
      'a failing remote sign-out does not fail the (already complete) local reset',
      () async {
    final session = AppSession.instance;
    session.configureCaptureOwnerClear(() async => true);
    await session.setIdentity(method: 'google', email: 'a@x.com', userId: 'A');
    order.clear();
    await session.resetAllLocalData(
      signOutRemote: () async => throw StateError('offline'),
    );
    expect(order, contains('finish:A'));
  });

  test('both destructive UI flows go through resetAllLocalData', () {
    for (final path in const [
      'lib/features/settings/settings_screen.dart',
      'lib/features/settings/privacy_screen.dart',
    ]) {
      final src = File('${Directory.current.path}/$path').readAsStringSync();
      expect(src, contains('resetAllLocalData('), reason: path);
      expect(src.contains('wipeAndReset()'), isFalse,
          reason: '$path must not hand-roll wipe -> reset without the fence');
      expect(src.contains('.wipeAll()'), isFalse, reason: path);
      expect(src.contains('wipeDatabase'), isFalse, reason: path);
    }
  });
}
