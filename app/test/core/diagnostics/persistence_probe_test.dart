// TEMP-PROBE: tests the diagnostic recorder, not evidence of the device bug.
import 'dart:convert';
import 'dart:io';
import 'package:drift/native.dart';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/diagnostics/persistence_probe.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';

class _TestKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'test-only';
  @override
  Future<String?> readStoredKey() async => 'test-only';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  if (!PersistenceProbe.enabled) {
    test('TEMP-PROBE opt-in recorder tests', () {},
        skip: 'Run with --dart-define=QA_PERSISTENCE_TRACE=true');
    return;
  }
  late Directory directory;
  File trace() => File('${directory.path}/qa_persistence_trace.jsonl');
  Future<List<Map<String, dynamic>>> events() async =>
      (await trace().readAsLines())
          .map((s) => jsonDecode(s) as Map<String, dynamic>)
          .toList();

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('qirsh-probe-test-');
    FlutterSecureStorage.setMockInitialValues(
        {'local_data_owner_uid': 'PRIVATE_OWNER_SENTINEL'});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (_) async => directory.path);
  });
  tearDown(() async {
    await directory.delete(recursive: true);
  });

  test(
      'intent is durably appended before mutation, SQL and identity are absent',
      () async {
    expect(PersistenceProbe.enabled, isTrue,
        reason: 'run with --dart-define=QA_PERSISTENCE_TRACE=true');
    await PersistenceProbe.sql(
        "UPDATE accounts SET name='PRIVATE_FINANCIAL_SENTINEL'", () async {
      final before = await events();
      expect(before.single['event'], 'mutation.before');
      expect(before.single['domain'], 'accounts');
      return 1;
    });
    final after = await events();
    expect(after.last['event'], 'mutation.succeeded');
    expect(after.first['operationId'], after.last['operationId']);
    final text = await trace().readAsString();
    expect(text, isNot(contains('PRIVATE_')));
    expect(text, isNot(contains('SET name')));
    expect(after.first['ownerPresent'], isTrue);
    expect(after.first['ownerAuthStatus'], 'not_comparable');
  });

  test('failure is distinguished and exception text is never recorded',
      () async {
    await expectLater(
        PersistenceProbe.sql('DELETE FROM accounts', () async {
          throw StateError('PRIVATE_EXCEPTION_SENTINEL');
        }),
        throwsStateError);
    final rows = await events();
    expect(rows.map((r) => r['event']), ['mutation.before', 'mutation.failed']);
    expect(rows.first['destructive'], isTrue);
    expect(await trace().readAsString(), isNot(contains('PRIVATE_EXCEPTION')));
  });

  test('concurrent calls append complete ordered records without truncation',
      () async {
    await PersistenceProbe.record('prior.launch');
    await Future.wait(
        List.generate(20, (_) => PersistenceProbe.record('concurrent')));
    final rows = await events();
    expect(rows.length, 21);
    expect(rows.first['event'], 'prior.launch');
    final sequences = rows.map((r) => r['sequence'] as int).toList();
    expect(sequences, orderedEquals([...sequences]..sort()));
    expect(sequences.toSet().length, 21);
  });

  test('disk writes capture state and distinguish rollback from commit', () async {
    final file = File('${directory.path}/money_companion.sqlite');
    final db = await AppDatabase.open(executor: NativeDatabase(file), keyStore: _TestKeyStore());
    try {
      await db.transaction(() => db.customStatement("UPDATE user_settings SET language = 'en'"));
      await expectLater(db.transaction(() async {
        await db.customStatement("UPDATE user_settings SET language = 'ar'");
        throw StateError('PRIVATE_ROLLBACK_SENTINEL');
      }), throwsStateError);
      final rows = await events();
      expect(rows.any((r) => r['event'] == 'transaction.committed'), isTrue);
      expect(rows.last['event'], 'transaction.failed');
      final statements = rows.where((r) => r['event'] == 'statement.state.after' && r['domain'] == 'user_settings');
      expect(statements.any((r) => r['language'] == 'en'), isTrue);
      expect((await db.customSelect('SELECT language FROM user_settings').getSingle()).read<String>('language'), 'en');
      expect(await trace().readAsString(), isNot(contains('PRIVATE_')));
    } finally { await db.close(); }
    final reopened = await AppDatabase.open(executor: NativeDatabase(file), keyStore: _TestKeyStore());
    try {
      expect((await reopened.customSelect('SELECT language FROM user_settings').getSingle()).read<String>('language'), 'en');
      expect((await events()).any((r) => r['event'] == 'transaction.failed'), isTrue);
      await PersistenceProbe.snapshot('test.reopened.snapshot', reopened);
      final snapshot = (await events()).last;
      expect(snapshot['event'], 'test.reopened.snapshot');
      expect(snapshot['dbPath'], file.path);
      expect(snapshot['dbExists'], isTrue);
      expect(snapshot['dbSize'], await file.length());
      expect(snapshot['counts']['user_settings'], 1);
      expect(snapshot['language'], 'en');
      expect(snapshot.containsKey('inode'), isFalse);
      expect(snapshot.containsKey('nativeDbPath'), isFalse);
      expect(snapshot.containsKey('nativeDbSize'), isFalse);
      expect(await trace().readAsString(), isNot(contains('PRIVATE_')));
    } finally { await reopened.close(); }
  });
}
