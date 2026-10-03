import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/session/app_session.dart';

const String _kGen = 'local_data_owner_generation';

/// B15 — "erase all data" / account deletion must (1) invalidate the admission
/// generation BEFORE wiping, so an in-flight drain cannot write into the wiped
/// DB, then (2) wipe, then (3) sign out of the remote auth session.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  test('generation is invalidated before the wipe; remote sign-out runs last',
      () async {
    const store = FlutterSecureStorage();
    final session = AppSession.instance;
    session.configureLocalResiduePurge(() async => true);
    await session.setIdentity(method: 'google', email: 'a@x.com', userId: 'A');
    expect(await store.read(key: _kGen), isNotNull);

    final order = <String>[];
    var generationAtWipe = 'unset';
    await session.resetAllLocalData(
      wipeDatabase: () async {
        generationAtWipe = (await store.read(key: _kGen)) ?? 'absent';
        order.add('wipe');
      },
      signOutRemote: () async => order.add('signOut'),
    );

    expect(generationAtWipe, 'absent',
        reason: 'invalidated BEFORE the DB wipe began');
    expect(order, ['wipe', 'signOut']);
    expect(session.isGuest || session.authMethod == null, isTrue,
        reason: 'wipeAndReset ran');
    session.configureLocalResiduePurge(null);
  });

  test('a failing remote sign-out does not fail the (already complete) local reset',
      () async {
    final session = AppSession.instance;
    session.configureLocalResiduePurge(() async => true);
    var wiped = false;
    await session.resetAllLocalData(
      wipeDatabase: () async => wiped = true,
      signOutRemote: () async => throw StateError('offline'),
    );
    expect(wiped, isTrue);
    session.configureLocalResiduePurge(null);
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
    }
  });
}
