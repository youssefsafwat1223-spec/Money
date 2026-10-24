import 'dart:async';
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/security/secure_storage_options.dart';
import 'package:money_companion/core/session/account_fence_store.dart';
import 'package:money_companion/data/db/database_key_store.dart';

import 'recording_secure_storage.dart';

class _Persistence implements AccountFencePersistence {
  String? value;
  int reads = 0;
  final writes = <String>[];
  Future<String?> Function()? onRead;
  Future<void> Function(String)? onWrite;

  @override
  Future<String?> read() async {
    reads++;
    return onRead == null ? value : await onRead!();
  }

  @override
  Future<void> write(String value) async {
    writes.add(value);
    if (onWrite != null) {
      await onWrite!(value);
    } else {
      this.value = value;
    }
  }
}

const _operation = '550e8400-e29b-41d4-a716-446655440000';
final _owner = AccountFenceStore.ownerDigest('owner-a');
final _other = AccountFenceStore.ownerDigest('owner-b');
final _replica = AccountFenceStore.replicaDigest('/captured/a.sqlite', 'key-a');

AccountFenceRecord _record([AccountFenceState state = AccountFenceState.pending,
    String generation = 'generation-a']) => AccountFenceRecord(
      state: state,
      operationId: _operation,
      ownerGeneration: generation,
      replicaDigest: _replica,
      scopeGeneration: 7,
    );

Map<String, Object?> _entry() => {
  'state': 'pending', 'operation_id': _operation,
  'owner_generation': 'generation-a', 'replica_digest': _replica,
  'scope_generation': 7,
};
String _envelope(Map<String, Object?> owners) =>
    jsonEncode({'version': 1, 'owners': owners});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('E4 store synchronous unknown denies, verified null alone means absence', () async {
    final io = _Persistence();
    final store = AccountFenceStore(persistence: io);
    expect(store.ready, isFalse);
    expect(store.allows(_owner), isFalse);
    expect(await store.load(), isTrue);
    expect(store.ready, isTrue);
    expect(store.allows(_owner), isTrue);
    expect(store.holdFor(_owner), isNull);
    expect(io.writes, isEmpty);
  });

  test('E4 store coalesces concurrent reads and does not authorize while paused', () async {
    final entered = Completer<void>();
    final reply = Completer<String?>();
    final io = _Persistence()..onRead = () { entered.complete(); return reply.future; };
    final store = AccountFenceStore(persistence: io);
    final a = store.load(); final b = store.load();
    final readyAfterA = a.then((_) => store.ready);
    final readyAfterB = b.then((_) => store.ready);
    expect(identical(a, b), isTrue, reason: 'coalesced callers share the same completion boundary');
    await entered.future;
    expect(io.reads, 1);
    expect(store.allows(_owner), isFalse);
    reply.complete(null);
    expect(await a, isTrue); expect(await b, isTrue);
    expect(await readyAfterA, isTrue);
    expect(await readyAfterB, isTrue);
    expect(store.allows(_owner), isTrue);
  });

  test('E4 store read failure is restrictive and retried, never cached clear', () async {
    final io = _Persistence(); final store = AccountFenceStore(persistence: io);
    expect(await store.load(), isTrue);
    io.onRead = () async => throw StateError('unavailable');
    expect(await store.load(), isFalse);
    expect(store.ready, isFalse);
    expect(store.allows(_owner), isFalse);
    io.onRead = null;
    expect(await store.load(), isTrue);
    expect(io.reads, 3);
    expect(store.allows(_owner), isTrue);
  });

  final malformed = <String, Object?>{
    'empty': '', 'invalid JSON': '{', 'non-object': [],
    'missing owners': {'version': 1},
    'extra envelope field': {'version': 1, 'owners': {}, 'extra': true},
    'wrong version': {'version': 2, 'owners': {}},
    'numeric version': {'version': 1.0, 'owners': {}},
    'wrong owner map': {'version': 1, 'owners': []},
    'raw owner key': {'version': 1, 'owners': {'owner-a': _entry()}},
    'uppercase digest': {'version': 1, 'owners': {_owner.toUpperCase(): _entry()}},
    'missing field plus extra': {'version': 1, 'owners': {_owner: {..._entry()..remove('operation_id'), 'extra': true}}},
    'extra record field': {'version': 1, 'owners': {_owner: {..._entry(), 'extra': true}}},
    'unknown state': {'version': 1, 'owners': {_owner: {..._entry(), 'state': 'clear'}}},
    'bad operation': {'version': 1, 'owners': {_owner: {..._entry(), 'operation_id': 'not-a-uuid'}}},
    'empty generation': {'version': 1, 'owners': {_owner: {..._entry(), 'owner_generation': ''}}},
    'wrong generation type': {'version': 1, 'owners': {_owner: {..._entry(), 'owner_generation': 7}}},
    'invalid replica': {'version': 1, 'owners': {_owner: {..._entry(), 'replica_digest': '/raw/path'}}},
    'negative scope': {'version': 1, 'owners': {_owner: {..._entry(), 'scope_generation': -1}}},
    'floating scope': {'version': 1, 'owners': {_owner: {..._entry(), 'scope_generation': 7.0}}},
    'null record': {'version': 1, 'owners': {_owner: null}},
  };
  for (final item in malformed.entries) {
    test('E4 store rejects ${item.key} without writes', () async {
      final io = _Persistence()..value = item.value is String ? item.value as String : jsonEncode(item.value);
      final store = AccountFenceStore(persistence: io);
      expect(await store.load(), isFalse);
      expect(store.allows(_owner), isFalse);
      expect(store.allows(_other), isFalse);
      expect(io.writes, isEmpty);
    });
  }

  test('E4 store synchronous hold survives an older paused absence read', () async {
    final entered = Completer<void>(); final reply = Completer<String?>();
    final io = _Persistence();
    io.onRead = () { entered.complete(); return reply.future; };
    final store = AccountFenceStore(persistence: io);
    final loading = store.load(); await entered.future;
    final writing = store.record(_owner, _record());
    expect(store.holdFor(_owner)?.state, AccountFenceState.pending);
    expect(store.allows(_owner), isFalse);
    io.onRead = null; reply.complete(null);
    expect(await loading, isTrue);
    expect(store.allows(_owner), isFalse);
    expect(await writing, isTrue);
    final rebuilt = AccountFenceStore(persistence: io);
    expect(await rebuilt.load(), isTrue);
    expect(rebuilt.allows(_owner), isFalse);
    expect(rebuilt.holdFor(_owner)?.ownerGeneration, 'generation-a');
  });

  test('E4 store queued load denies unrelated owner after write completion until read resolves', () async {
    final writeEntered = Completer<void>();
    final writeRelease = Completer<void>();
    final readEntered = Completer<void>();
    final readRelease = Completer<String?>();
    final io = _Persistence();
    var reads = 0;
    io.onRead = () async {
      reads++;
      if (reads == 3) {
        readEntered.complete();
        return readRelease.future;
      }
      return io.value;
    };
    io.onWrite = (value) async {
      writeEntered.complete();
      await writeRelease.future;
      io.value = value;
    };
    final store = AccountFenceStore(persistence: io);
    final writing = store.record(_owner, _record());
    await writeEntered.future;
    final loading = store.load();
    final coalesced = store.load();
    writeRelease.complete();
    expect(await writing, isTrue);
    await readEntered.future;
    final readyDuringRead = store.ready;
    final otherAllowedDuringRead = store.allows(_other);
    final heldOwnerAllowedDuringRead = store.allows(_owner);
    readRelease.completeError(StateError('read unavailable'));
    expect(await loading, isFalse);
    expect(await coalesced, isFalse);
    expect(store.ready, isFalse);
    expect(store.allows(_other), isFalse);
    expect(store.allows(_owner), isFalse);
    expect(await store.load(), isTrue);
    expect(store.ready, isTrue);
    expect(store.allows(_other), isTrue);
    expect(store.allows(_owner), isFalse);
    expect(readyDuringRead, isFalse, reason: 'a queued unresolved load keeps readiness closed after the write settles');
    expect(otherAllowedDuringRead, isFalse);
    expect(heldOwnerAllowedDuringRead, isFalse);
  });

  test('E4 store gone is synchronous and never downgraded by pending or absence', () async {
    final io = _Persistence(); final store = AccountFenceStore(persistence: io);
    final writing = store.record(_owner, _record(AccountFenceState.gone));
    expect(store.holdFor(_owner)?.state, AccountFenceState.gone);
    expect(await writing, isTrue);
    expect(await store.record(_owner, _record(AccountFenceState.pending, 'new-generation')), isTrue);
    expect(store.holdFor(_owner)?.state, AccountFenceState.gone);
    expect(store.holdFor(_owner)?.ownerGeneration, 'generation-a');
    io.value = null;
    expect(await store.load(), isTrue);
    expect(store.allows(_owner), isFalse, reason: 'absence never releases an observed hold in this application');
    expect(await store.record(_other, _record()), isTrue);
    final rebuilt = AccountFenceStore(persistence: io); await rebuilt.load();
    expect(rebuilt.holdFor(_owner)?.state, AccountFenceState.gone);
    expect(rebuilt.holdFor(_other)?.state, AccountFenceState.pending);
  });

  test('E4 store merges actual disk owners, serializes writes and confirms readback', () async {
    final io = _Persistence()..value = _envelope({_other: _entry()});
    final entered = Completer<void>(); final release = Completer<void>();
    var writes = 0;
    io.onWrite = (value) async {
      writes++;
      if (writes == 1) { entered.complete(); await release.future; }
      io.value = value;
    };
    final store = AccountFenceStore(persistence: io);
    final pending = store.record(_owner, _record()); await entered.future;
    final gone = store.record(_owner, _record(AccountFenceState.gone));
    expect(store.holdFor(_owner)?.state, AccountFenceState.gone);
    expect(writes, 1);
    release.complete(); expect(await pending, isTrue); expect(await gone, isTrue);
    expect(writes, 2);
    final rebuilt = AccountFenceStore(persistence: io); expect(await rebuilt.load(), isTrue);
    expect(rebuilt.holdFor(_owner)?.state, AccountFenceState.gone);
    expect(rebuilt.holdFor(_other)?.state, AccountFenceState.pending);
    expect(io.reads, 5, reason: 'two read/merge + two verification + reconstruction');
  });

  for (final failure in ['read', 'before write', 'after write', 'readback', 'mismatch']) {
    test('E4 store $failure stays restrictive and reports incomplete', () async {
      final io = _Persistence(); var reads = 0;
      io.onRead = () async {
        reads++;
        if (failure == 'read' || (failure == 'readback' && reads == 2)) throw StateError('unavailable');
        return failure == 'mismatch' && reads == 2 ? null : io.value;
      };
      io.onWrite = (value) async {
        if (failure == 'before write') throw StateError('unavailable');
        io.value = value;
        if (failure == 'after write') throw StateError('ambiguous');
      };
      final store = AccountFenceStore(persistence: io);
      final run = store.record(_owner, _record());
      expect(store.holdFor(_owner), isNotNull);
      expect(await run, isFalse);
      expect(store.ready, isFalse); expect(store.allows(_owner), isFalse);
      expect(store.allows(_other), isFalse);
      expect(store.holdFor(_owner)?.state, AccountFenceState.pending);
      io.onRead = null; io.onWrite = null;
      expect(await store.record(_owner, _record()), isTrue);
      final rebuilt = AccountFenceStore(persistence: io); await rebuilt.load();
      expect(rebuilt.allows(_owner), isFalse);
    });
  }

  test('E4 store malformed disk cannot be overwritten as if it were absent', () async {
    final io = _Persistence()..value = '{broken';
    final store = AccountFenceStore(persistence: io);
    expect(await store.record(_owner, _record()), isFalse);
    expect(io.writes, isEmpty); expect(io.value, '{broken');
    expect(store.allows(_owner), isFalse);
  });

  test('E4 store digest domains use exact captured UID and replica path/key', () {
    expect(_owner, '68d852644262b186236aaf8614778ad3e2932726494d17dad8dc3506700f63f9');
    expect(_replica, '4bf84c89a5870cd22483830717c339ee0fcd5ca2ba1bbea8ffa092ac6046edfc');
    expect(AccountFenceStore.ownerDigest('owner-a '), isNot(_owner));
    expect(AccountFenceStore.replicaDigest('/captured/a.sqlite', 'key-b'), isNot(_replica));
    expect(AccountFenceStore.replicaDigest('/captured//a.sqlite', 'key-a'), isNot(_replica));
  });

  test('E4 store a lost successful write remains denied after reconstruction', () async {
    final io = _Persistence();
    io.onWrite = (value) async { io.value = value; throw StateError('lost acknowledgement'); };
    final store = AccountFenceStore(persistence: io);
    expect(await store.record(_owner, _record(AccountFenceState.gone)), isFalse);
    expect(store.allows(_owner), isFalse);
    final rebuilt = AccountFenceStore(persistence: io);
    expect(await rebuilt.load(), isTrue);
    expect(rebuilt.holdFor(_owner)?.state, AccountFenceState.gone);
    expect(rebuilt.allows(_owner), isFalse);
  });

  test('E4 store malformed other owner prevents partial load or clobber', () async {
    final io = _Persistence()..value = _envelope({_owner: _entry(), _other: {'state': 'gone'}});
    final before = io.value;
    final store = AccountFenceStore(persistence: io);
    expect(await store.load(), isFalse);
    expect(store.allows(_owner), isFalse); expect(store.allows(_other), isFalse);
    expect(await store.record(_owner, _record()), isFalse);
    expect(io.value, before); expect(io.writes, isEmpty);
  });

  test('E4 store an old read cannot replace synchronous captured provenance', () async {
    final entered = Completer<void>(); final release = Completer<String?>();
    final io = _Persistence()..onRead = () { entered.complete(); return release.future; };
    final store = AccountFenceStore(persistence: io);
    final loading = store.load(); await entered.future;
    final writing = store.record(_owner, _record(AccountFenceState.gone, 'captured-new'));
    io.onRead = null;
    release.complete(_envelope({_owner: _entry()}));
    expect(await loading, isTrue);
    expect(store.holdFor(_owner)?.state, AccountFenceState.gone);
    expect(store.holdFor(_owner)?.ownerGeneration, 'captured-new');
    expect(await writing, isTrue);
    expect((jsonDecode(io.value!) as Map)['owners'][_owner]['owner_generation'], 'captured-new');
  });

  test('E4 store failed initialization never erases accepted synchronous denial', () async {
    final entered = Completer<void>(); final release = Completer<String?>();
    final io = _Persistence()..onRead = () { entered.complete(); return release.future; };
    final store = AccountFenceStore(persistence: io);
    final loading = store.load(); await entered.future;
    final writing = store.record(_owner, _record());
    io.onRead = null; release.complete('{broken');
    expect(await loading, isFalse);
    expect(store.holdFor(_owner)?.state, AccountFenceState.pending);
    expect(await writing, isTrue);
    expect(store.allows(_owner), isFalse);
  });

  test('E4 store validates captured metadata before accepting or writing', () {
    final io = _Persistence(); final store = AccountFenceStore(persistence: io);
    expect(() => store.record('raw-owner', _record()), throwsArgumentError);
    expect(() => AccountFenceRecord(state: AccountFenceState.pending,
        operationId: 'not-a-uuid', ownerGeneration: 'gen', replicaDigest: _replica,
        scopeGeneration: 0), throwsArgumentError);
    expect(store.holdFor('raw-owner'), isNull); expect(io.writes, isEmpty);
  });

  test('E4 store uses dedicated key and exact existing storage options', () async {
    final platform = _RecordingPlatform();
    platform.install();
    // The storage package selects dart:io Platform, not Flutter's target
    // override. Compare the real boundary with the existing production object.
    await SecureStorageOptions.storage.read(key: AccountFenceStore.storageKey);
    final expectedOptions = platform.options.single;
    platform.options.clear(); platform.readKeys.clear();
    expect(SecureStorageOptions.storage.iOptions.toMap(), SecureStorageOptions.ios.toMap());
    expect(SecureStorageOptions.storage.aOptions.toMap(), SecureStorageOptions.android.toMap());
    final store = AccountFenceStore();
    expect(await store.load(), isTrue);
    expect(await store.record(_owner, _record()), isTrue);
    expect(platform.readKeys.toSet(), {AccountFenceStore.storageKey});
    expect(platform.writeKeys.toSet(), {AccountFenceStore.storageKey});
    expect(platform.enumerations, 0); expect(platform.deletes, isEmpty);
    for (final actual in platform.options) { expect(actual, expectedOptions); }
    final encoded = platform.data[AccountFenceStore.storageKey]!;
    expect(encoded, isNot(contains('owner-a')));
    expect(encoded, isNot(contains('/captured')));
    expect(encoded, isNot(contains('key-a')));
  });

  test('E4 real session wipe helper preserves persisted denial key', () async {
    FlutterSecureStorage.setMockInitialValues({});
    final store = AccountFenceStore();
    expect(await store.record(_owner, _record(AccountFenceState.gone)), isTrue);
    const storage = SecureStorageOptions.storage;
    await storage.write(key: 'auth_email', value: 'fixture@example.invalid');
    final before = await storage.read(key: AccountFenceStore.storageKey);
    final result = await wipeSecureStoragePreservingDatabaseKey(
        readAll: storage.readAll, delete: (key) => storage.delete(key: key));
    expect(result.isComplete, isTrue);
    expect(await storage.read(key: 'auth_email'), isNull);
    expect(await storage.read(key: AccountFenceStore.storageKey), before);
    final rebuilt = AccountFenceStore(); expect(await rebuilt.load(), isTrue);
    expect(rebuilt.holdFor(_owner)?.state, AccountFenceState.gone);
  });
}


class _RecordingPlatform extends RecordingSecureStorage {
  final readKeys = <String>[];
  final writeKeys = <String>[];
  final options = <Map<String, String>>[];
  int enumerations = 0;
  @override
  Future<String?> read({required String key, required Map<String, String> options}) {
    readKeys.add(key); this.options.add(options);
    return super.read(key: key, options: options);
  }
  @override
  Future<void> write({required String key, required String value, required Map<String, String> options}) {
    writeKeys.add(key); this.options.add(options);
    return super.write(key: key, value: value, options: options);
  }
  @override
  Future<Map<String, String>> readAll({required Map<String, String> options}) {
    enumerations++;
    return super.readAll(options: options);
  }
}
