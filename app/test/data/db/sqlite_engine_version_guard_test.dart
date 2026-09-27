import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'test-key';
  @override
  Future<String?> readStoredKey() async => 'test-key';
}

/// THE RUNTIME SQLITE ENGINE MUST NOT REGRESS BELOW THE WAL-RESET FIX.
///
/// SQLite 3.51.3 fixed a WAL-reset defect that can corrupt a database when a
/// WAL reset races other access. Qirsh is not exposed to it today on two
/// independent counts, and this guard exists so neither can be lost silently:
///
///   1. ENGINE. `package:sqlite3` builds SQLite Multiple Ciphers from source via
///      its build hook; 3.3.2 moved to SQLite 3.53.1 and 3.3.3 inherits it. The
///      Dart package version is NOT the engine version, which is exactly why
///      this asserts the engine at runtime rather than reading pubspec.
///
///   2. CONCURRENCY. docs/PROCESS_ACCESS_INVENTORY.md states the contract that
///      exactly one OS process ever opens the database: it lives in the app's
///      private Application Support directory, not the App Group, and the Share
///      Extension contains no SQLite reference at all. A cross-isolate lease
///      covers isolates within that one process.
///
/// A downgrade of either is a P0, so the engine half is pinned here.
void main() {
  /// Asked through the SAME stack the app uses — an AppDatabase over the native
  /// executor — rather than by importing sqlite3 directly. That keeps the guard
  /// honest (it measures what actually ships) and avoids promoting a transitive
  /// package to a direct dependency purely for a test.
  Future<({int number, String text})> engineVersion() async {
    final db = await AppDatabase.open(
      executor: NativeDatabase.memory(),
      keyStore: _MemoryKeyStore(),
    );
    try {
      final row = await db
          .customSelect('select sqlite_version() as v, '
              'sqlite_version() is not null as ok;')
          .getSingle();
      final text = row.read<String>('v');
      final parts = text.split('.').map(int.parse).toList();
      return (
        number: parts[0] * 1000000 + parts[1] * 1000 + (parts.length > 2 ? parts[2] : 0),
        text: text,
      );
    } finally {
      await db.close();
    }
  }

  test('the linked SQLite engine is at or past the WAL-reset fix (3.51.3)',
      () async {
    final v = await engineVersion();
    // SQLite encodes version as X*1000000 + Y*1000 + Z.
    const walResetFix = 3 * 1000000 + 51 * 1000 + 3;

    expect(
      v.number,
      greaterThanOrEqualTo(walResetFix),
      reason: 'linked SQLite ${v.text} predates 3.51.3, whose WAL-reset fix '
          'this app has never had to think about. Before shipping this engine, '
          're-prove the single-writer-process contract in '
          'docs/PROCESS_ACCESS_INVENTORY.md — the two together are what make '
          'the defect unreachable.',
    );
  });

  test('the engine reports a usable version at all', () async {
    // A guard that cannot read the version is not a guard.
    final v = await engineVersion();
    expect(v.text, matches(r'^\d+\.\d+\.\d+'));
    expect(v.number, greaterThan(3 * 1000000));
  });
}
