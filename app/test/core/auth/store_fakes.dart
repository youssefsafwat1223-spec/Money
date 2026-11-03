import 'package:money_companion/core/auth/session_keychain.dart';
import 'package:money_companion/core/auth/session_store.dart';

/// In-memory Keychain and legacy-session fakes shared by the ASR store and
/// coordinator tests.
class FakeKeychain implements SessionKeychainApi {
  final Map<String, String> items = {};
  bool protectedData = true;
  KeychainStatus? readStatus;

  /// The next this many reads fail with an error status.
  int failNextReads = 0;
  bool failNextWrite = false;
  bool loseNextWriteReply = false;
  bool unknownNextWriteDropped = false;
  bool failDeletes = false;

  /// Called with every value that lands in the item.
  void Function(String value)? onWrite;

  @override
  Future<KeychainResult> read(String key) async {
    if (readStatus != null) return KeychainResult(readStatus!);
    if (failNextReads > 0) {
      failNextReads--;
      return const KeychainResult(KeychainStatus.error);
    }
    final v = items[key];
    return v == null
        ? const KeychainResult(KeychainStatus.absent)
        : KeychainResult(KeychainStatus.found, v);
  }

  @override
  Future<KeychainResult> write(String key, String value) async {
    if (failNextWrite) {
      failNextWrite = false;
      return const KeychainResult(KeychainStatus.error);
    }
    if (unknownNextWriteDropped) {
      unknownNextWriteDropped = false;
      return const KeychainResult(KeychainStatus.unknown);
    }
    items[key] = value;
    onWrite?.call(value);
    if (loseNextWriteReply) {
      loseNextWriteReply = false;
      return const KeychainResult(KeychainStatus.unknown);
    }
    return const KeychainResult(KeychainStatus.ok);
  }

  @override
  Future<KeychainResult> delete(String key) async {
    if (failDeletes) return const KeychainResult(KeychainStatus.error);
    items.remove(key);
    return const KeychainResult(KeychainStatus.ok);
  }

  @override
  Future<KeychainResult> readPluginItem(String key) => read('plugin:$key');

  @override
  Future<bool?> protectedDataAvailable() async => protectedData;

  @override
  Stream<void> get protectedDataBecameAvailable => const Stream.empty();
}

class FakeLegacy implements LegacySessionSource {
  String? value;
  int reads = 0;
  int blindRemoves = 0;

  @override
  Future<String?> readValue() async {
    reads++;
    return value;
  }

  @override
  Future<bool> removeVerified() async {
    blindRemoves++;
    value = null;
    return true;
  }
}
