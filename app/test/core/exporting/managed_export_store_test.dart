// MALI-065n — behavioral tests for the managed temp-export lifecycle.
//
// These drive a real on-disk directory (an isolated systemTemp dir per test)
// through the actual store: write, dispose, and sweep, asserting file-system
// state — not source shape.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/exporting/export_file_protector.dart';
import 'package:money_companion/core/exporting/managed_export_store.dart';

class _SpyProtector implements ExportFileProtector {
  final List<String> protected = <String>[];
  @override
  Future<void> protect(String path) async => protected.add(path);
}

void main() {
  late Directory base;

  setUp(() async {
    base = await Directory.systemTemp.createTemp('mali_export_test');
  });
  tearDown(() async {
    if (await base.exists()) await base.delete(recursive: true);
  });

  ManagedExportStore storeWith({
    _SpyProtector? protector,
    int idSeed = 0,
    DateTime? clock,
  }) {
    var n = idSeed;
    return ManagedExportStore(
      baseDirectory: () async => base,
      protector: protector ?? _SpyProtector(),
      idGenerator: () => 'id${n++}',
      clock: () => clock ?? DateTime(2026, 8, 5, 12),
    );
  }

  Directory managedDir() => Directory('${base.path}/mali_exports');

  test('writes an opaque on-disk name that carries no share-name data', () async {
    final store = storeWith();
    final export = await store.writeString(
      'amount,merchant\n512.34,StarbucksRiyadh',
      // A friendly name deliberately full of "financial" words:
      shareName: 'Qirsh-512.34-StarbucksRiyadh.csv',
      extension: 'csv',
      mimeType: 'text/csv',
    );

    final onDisk = export.file.uri.pathSegments.last;
    expect(onDisk, 'id0.csv');
    expect(onDisk.contains('512.34'), isFalse);
    expect(onDisk.contains('Starbucks'), isFalse);
    expect(await export.file.exists(), isTrue);
    // The friendly name is retained on the handle for the share sheet only.
    expect(export.shareName, 'Qirsh-512.34-StarbucksRiyadh.csv');
    // Sidecar written with a creation timestamp.
    final meta = File('${managedDir().path}/id0.meta.json');
    expect(await meta.exists(), isTrue);
    expect(jsonDecode(await meta.readAsString())['createdAtMs'], isA<int>());
  });

  test('applies platform protection to both payload and sidecar', () async {
    final spy = _SpyProtector();
    final store = storeWith(protector: spy);
    final export = await store.writeBytes(
      Uint8List.fromList(<int>[1, 2, 3]),
      shareName: 'r.pdf',
      extension: 'pdf',
      mimeType: 'application/pdf',
    );
    expect(spy.protected, contains(export.file.path));
    expect(spy.protected, contains('${managedDir().path}/id0.meta.json'));
  });

  test('dispose removes file + sidecar and is idempotent (success/cancel/fail)',
      () async {
    final store = storeWith();
    final export = await store.writeString('x',
        shareName: 'r.csv', extension: 'csv', mimeType: 'text/csv');
    final meta = File('${managedDir().path}/id0.meta.json');
    expect(await export.file.exists(), isTrue);

    await store.dispose(export);
    expect(await export.file.exists(), isFalse);
    expect(await meta.exists(), isFalse);

    // Idempotent: a second dispose (e.g. sweep already reclaimed it) is a no-op.
    await store.dispose(export);
    expect(await export.file.exists(), isFalse);
  });

  test('concurrent exports get distinct ids and dispose independently',
      () async {
    final store = storeWith();
    final results = await Future.wait<ManagedExport>(<Future<ManagedExport>>[
      store.writeString('a',
          shareName: 'a.csv', extension: 'csv', mimeType: 'text/csv'),
      store.writeString('b',
          shareName: 'b.csv', extension: 'csv', mimeType: 'text/csv'),
    ]);
    expect(results[0].id, isNot(results[1].id));
    expect(await results[0].file.exists(), isTrue);
    expect(await results[1].file.exists(), isTrue);

    await store.dispose(results[0]);
    expect(await results[0].file.exists(), isFalse);
    expect(await results[1].file.exists(), isTrue); // sibling untouched
  });

  test('startup sweep (olderThan null) reclaims every orphan', () async {
    final store = storeWith();
    await store.writeString('a',
        shareName: 'a.csv', extension: 'csv', mimeType: 'text/csv');
    await store.writeString('b',
        shareName: 'b.pdf', extension: 'pdf', mimeType: 'application/pdf');

    final deleted = await store.sweep(); // olderThan null → delete all
    expect(deleted, 2);
    expect(managedDir().listSync(), isEmpty);
  });

  test('resume sweep respects the lease: old reclaimed, fresh kept', () async {
    final spy = _SpyProtector();
    // Written "yesterday" — its sidecar records an old createdAt.
    final oldStore = ManagedExportStore(
      baseDirectory: () async => base,
      protector: spy,
      idGenerator: () => 'old',
      clock: () => DateTime(2026, 8, 4, 12),
    );
    await oldStore.writeString('old',
        shareName: 'o.csv', extension: 'csv', mimeType: 'text/csv');

    // A fresh export written "now".
    final now = DateTime(2026, 8, 5, 12);
    final store = ManagedExportStore(
      baseDirectory: () async => base,
      protector: spy,
      idGenerator: () => 'fresh',
      clock: () => now,
    );
    await store.writeString('fresh',
        shareName: 'f.csv', extension: 'csv', mimeType: 'text/csv');

    final deleted = await store.sweep(olderThan: const Duration(hours: 6));
    expect(deleted, 1);
    expect(await File('${managedDir().path}/old.csv').exists(), isFalse);
    expect(await File('${managedDir().path}/fresh.csv').exists(), isTrue);
  });

  test('sweep tolerates corrupt metadata and still reclaims the payload',
      () async {
    final store = storeWith();
    await store.writeString('x',
        shareName: 'r.csv', extension: 'csv', mimeType: 'text/csv');
    // Corrupt the sidecar.
    await File('${managedDir().path}/id0.meta.json')
        .writeAsString('{ this is not json ');

    // Even with a lease, a corrupt sidecar is treated as very old → reclaimed.
    final deleted = await store.sweep(olderThan: const Duration(hours: 6));
    expect(deleted, 1);
    expect(await File('${managedDir().path}/id0.csv').exists(), isFalse);
  });

  test('sweep removes an orphaned sidecar whose payload is gone', () async {
    await managedDir().create(recursive: true);
    final orphan = File('${managedDir().path}/ghost.meta.json');
    await orphan.writeAsString('{"id":"ghost","createdAtMs":0}');

    await storeWith().sweep(olderThan: const Duration(hours: 6));
    expect(await orphan.exists(), isFalse);
  });

  test('sweep on a never-used store is a no-op', () async {
    expect(await storeWith().sweep(), 0);
  });
}
