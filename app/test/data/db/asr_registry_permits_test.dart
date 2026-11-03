import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/db/replica_store.dart';

import '../../core/session/recording_secure_storage.dart';

/// ASR v7.2 E11 (§9.2/§12, Phase 4 B6): the registry predicate reads through
/// the status-preserving accessor, parses strictly and honours every
/// restriction local read itself honours. Host fixture over a real replica.
const _uid = 'uid-aaaa';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory support;
  late ReplicaStore store;
  late Map<String, Object?> registry;

  setUp(() async {
    support = Directory.systemTemp.createTempSync('asr_registry_');
    RecordingSecureStorage().install();
    store = ReplicaStore(
      requireCreationAuthority: false,
      appSupportDirectory: support.path,
      readOwnerMarker: () async => _uid,
    );
    await store.openReplica(_uid);
    await store.closeAll();
    registry = (jsonDecode((await const FlutterSecureStorage()
            .read(key: ReplicaStore.registryKey))!) as Map)
        .cast<String, Object?>();
  });

  tearDown(() async {
    await store.closeAll();
    if (support.existsSync()) support.deleteSync(recursive: true);
  });

  Future<bool> permits(String? raw) => store.asrRegistryPermits(_uid,
      read: (key) async {
        expect(key, ReplicaStore.registryKey);
        return raw;
      });

  Future<String> withEntry(void Function(Map<String, Object?> e) edit) async {
    final hash = await store.uidHash(_uid);
    final copy = jsonDecode(jsonEncode(registry)) as Map<String, Object?>;
    edit((copy[hash]! as Map).cast<String, Object?>());
    return jsonEncode(copy);
  }

  test('an active, settled entry passes', () async {
    expect(await permits(jsonEncode(registry)), isTrue);
  });

  test('an unreadable registry denies', () async {
    expect(
        await store.asrRegistryPermits(_uid,
            read: (_) async => throw StateError('unavailable')),
        isFalse);
  });

  test('absent or empty denies (local read requires an entry)', () async {
    expect(await permits(null), isFalse);
    expect(await permits(''), isFalse);
    expect(await permits('{}'), isFalse);
  });

  test('malformed JSON or a malformed restriction flag denies', () async {
    expect(await permits('{'), isFalse);
    expect(await permits(await withEntry((e) => e['adoptPending'] = 'yes')),
        isFalse);
  });

  for (final state in ['locked', 'migrating', 'quarantined']) {
    test('a $state replica denies', () async {
      expect(await permits(await withEntry((e) => e['state'] = state)),
          isFalse);
    });
  }

  test('an adoption-pending replica denies', () async {
    expect(await permits(await withEntry((e) => e['adoptPending'] = true)),
        isFalse);
  });

  test('a rebootstrap in progress anywhere denies', () async {
    final copy = jsonDecode(jsonEncode(registry)) as Map<String, Object?>;
    copy['0' * 32] = {
      ...(copy.values.first! as Map).cast<String, Object?>(),
      'rebootstrap': {
        'phase': 'frozen',
        'reason': 'purge',
        'startedAt': DateTime.utc(2026).toIso8601String(),
      },
    };
    expect(await permits(jsonEncode(copy)), isFalse);
  });
}
