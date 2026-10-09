// `package:sqlite3` is a transitive dependency (through drift) whose
// `OpenMode.readWrite` is the only way to open a database that must NOT be
// created; drift's own `NativeDatabase` always calls `sqlite3.open(path)`, whose
// default mode is `readWriteCreate`. Adding it to pubspec would change the
// dependency set, which this change does not do.
// ignore_for_file: depend_on_referenced_packages

import 'dart:ffi';
import 'dart:io';

import 'package:drift/native.dart' show SqliteResolver;
import 'package:sqlite3/sqlite3.dart';

/// F2 — a [Sqlite3] that can only open databases that ALREADY EXIST.
///
/// `NativeDatabase` creates the parent directory and calls `sqlite3.open(path)`
/// with the creation-capable default mode. A secondary or launch open that raced
/// the deletion of its replica would therefore silently create a fresh, empty
/// database (and its directory) after Remove data. This wrapper opens in
/// [OpenMode.readWrite], which SQLite refuses for a missing file, so the open
/// cannot create anything.
class ExistingOnlySqlite3 implements Sqlite3 {
  const ExistingOnlySqlite3(this._inner);
  final Sqlite3 _inner;

  @override
  Database open(
    String filename, {
    String? vfs,
    OpenMode mode = OpenMode.readWriteCreate,
    bool uri = false,
    bool? mutex,
  }) => _inner.open(
    filename,
    vfs: vfs,
    mode: OpenMode.readWrite,
    uri: uri,
    mutex: mutex,
  );

  @override
  Database openInMemory({String? vfs}) => _inner.openInMemory(vfs: vfs);

  @override
  Version get version => _inner.version;

  @override
  String? get tempDirectory => _inner.tempDirectory;

  @override
  set tempDirectory(String? value) => _inner.tempDirectory = value;

  @override
  Database fromPointer(Pointer<void> database, {bool borrowed = false}) =>
      _inner.fromPointer(database, borrowed: borrowed);

  @override
  Database copyIntoMemory(Database restoreFrom) =>
      _inner.copyIntoMemory(restoreFrom);

  @override
  void ensureExtensionLoaded(SqliteExtension extension) =>
      _inner.ensureExtensionLoaded(extension);

  @override
  bool usedCompileOption(String name) => _inner.usedCompileOption(name);

  @override
  Iterable<String> get compileOptions => _inner.compileOptions;

  @override
  void registerVirtualFileSystem(
    VirtualFileSystem vfs, {
    bool makeDefault = false,
  }) => _inner.registerVirtualFileSystem(vfs, makeDefault: makeDefault);

  @override
  void unregisterVirtualFileSystem(VirtualFileSystem vfs) =>
      _inner.unregisterVirtualFileSystem(vfs);
}

/// The resolver handed to `NativeDatabase` for the database at [path].
///
/// A creating open gets the stock bindings. An existing-only open gets
/// [ExistingOnlySqlite3], and the resolver itself runs in the database's own
/// isolate immediately before drift would create the parent directory, so a file
/// that vanished since the caller's existence check makes the open FAIL there,
/// before any directory exists.
SqliteResolver databaseResolver(String path, {required bool createFile}) {
  if (createFile) return () => sqlite3;
  return () {
    if (!File(path).existsSync()) {
      throw const FileSystemException('database does not exist');
    }
    return const ExistingOnlySqlite3(sqlite3);
  };
}
