import 'dart:io';

// MALI-069n (Batch-4 closure) — a CROSS-ISOLATE (and cross-process) database-use
// lease. Dart's RandomAccessFile.lock uses POSIX fcntl record locks, which are
// PER-PROCESS and therefore DO NOT coordinate isolates within one process (the
// two production secondary paths run as background isolates in the app process).
// So the lease is built on the file system instead, which every isolate/process
// sees identically:
//   * an ATOMIC maintenance-intent marker (File.create(exclusive:true) = O_EXCL)
//     — while it exists, NEW shared leases are refused (writer-starvation-safe);
//   * a REGISTRY of per-secondary lease files (each atomically created on
//     acquire, deleted in `finally` on release) — file-exclusive maintenance
//     bounded-waits until the registry is empty before proceeding;
//   * STALE recovery by bounded age, so a crashed holder can never permanently
//     block database access (a killed isolate/process leaves its file behind).
// The marker + lease files contain only a timestamp — no user, financial, path,
// or key information.

/// A held database-use lease. Always release() it in a `finally`.
class DatabaseFileLease {
  DatabaseFileLease._(this._path, this.isExclusive, this._onRelease);

  final String _path;
  final bool isExclusive;
  final Future<void> Function()? _onRelease;
  bool _released = false;

  Future<void> release() async {
    if (_released) return;
    _released = true;
    try {
      final f = File(_path);
      if (await f.exists()) await f.delete();
    } catch (_) {}
    final onRelease = _onRelease;
    if (onRelease != null) await onRelease();
  }
}

/// Thrown when a lease cannot be acquired within the bounded window.
class DatabaseLeaseUnavailable implements Exception {
  const DatabaseLeaseUnavailable(this.reason);

  /// 'maintenance_in_progress' | 'timeout' — no secrets.
  final String reason;

  @override
  String toString() => 'DatabaseLeaseUnavailable($reason)';
}

class DatabaseLeaseManager {
  DatabaseLeaseManager({
    required this.leaseDir,
    required this.intentPath,
    this.staleAge = const Duration(minutes: 2),
  });

  /// A directory holding one file per active shared lease.
  final String leaseDir;

  /// The maintenance-intent marker path.
  final String intentPath;

  /// A lease/intent file older than this is treated as stale (its holder
  /// crashed) and never permanently blocks database access.
  final Duration staleAge;

  static const Duration _retryStep = Duration(milliseconds: 25);
  int _seq = 0;

  bool _isRecent(FileSystemEntity entity) {
    try {
      final stat = entity.statSync();
      return DateTime.now().difference(stat.modified) <= staleAge;
    } catch (_) {
      return false;
    }
  }

  /// True while a NON-STALE maintenance intent exists. A stale marker is removed.
  bool _maintenanceIntentActive() {
    final f = File(intentPath);
    if (!f.existsSync()) return false;
    if (_isRecent(f)) return true;
    try {
      f.deleteSync(); // stale — recover
    } catch (_) {}
    return false;
  }

  /// Non-stale active shared leases in the registry (stale files are removed).
  int _activeLeaseCount() {
    final d = Directory(leaseDir);
    if (!d.existsSync()) return 0;
    var count = 0;
    for (final e in d.listSync()) {
      if (e is! File || !e.path.endsWith('.lease')) continue;
      if (_isRecent(e)) {
        count++;
      } else {
        try {
          e.deleteSync();
        } catch (_) {}
      }
    }
    return count;
  }

  /// Acquire a SHARED database-use lease (a normal main/secondary user). Refused
  /// immediately when file-exclusive maintenance intent is active; the lease is
  /// registered so maintenance waits for it, and MUST be released in a `finally`.
  Future<DatabaseFileLease> acquireShared() async {
    if (_maintenanceIntentActive()) {
      throw const DatabaseLeaseUnavailable('maintenance_in_progress');
    }
    Directory(leaseDir).createSync(recursive: true);
    final path = '$leaseDir/${pid}_${_seq++}_${DateTime.now().microsecondsSinceEpoch}.lease';
    final file = File(path);
    await file.writeAsString(DateTime.now().toUtc().toIso8601String(),
        flush: true);
    // Re-check AFTER registering: if maintenance started meanwhile, back off so a
    // secondary never proceeds concurrently with file-exclusive maintenance.
    if (_maintenanceIntentActive()) {
      try {
        await file.delete();
      } catch (_) {}
      throw const DatabaseLeaseUnavailable('maintenance_in_progress');
    }
    return DatabaseFileLease._(path, false, null);
  }

  /// Acquire an EXCLUSIVE (file-level) maintenance lease. Atomically publishes
  /// the intent marker (so NEW shared leases are refused), then bounded-waits for
  /// existing shared leases to drain. Releasing the returned lease removes the
  /// intent marker.
  Future<DatabaseFileLease> acquireExclusive({
    Duration timeout = const Duration(seconds: 10),
  }) async {
    await _publishIntent(timeout);
    final deadline = DateTime.now().add(timeout);
    try {
      while (_activeLeaseCount() > 0) {
        if (DateTime.now().isAfter(deadline)) {
          await _clearIntent();
          throw const DatabaseLeaseUnavailable('timeout');
        }
        await Future<void>.delayed(_retryStep);
      }
      return DatabaseFileLease._(intentPath, true, _clearIntent);
    } catch (_) {
      await _clearIntent();
      rethrow;
    }
  }

  Future<void> _publishIntent(Duration timeout) async {
    final f = File(intentPath);
    final deadline = DateTime.now().add(timeout);
    while (true) {
      try {
        // Atomic O_EXCL create — fails if another (recent) maintainer holds it.
        await f.create(exclusive: true);
        await f.writeAsString(DateTime.now().toUtc().toIso8601String(),
            flush: true);
        return;
      } on FileSystemException {
        if (!_maintenanceIntentActive()) {
          // The existing marker was stale and got recovered — retry the create.
          continue;
        }
        if (DateTime.now().isAfter(deadline)) {
          throw const DatabaseLeaseUnavailable('timeout');
        }
        await Future<void>.delayed(_retryStep);
      }
    }
  }

  Future<void> _clearIntent() async {
    try {
      final f = File(intentPath);
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }
}
