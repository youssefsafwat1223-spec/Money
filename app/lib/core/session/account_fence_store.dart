import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../security/secure_storage_options.dart';

/// Only this dedicated persistence boundary is replaceable in tests. It has no
/// enumeration, deletion, release or expiry operation.
abstract interface class AccountFencePersistence {
  Future<String?> read();
  Future<void> write(String value);
}

class _SecureAccountFencePersistence implements AccountFencePersistence {
  const _SecureAccountFencePersistence();

  @override
  Future<String?> read() => SecureStorageOptions.storage.read(
      key: AccountFenceStore.storageKey);

  @override
  Future<void> write(String value) => SecureStorageOptions.storage.write(
      key: AccountFenceStore.storageKey, value: value);
}

enum AccountFenceState { pending, gone }

/// Denial provenance only. Generations and replica identity never release a hold.
class AccountFenceRecord {
  AccountFenceRecord({
    required this.state,
    required this.operationId,
    required this.ownerGeneration,
    required this.replicaDigest,
    required this.scopeGeneration,
  }) {
    if (!_uuid.hasMatch(operationId) || ownerGeneration.isEmpty ||
        !_digest.hasMatch(replicaDigest) || scopeGeneration < 0) {
      throw ArgumentError('invalid_account_fence_record');
    }
  }

  final AccountFenceState state;
  final String operationId;
  final String ownerGeneration;
  final String replicaDigest;
  final int scopeGeneration;

  static final _digest = RegExp(r'^[0-9a-f]{64}$');
  static final _uuid = RegExp(
      r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$');

  Map<String, Object> _json() => {
    'state': state.name,
    'operation_id': operationId,
    'owner_generation': ownerGeneration,
    'replica_digest': replicaDigest,
    'scope_generation': scopeGeneration,
  };

  static AccountFenceRecord _parse(Object? value) {
    if (value is! Map<String, dynamic> || !_keys(value, const {
      'state', 'operation_id', 'owner_generation', 'replica_digest',
      'scope_generation',
    }) || value['operation_id'] is! String ||
        value['owner_generation'] is! String ||
        value['replica_digest'] is! String || value['scope_generation'] is! int) {
      throw const FormatException('invalid_account_fence_record');
    }
    final state = switch (value['state']) {
      'pending' => AccountFenceState.pending,
      'gone' => AccountFenceState.gone,
      _ => throw const FormatException('invalid_account_fence_state'),
    };
    return AccountFenceRecord(
      state: state,
      operationId: value['operation_id'] as String,
      ownerGeneration: value['owner_generation'] as String,
      replicaDigest: value['replica_digest'] as String,
      scopeGeneration: value['scope_generation'] as int,
    );
  }
}

bool _keys(Map<String, dynamic> value, Set<String> expected) =>
    value.length == expected.length && value.keys.every(expected.contains);

/// Application-owned, aggregate deny store. It serializes only this instance's
/// operations; this is not a cross-process compare-and-swap guarantee.
class AccountFenceStore {
  AccountFenceStore({AccountFencePersistence? persistence})
      : _persistence = persistence ?? const _SecureAccountFencePersistence();

  static const storageKey = 'qirsh.account_fence.v1';
  static final shared = AccountFenceStore();
  final AccountFencePersistence _persistence;
  final Map<String, AccountFenceRecord> _holds = {};
  final Map<String, AccountFenceRecord> _accepted = {};
  Future<void> _tail = Future<void>.value();
  Future<bool>? _loading;
  bool _known = false;
  int _pendingWrites = 0;

  bool get ready => _known && _pendingWrites == 0 && _loading == null;

  /// Unknown state denies synchronously. A successful load of valid absence is
  /// required before an owner without a known hold can pass this store.
  bool allows(String ownerDigest) => ready &&
      AccountFenceRecord._digest.hasMatch(ownerDigest) &&
      !_holds.containsKey(ownerDigest);

  AccountFenceRecord? holdFor(String ownerDigest) => _holds[ownerDigest];

  static String ownerDigest(String exactUid) => sha256.convert(utf8.encode(
      'qirsh.account_fence.owner.v1\u0000$exactUid')).toString();

  static String replicaDigest(String capturedDbPath, String keyName) =>
      sha256.convert(utf8.encode(
          'qirsh.account_fence.replica.v1\u0000$capturedDbPath\u0000$keyName')).toString();

  Future<T> _serial<T>(Future<T> Function() work) {
    final run = _tail.then((_) => work());
    _tail = run.then<void>((_) {}, onError: (Object _) {});
    return run;
  }

  /// Every guarded load reads the dedicated key again. Concurrent callers share
  /// one read; errors never become a cached clear state.
  Future<bool> load() {
    final current = _loading;
    if (current != null) return current;
    _known = false;
    final run = _serial(() async {
      try {
        _merge(_parse(await _persistence.read()));
        _known = true;
        return true;
      } catch (_) {
        _known = false;
        return false;
      }
    });
    late final Future<bool> loading;
    loading = run.whenComplete(() {
      if (identical(_loading, loading)) _loading = null;
    });
    _loading = loading;
    return loading;
  }

  /// The mirror changes BEFORE any await or queued work. A returned true means
  /// the merged write was read back exactly; false is incomplete, never release.
  Future<bool> record(String ownerDigest, AccountFenceRecord record) {
    if (!AccountFenceRecord._digest.hasMatch(ownerDigest)) {
      throw ArgumentError('invalid_account_fence_owner_digest');
    }
    final accepted = _stronger(_holds[ownerDigest], record);
    _accepted[ownerDigest] = accepted;
    _holds[ownerDigest] = accepted;
    _pendingWrites++;
    return _serial(() async {
      _known = false;
      try {
        _merge(_parse(await _persistence.read()));
        final expected = _encode(_holds);
        await _persistence.write(expected);
        final confirmed = _parse(await _persistence.read());
        if (_encode(confirmed) != expected) return false;
        _merge(confirmed);
        _known = true;
        return true;
      } catch (_) {
        return false;
      } finally {
        _pendingWrites--;
      }
    });
  }

  void _merge(Map<String, AccountFenceRecord> disk) {
    // An older read cannot discard a synchronous hold, and neither a missing
    // disk entry nor a newer generation can clear an already observed denial.
    for (final entry in disk.entries) {
      _holds[entry.key] = _stronger(_holds[entry.key], entry.value);
    }
    for (final entry in _accepted.entries) {
      _holds[entry.key] = _stronger(_holds[entry.key], entry.value);
    }
  }

  static AccountFenceRecord _stronger(
      AccountFenceRecord? previous, AccountFenceRecord next) =>
      previous?.state == AccountFenceState.gone ? previous! : next;

  static Map<String, AccountFenceRecord> _parse(String? raw) {
    if (raw == null) return {};
    final value = jsonDecode(raw);
    if (value is! Map<String, dynamic> ||
        !_keys(value, const {'version', 'owners'}) ||
        value['version'] is! int || value['version'] != 1 ||
        value['owners'] is! Map<String, dynamic>) {
      throw const FormatException('invalid_account_fence_store');
    }
    final owners = value['owners'] as Map<String, dynamic>;
    final parsed = <String, AccountFenceRecord>{};
    for (final entry in owners.entries) {
      if (!AccountFenceRecord._digest.hasMatch(entry.key)) {
        throw const FormatException('invalid_account_fence_owner_digest');
      }
      parsed[entry.key] = AccountFenceRecord._parse(entry.value);
    }
    return parsed;
  }

  static String _encode(Map<String, AccountFenceRecord> records) {
    final owners = records.keys.toList()..sort();
    return jsonEncode({'version': 1, 'owners': {
      for (final owner in owners) owner: records[owner]!._json(),
    }});
  }
}
