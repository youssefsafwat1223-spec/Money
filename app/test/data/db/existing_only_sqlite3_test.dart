// `package:sqlite3` is a transitive dependency (through drift), as in the source
// file under test.
// ignore_for_file: depend_on_referenced_packages

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/db/existing_only_sqlite3.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

// The resolver decides the SQLite open mode. A caller (drift) always asks for the
// creating default; the CONFIGURED mode must win, or "existing only" and
// "read only" are only names. Real SQLite files, no mocks.

void main() {
  late Directory dir;
  late String existing;
  late String missing;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('existing_only_sqlite3_');
    existing = p.join(dir.path, 'existing.sqlite');
    missing = p.join(dir.path, 'missing.sqlite');
    final db = sqlite3.open(existing);
    db.execute('CREATE TABLE t(v TEXT);');
    db.execute("INSERT INTO t VALUES ('known');");
    db.dispose();
  });

  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  List<String> rows(Database db) =>
      db.select('SELECT v FROM t;').map((r) => r['v'] as String).toList();

  group('read-only resolver', () {
    test('a caller asking for a creating, writable mode still gets read-only',
        () async {
      final resolved = await databaseResolver(existing,
          createFile: false, readOnly: true)();
      final db = resolved.open(existing, mode: OpenMode.readWriteCreate);
      expect(rows(db), ['known']);
      for (final mode in [OpenMode.readWriteCreate, OpenMode.readWrite]) {
        final again = resolved.open(existing, mode: mode);
        expect(() => again.execute("INSERT INTO t VALUES ('x');"),
            throwsA(isA<SqliteException>()));
        expect(() => again.execute('CREATE TABLE u(a);'),
            throwsA(isA<SqliteException>()));
        again.dispose();
      }
      // Not even with query_only switched off: the open mode is the boundary.
      db.execute('PRAGMA query_only = OFF;');
      expect(() => db.execute('DELETE FROM t;'),
          throwsA(isA<SqliteException>()));
      expect(rows(db), ['known']);
      db.dispose();
    });

    test('never creates a missing file, whatever the caller asks for',
        () async {
      final resolver =
          databaseResolver(missing, createFile: false, readOnly: true);
      await expectLater(() async => await resolver(),
          throwsA(isA<FileSystemException>()));
      const direct = ExistingOnlySqlite3(sqlite3, mode: OpenMode.readOnly);
      expect(() => direct.open(missing, mode: OpenMode.readWriteCreate),
          throwsA(isA<SqliteException>()));
      expect(File(missing).existsSync(), isFalse);
      expect(dir.listSync().map((e) => p.basename(e.path)),
          ['existing.sqlite']);
    });
  });

  group('existing-only (normal) resolver', () {
    test('a caller asking to create cannot create a missing database',
        () async {
      final resolver = databaseResolver(missing, createFile: false);
      await expectLater(() async => await resolver(),
          throwsA(isA<FileSystemException>()));
      const direct = ExistingOnlySqlite3(sqlite3);
      expect(() => direct.open(missing, mode: OpenMode.readWriteCreate),
          throwsA(isA<SqliteException>()));
      expect(File(missing).existsSync(), isFalse);
    });

    test('still opens an existing database for writing', () async {
      final resolved = await databaseResolver(existing, createFile: false)();
      final db = resolved.open(existing, mode: OpenMode.readWriteCreate);
      db.execute("INSERT INTO t VALUES ('y');");
      expect(rows(db), ['known', 'y']);
      db.dispose();
    });
  });

  test('a creating resolver is the stock bindings', () async {
    final resolved = await databaseResolver(missing, createFile: true)();
    expect(identical(resolved, sqlite3), isTrue);
  });
}
