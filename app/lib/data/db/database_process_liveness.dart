import 'dart:io';
import 'dart:math';

// MALI-069n (Batch-4 closure #4) — Contract B process liveness.
//
// Inventory (see docs/PROCESS_ACCESS_INVENTORY.md) proves exactly ONE OS process
// (the Flutter host app) ever opens the Drift/SQLCipher database; every separate-
// process target (iOS Share extension, App Intents, Android receivers) is pure-
// native and only stages to the App Group / SharedPreferences. So the liveness
// authority is not a heartbeat — it is a PROCESS-LIFETIME OS ADVISORY LOCK:
//
//   * Each process instance holds an OS advisory exclusive lock (POSIX fcntl, via
//     RandomAccessFile.lock) on a single lock file, taken at startup and RETAINED
//     for the whole process lifetime (the fd is never closed). The OS releases it
//     automatically when the process dies — even on SIGKILL — so a later process
//     start can detect that the previous instance ended.
//
//   * A random instance token identifies this process instance (combined with the
//     OS pid, which is unique among LIVE processes). It contains no user or
//     financial data.
//
// Acquiring the exclusive lock at startup is the ONLY authority that permits
// clearing another instance's leftover lease/intent records. Nothing time-based
// ever authorizes deletion.

/// A held process-liveness handle. Retain it for the process lifetime; the OS
/// releases the underlying advisory lock when this process exits.
class ProcessLivenessHandle {
  ProcessLivenessHandle._(this.instanceToken, this.ownerPid, this._lockFile,
      {required this.acquiredExclusive});

  /// Random per-process-instance identity. No user/financial content.
  final String instanceToken;

  /// The OS pid that owns this instance (unique among currently-live processes).
  final int ownerPid;

  /// True when THIS process acquired the exclusive advisory lock — proof that no
  /// other process was holding it, so leftover records from ended instances may be
  /// recovered. False means another live opener exists (must not recover).
  final bool acquiredExclusive;

  // Retained so the OS keeps the advisory lock until the process dies. Never
  // closed on purpose in production.
  final RandomAccessFile? _lockFile;

  /// Test-only: release the advisory lock + close the fd (production never does
  /// this — the OS releases on process exit). Lets a test free the lock between
  /// cases without leaking file descriptors.
  void debugReleaseForTest() {
    try {
      _lockFile?.unlockSync();
    } catch (_) {}
    try {
      _lockFile?.closeSync();
    } catch (_) {}
  }
}

class DatabaseProcessLiveness {
  DatabaseProcessLiveness({required this.lockPath, required this.instancePath});

  /// The single OS advisory-lock file for the process instance.
  final String lockPath;

  /// A record file holding `<pid>:<instanceToken>` for diagnostics/discovery.
  final String instancePath;

  static final Random _rng = Random.secure();

  static String _newInstanceToken() {
    final bytes = List<int>.generate(16, (_) => _rng.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  /// Acquire process liveness for THIS process. Takes the OS advisory exclusive
  /// lock (non-blocking) and retains it for the process lifetime. Writes the
  /// instance record. If the lock is already held by ANOTHER live process,
  /// [ProcessLivenessHandle.acquiredExclusive] is false and the caller must NOT
  /// perform destructive recovery.
  ProcessLivenessHandle acquire() {
    final token = _newInstanceToken();
    File(lockPath).parent.createSync(recursive: true);
    RandomAccessFile? raf;
    var exclusive = false;
    try {
      raf = File(lockPath).openSync(mode: FileMode.write);
      // FileLock.exclusive is NON-blocking on Dart: it throws if another process
      // holds the lock, rather than waiting.
      raf.lockSync(FileLock.exclusive);
      exclusive = true;
    } on FileSystemException {
      // Another live process holds the lock. Keep going without exclusivity: the
      // DB still opens; only destructive recovery is withheld.
      exclusive = false;
      try {
        raf?.closeSync();
      } catch (_) {}
      raf = null;
    }
    // Best-effort discovery record (never authoritative for deletion).
    try {
      File(instancePath).writeAsStringSync('$pid:$token');
    } catch (_) {}
    return ProcessLivenessHandle._(token, pid, raf, acquiredExclusive: exclusive);
  }
}
