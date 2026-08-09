import 'dart:async';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';

// MALI-040 — regression coverage for the production close() lifecycle defect:
// AppDatabase.close() overrode GeneratedDatabase.close() but never called
// super.close(), so Drift's stream-query manager was never disposed and Drift's
// open-database counter was never decremented (the source of the spurious
// "created the database class AppDatabase multiple times" warnings). These tests
// drive the REAL production close() path and would fail on the old
// implementation. The warning is CAPTURED (not suppressed) to assert on it.

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'memory-key';
  @override
  Future<String?> readStoredKey() async => 'memory-key';
}

Future<AppDatabase> _open() =>
    AppDatabase.open(executor: NativeDatabase.memory(), keyStore: _MemoryKeyStore());

void main() {
  test(
      'close() decrements Drift open-db counter — a watched query then close '
      'leaves no multi-db warning on the next open', () async {
    final messages = <String>[];
    final original = driftRuntimeOptions.debugPrint;
    driftRuntimeOptions.debugPrint = messages.add;
    addTearDown(() => driftRuntimeOptions.debugPrint = original);

    // Instantiate Drift's stream-query manager so close() MUST dispose it.
    final db1 = await _open();
    final sub = db1.customSelect('SELECT 1 AS x').watch().listen((_) {});
    await db1.close();
    await sub.cancel();

    // Isolate the next open: with the old close() (no super.close) the counter
    // was never decremented, so this open would emit the multi-db warning.
    messages.clear();
    final db2 = await _open();
    addTearDown(db2.close);

    expect(
      messages.where((m) => m.contains('created the database class')),
      isEmpty,
      reason: 'close() must call super.close() so Drift decrements its counter',
    );
  });

  test('close() terminates active watch streams (streamQueries disposed)',
      () async {
    final db = await _open();
    final done = Completer<void>();
    final sub = db
        .customSelect('SELECT 1 AS x')
        .watch()
        .listen((_) {}, onDone: done.complete);

    await db.close();

    // With super.close() the stream-query manager closes its controllers, so the
    // stream completes. Without it (old code) this never fires → timeout → fail.
    await done.future.timeout(
      const Duration(seconds: 5),
      onTimeout: () =>
          fail('watch stream was not terminated — streamQueries not disposed'),
    );
    await sub.cancel();
  });

  test('close() is idempotent — repeated close is safe and stays balanced',
      () async {
    final messages = <String>[];
    final original = driftRuntimeOptions.debugPrint;
    driftRuntimeOptions.debugPrint = messages.add;
    addTearDown(() => driftRuntimeOptions.debugPrint = original);

    final db = await _open();
    await db.close();
    await db.close(); // second close must not throw or double-decrement

    messages.clear();
    final next = await _open();
    addTearDown(next.close);
    expect(
      messages.where((m) => m.contains('created the database class')),
      isEmpty,
      reason: 'repeated close must leave the counter balanced (one decrement)',
    );
  });
}
