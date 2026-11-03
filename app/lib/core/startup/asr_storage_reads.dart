import '../auth/session_keychain.dart';
import '../privacy/cloud_egress_gate.dart';
import '../session/account_fence_store.dart';

/// ASR v7.2 §12: the status-preserving accessor behind every eligibility
/// predicate whose absence passes (E3, E5, E6, E10, E11).
///
/// The plugin's own `read` retries a failed non-synchronizable lookup as a
/// synchronizable one, which then reports not-found: a temporary Keychain error
/// reads as absent. These reads use one native lookup that keeps the OS status
/// (`SessionKeychain.readPluginItem`), so only a confirmed not-found is absence.
class AsrStrictReads {
  AsrStrictReads(this._keychain);
  final SessionKeychainApi _keychain;

  /// The item's value; null only when the OS confirmed it does not exist.
  /// Anything else throws (the caller denies).
  Future<String?> read(String key) async {
    final r = await _keychain.readPluginItem(key);
    if (r.isAbsent) return null;
    final value = r.value;
    if (r.isFound && value != null) return value;
    throw AsrStorageUnavailable(r.status);
  }

  /// [read] as a read-only [DurableSlot] (status kept as `unreadable`).
  DurableSlot slot(String key) => _StrictSlot(this, key);

  /// A fresh, unshared fence store whose single load uses [read].
  AccountFenceStore fenceStore() =>
      AccountFenceStore(persistence: _StrictFencePersistence(this));
}

class AsrStorageUnavailable implements Exception {
  const AsrStorageUnavailable(this.status);
  final KeychainStatus status;
  @override
  String toString() => 'AsrStorageUnavailable($status)';
}

class _StrictSlot implements DurableSlot {
  _StrictSlot(this._reads, this._key);
  final AsrStrictReads _reads;
  final String _key;

  @override
  Future<SlotRead> read() async {
    try {
      final v = await _reads.read(_key);
      return v == null
          ? const SlotRead(SlotStatus.absent)
          : SlotRead(SlotStatus.value, v);
    } catch (_) {
      return const SlotRead(SlotStatus.unreadable);
    }
  }

  @override
  Future<void> write(String value) => throw UnsupportedError('read-only');

  @override
  Future<void> delete() => throw UnsupportedError('read-only');
}

class _StrictFencePersistence implements AccountFencePersistence {
  _StrictFencePersistence(this._reads);
  final AsrStrictReads _reads;

  @override
  Future<String?> read() => _reads.read(AccountFenceStore.storageKey);

  @override
  Future<void> write(String value) => throw UnsupportedError('read-only');
}
