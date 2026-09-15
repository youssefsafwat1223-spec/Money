import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// KEYCHAIN ACCESSIBILITY — can hardened options still read what the old
/// options wrote?
///
/// Every `FlutterSecureStorage()` in this app is constructed with platform
/// defaults, which on iOS means the item is eligible for iCloud Keychain and
/// for device-to-device migration. For a SQLCipher database key and a capture
/// relay secret that is the wrong default: those should never leave the handset.
/// `ThisDeviceOnly` accessibility fixes it.
///
/// It also risks everything. If items written by the shipped build become
/// unreadable under the new options, an upgrading user loses the key to their
/// own encrypted database — which is worse than the exposure being fixed. iOS
/// does not treat `kSecAttrAccessible` as part of a keychain item's primary
/// key, so a read should not filter on it, but "should" is exactly the kind of
/// claim that belongs in a test rather than a comment.
///
/// This runs on a real simulator keychain, writes with the OLD options, reads
/// with the NEW ones, and then does it the other way round.
const _hardened = IOSOptions(
  accessibility: KeychainAccessibility.first_unlock_this_device,
);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const legacy = FlutterSecureStorage();
  const hardened = FlutterSecureStorage(iOptions: _hardened);
  const key = 'qirsh_keychain_accessibility_probe';

  tearDown(() async {
    await legacy.delete(key: key);
    await hardened.delete(key: key);
  });

  testWidgets('a value written with the DEFAULT options is readable with the '
      'hardened ones — the upgrade path', (tester) async {
    await legacy.delete(key: key);
    await legacy.write(key: key, value: 'written-by-the-old-build');

    final read = await hardened.read(key: key);
    expect(read, 'written-by-the-old-build',
        reason: 'an upgrading user would lose their database key. Do NOT '
            'harden accessibility until this passes');
  });

  testWidgets('a value written with the hardened options is readable with the '
      'defaults — the downgrade path', (tester) async {
    await hardened.delete(key: key);
    await hardened.write(key: key, value: 'written-by-the-new-build');

    final read = await legacy.read(key: key);
    expect(read, 'written-by-the-new-build',
        reason: 'a rollback to the previous build must not strand the key '
            'either');
  });

  testWidgets('hardened writes survive a rewrite through the hardened path',
      (tester) async {
    await hardened.write(key: key, value: 'first');
    await hardened.write(key: key, value: 'second');
    expect(await hardened.read(key: key), 'second');
  });
}
