import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// The keychain options every `FlutterSecureStorage` in this app uses.
///
/// ## Why this exists
///
/// Every construction site used `FlutterSecureStorage()` with platform
/// defaults. On iOS that means `kSecAttrAccessibleWhenUnlocked` **without**
/// `ThisDeviceOnly`, so the items are eligible for iCloud Keychain and for
/// device-to-device transfer. The items in question are the SQLCipher database
/// key, the capture relay device secret, the install id and the app-lock state
/// — the key to someone's entire financial history among them. None of that
/// should exist anywhere but the handset that created it.
///
/// `first_unlock_this_device` maps to `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`:
/// readable by background work after the first unlock following a boot, and
/// never copied off the device. `afterFirstUnlock` rather than `whenUnlocked`
/// because the capture pipeline and scheduled notifications legitimately run
/// while the phone is locked; `whenUnlocked` would break them.
///
/// ## Why this was safe to change
///
/// Hardening accessibility on a shipped app risks stranding an upgrading user's
/// database key, which would be far worse than the exposure it fixes. iOS does
/// not treat `kSecAttrAccessible` as part of a keychain item's primary key, so
/// a read does not filter on it — but that is exactly the sort of claim that
/// belongs in a test. `integration_test/keychain_accessibility_test.dart` runs
/// against a real simulator keychain and proves both directions: a value
/// written with the OLD options reads back under the new ones (upgrade), and a
/// value written with the new options reads back under the old (rollback).
///
/// Android's `EncryptedSharedPreferences` is already device-bound and has no
/// equivalent knob, so [androidOptions] simply states the default rather than
/// implying a choice was available.
abstract final class SecureStorageOptions {
  static const IOSOptions ios = IOSOptions(
    accessibility: KeychainAccessibility.first_unlock_this_device,
  );

  static const AndroidOptions android = AndroidOptions(
    encryptedSharedPreferences: true,
  );

  /// The single storage instance shape. Prefer this over constructing
  /// `FlutterSecureStorage()` directly — an unadorned constructor is how the
  /// defaults got in everywhere in the first place.
  static const FlutterSecureStorage storage = FlutterSecureStorage(
    iOptions: ios,
    aOptions: android,
  );
}
