// MALI-065n — one managed lifecycle for every temporary export file.
//
// Reports (PDF), CSV exports, and the full-data portability package all wrote
// their own ad-hoc temp files with their own (inconsistent) cleanup. This is
// the single owner of that lifecycle:
//
//   * files live in a dedicated PRIVATE subdirectory of the app temp area,
//   * on-disk names are OPAQUE ids — never a period, amount, merchant or any
//     other financial datum (the user-facing share name is carried separately),
//   * each file gets platform file-protection + backup-exclusion applied,
//   * a sidecar `.meta.json` records the opaque id + creation time,
//   * [dispose] deletes the file + sidecar on success, cancel AND failure
//     (idempotent, with a small retry), and
//   * [sweep] reclaims orphans — on startup (delete everything left behind) and
//     on resume (delete anything older than a bounded lease), tolerating corrupt
//     metadata and racing deletes.
//
// SHARE SUCCESS-VS-CANCEL LIMITATION (documented, not hidden): the platform
// share sheet does not reliably tell us whether the user completed or cancelled
// a share. We therefore always [dispose] once the share future settles — the
// file has done its job the moment the sheet closes — and the bounded-lease
// [sweep] is the backstop for the case where the process is killed mid-share
// and [dispose] never runs.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import '../utils/id_generator.dart';
import 'export_file_protector.dart';

/// A handle to a managed export file. [file] has an opaque on-disk name;
/// [shareName] is the friendly, data-free name to present in the share sheet.
class ManagedExport {
  const ManagedExport({
    required this.id,
    required this.file,
    required this.shareName,
    required this.mimeType,
  });

  final String id;
  final File file;
  final String shareName;
  final String mimeType;
}

class ManagedExportStore {
  ManagedExportStore({
    Future<Directory> Function()? baseDirectory,
    ExportFileProtector? protector,
    String Function()? idGenerator,
    DateTime Function()? clock,
  })  : _baseDirectory = baseDirectory ?? getTemporaryDirectory,
        _protector = protector ?? const PlatformExportFileProtector(),
        _idGenerator = idGenerator ?? IdGenerator.uuidV4,
        _clock = clock ?? DateTime.now;

  final Future<Directory> Function() _baseDirectory;
  final ExportFileProtector _protector;
  final String Function() _idGenerator;
  final DateTime Function() _clock;

  static const String _dirName = 'mali_exports';
  static const String _metaSuffix = '.meta.json';
  static const int _deleteRetries = 3;

  /// Default cleanup lease used by the resume sweep.
  static const Duration defaultLease = Duration(hours: 6);

  Future<Directory> _managedDir() async {
    final base = await _baseDirectory();
    final dir = Directory('${base.path}/$_dirName');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// Writes [bytes] to a fresh managed file and returns its handle. [shareName]
  /// is the friendly name for the share sheet; [extension] and [mimeType]
  /// describe the payload. Callers MUST keep [shareName] free of financial data.
  Future<ManagedExport> writeBytes(
    Uint8List bytes, {
    required String shareName,
    required String extension,
    required String mimeType,
  }) async {
    final dir = await _managedDir();
    final id = _idGenerator();
    final ext = _safeExtension(extension);
    final file = File('${dir.path}/$id.$ext');
    await file.writeAsBytes(bytes, flush: true);
    await _protector.protect(file.path);

    final meta = File('${dir.path}/$id$_metaSuffix');
    await meta.writeAsString(
      jsonEncode(<String, Object?>{
        'id': id,
        'createdAtMs': _clock().millisecondsSinceEpoch,
        'ext': ext,
      }),
      flush: true,
    );
    await _protector.protect(meta.path);

    return ManagedExport(
      id: id,
      file: file,
      shareName: shareName,
      mimeType: mimeType,
    );
  }

  /// Convenience for text payloads (CSV/JSON). UTF-8 encoded.
  Future<ManagedExport> writeString(
    String content, {
    required String shareName,
    required String extension,
    required String mimeType,
  }) {
    return writeBytes(
      Uint8List.fromList(utf8.encode(content)),
      shareName: shareName,
      extension: extension,
      mimeType: mimeType,
    );
  }

  /// Deletes an export's file + sidecar. Idempotent and never throws — safe to
  /// call in a `finally` on success, cancel, or failure.
  Future<void> dispose(ManagedExport export) async {
    await _deleteWithRetry(export.file);
    final dir = export.file.parent;
    await _deleteWithRetry(File('${dir.path}/${export.id}$_metaSuffix'));
  }

  /// Reclaims orphaned managed files. With [olderThan] null (startup), deletes
  /// EVERYTHING left in the managed dir — on a fresh process no share can be in
  /// flight, so any survivor is an orphan. With [olderThan] set (resume),
  /// deletes only files past the lease so an in-flight share is never killed.
  /// Returns the number of payload files deleted. Never throws.
  Future<int> sweep({Duration? olderThan}) async {
    try {
      final base = await _baseDirectory();
      final dir = Directory('${base.path}/$_dirName');
      if (!await dir.exists()) return 0;

      final entities = await dir.list().toList();
      final files = entities.whereType<File>().toList();
      final now = _clock();
      var deleted = 0;

      for (final file in files) {
        final name = file.uri.pathSegments.last;
        if (name.endsWith(_metaSuffix)) continue; // handled with its payload
        final id = _idOf(name);
        final meta = File('${dir.path}/$id$_metaSuffix');
        final stale = olderThan == null ||
            now.difference(await _createdAt(file, meta)) >= olderThan;
        if (stale) {
          if (await _deleteWithRetry(file)) deleted++;
          await _deleteWithRetry(meta);
        }
      }

      // Sidecars whose payload never existed in this listing are pure orphans.
      final payloadIds = files
          .map((f) => f.uri.pathSegments.last)
          .where((n) => !n.endsWith(_metaSuffix))
          .map(_idOf)
          .toSet();
      for (final file in files) {
        final name = file.uri.pathSegments.last;
        if (!name.endsWith(_metaSuffix)) continue;
        final id = name.substring(0, name.length - _metaSuffix.length);
        if (!payloadIds.contains(id)) await _deleteWithRetry(file);
      }
      return deleted;
    } catch (_) {
      return 0; // sweeping is best-effort
    }
  }

  static String _idOf(String fileName) {
    final dot = fileName.lastIndexOf('.');
    return dot < 0 ? fileName : fileName.substring(0, dot);
  }

  static String _safeExtension(String extension) {
    final cleaned =
        extension.replaceAll(RegExp(r'[^A-Za-z0-9]'), '').toLowerCase();
    return cleaned.isEmpty ? 'bin' : cleaned;
  }

  /// Creation time used by the lease. A valid sidecar wins; a sidecar that is
  /// PRESENT but corrupt/unreadable is treated as epoch-0 ("very old") so a
  /// leased sweep still reclaims it. Only an ABSENT sidecar falls back to the
  /// payload's mtime (a payload orphaned before its sidecar was written).
  Future<DateTime> _createdAt(File payload, File meta) async {
    if (await meta.exists()) {
      try {
        final decoded = jsonDecode(await meta.readAsString());
        if (decoded is Map && decoded['createdAtMs'] is int) {
          return DateTime.fromMillisecondsSinceEpoch(
              decoded['createdAtMs'] as int);
        }
      } catch (_) {
        // corrupt sidecar → fall through to "very old"
      }
      return DateTime.fromMillisecondsSinceEpoch(0);
    }
    try {
      return (await payload.stat()).modified;
    } catch (_) {
      return DateTime.fromMillisecondsSinceEpoch(0);
    }
  }

  Future<bool> _deleteWithRetry(File file) async {
    for (var attempt = 0; attempt < _deleteRetries; attempt++) {
      try {
        if (!await file.exists()) return false;
        await file.delete();
        return true;
      } catch (_) {
        if (attempt == _deleteRetries - 1) return false;
      }
    }
    return false;
  }
}
