import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// ASR design v7.2 §6.4–§6.6 — the small durable files next to the session item
/// (Application Support): the removal fence map, the install marker and the
/// migration marker.
///
/// Reads preserve their status class: a file that exists but cannot be read
/// (protected data unavailable) is [FileStatus.unavailable], never absent; a file
/// that cannot be parsed is [FileStatus.malformed]. Writes go temp → flush →
/// rename → read-back, and report success only when the read-back matches.
enum FileStatus { found, absent, unavailable, malformed }

@immutable
class FileRead<T> {
  const FileRead(this.status, [this.value]);
  final FileStatus status;
  final T? value;

  bool get isFound => status == FileStatus.found;
  bool get isAbsent => status == FileStatus.absent;
}

class DurableJsonFile {
  DurableJsonFile(this.file);

  final File file;

  Future<FileRead<Map<String, Object?>>> read() async {
    try {
      if (!await file.exists()) return const FileRead(FileStatus.absent);
    } catch (_) {
      return const FileRead(FileStatus.unavailable);
    }
    final String raw;
    try {
      raw = await file.readAsString();
    } on PathNotFoundException {
      return const FileRead(FileStatus.absent);
    } catch (_) {
      return const FileRead(FileStatus.unavailable);
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return const FileRead(FileStatus.malformed);
      return FileRead(FileStatus.found, Map<String, Object?>.from(decoded));
    } catch (_) {
      return const FileRead(FileStatus.malformed);
    }
  }

  /// True only when the rename succeeded and the read-back equals [value].
  Future<bool> writeVerified(Map<String, Object?> value) async {
    final encoded = jsonEncode(value);
    final tmp = File('${file.path}.tmp');
    try {
      await file.parent.create(recursive: true);
      await tmp.writeAsString(encoded, flush: true);
      await tmp.rename(file.path);
    } catch (_) {
      return false;
    }
    final back = await read();
    return back.isFound && jsonEncode(back.value) == encoded;
  }

  /// True only when the file is verified absent afterwards.
  Future<bool> deleteVerified() async {
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {
      return false;
    }
    return (await read()).isAbsent;
  }
}

/// §6.4-2: `{ns: {installId, removedThroughSeq, lifecycleFloor}}`. Updating one
/// namespace never drops another.
@immutable
class FenceEntry {
  const FenceEntry({
    required this.installId,
    required this.removedThroughSeq,
    required this.lifecycleFloor,
  });
  final String installId;
  final int removedThroughSeq;
  final int lifecycleFloor;

  Map<String, Object?> toJson() => {
        'installId': installId,
        'removedThroughSeq': removedThroughSeq,
        'lifecycleFloor': lifecycleFloor,
      };

  static FenceEntry? tryParse(Object? j) {
    if (j is! Map) return null;
    final id = j['installId'];
    final s = j['removedThroughSeq'];
    final l = j['lifecycleFloor'];
    if (id is! String || s is! int || l is! int || j.length != 3) return null;
    return FenceEntry(installId: id, removedThroughSeq: s, lifecycleFloor: l);
  }
}

/// §6.6: `{ns: {state: importing|done, legacyCleanup: pending|done}}`.
enum MigrationState { importing, done }

enum LegacyCleanup { pending, done }

@immutable
class MigrationEntry {
  const MigrationEntry({required this.state, required this.legacyCleanup});
  final MigrationState state;
  final LegacyCleanup legacyCleanup;

  Map<String, Object?> toJson() =>
      {'state': state.name, 'legacyCleanup': legacyCleanup.name};

  static MigrationEntry? tryParse(Object? j) {
    if (j is! Map || j.length != 2) return null;
    MigrationState? s;
    LegacyCleanup? c;
    for (final v in MigrationState.values) {
      if (v.name == j['state']) s = v;
    }
    for (final v in LegacyCleanup.values) {
      if (v.name == j['legacyCleanup']) c = v;
    }
    if (s == null || c == null) return null;
    return MigrationEntry(state: s, legacyCleanup: c);
  }
}

/// Typed access to the three files under one directory.
class SessionFiles {
  SessionFiles(Directory dir)
      : fence = DurableJsonFile(File('${dir.path}/session_fence.v1')),
        installMarker = DurableJsonFile(File('${dir.path}/install_marker.v1')),
        migration = DurableJsonFile(File('${dir.path}/session_migration.v1'));

  final DurableJsonFile fence;
  final DurableJsonFile installMarker;
  final DurableJsonFile migration;

  /// A malformed map, or a malformed entry, is reported as malformed.
  static FileRead<Map<String, T>> typedMap<T>(
      FileRead<Map<String, Object?>> raw, T? Function(Object?) parse) {
    if (!raw.isFound) return FileRead(raw.status);
    final out = <String, T>{};
    for (final e in raw.value!.entries) {
      final v = parse(e.value);
      if (v == null) return const FileRead(FileStatus.malformed);
      out[e.key] = v;
    }
    return FileRead(FileStatus.found, out);
  }

  Future<FileRead<Map<String, FenceEntry>>> readFence() async =>
      typedMap(await fence.read(), FenceEntry.tryParse);

  Future<bool> writeFenceEntry(
      Map<String, FenceEntry> current, String ns, FenceEntry entry) {
    final next = {for (final e in current.entries) e.key: e.value.toJson()}
      ..[ns] = entry.toJson();
    return fence.writeVerified(next);
  }

  Future<FileRead<Map<String, MigrationEntry>>> readMigration() async =>
      typedMap(await migration.read(), MigrationEntry.tryParse);

  Future<bool> writeMigrationEntry(
      Map<String, MigrationEntry> current, String ns, MigrationEntry entry) {
    final next = {for (final e in current.entries) e.key: e.value.toJson()}
      ..[ns] = entry.toJson();
    return migration.writeVerified(next);
  }

  /// `{installId}`; malformed when the shape is anything else.
  Future<FileRead<String>> readInstallMarker() async {
    final raw = await installMarker.read();
    if (!raw.isFound) return FileRead(raw.status);
    final id = raw.value!['installId'];
    if (id is! String || id.isEmpty || raw.value!.length != 1) {
      return const FileRead(FileStatus.malformed);
    }
    return FileRead(FileStatus.found, id);
  }

  Future<bool> writeInstallMarker(String installId) =>
      installMarker.writeVerified({'installId': installId});
}
