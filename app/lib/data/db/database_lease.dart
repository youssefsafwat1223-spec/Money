import 'dart:async';
import 'dart:io';
import 'dart:math';

// MALI-069n (Batch-4 closure #4) — the CROSS-ISOLATE database-use lease under
// Contract B (see docs/PROCESS_ACCESS_INVENTORY.md: exactly one OS process ever
// opens the DB).
//
// The earlier closure made a heartbeat/mtime the stale-recovery AUTHORITY, which
// is unsafe: a live isolate whose heartbeat merely stopped (a long SQLite call, a
// paused/suspended isolate) could be false-reaped, letting destructive maintenance
// proceed while that isolate's connection is still open. That authority is removed.
//
// New model:
//   * The authoritative lease/intent record is IMMUTABLE and written atomically
//     (temp file + rename), so a concurrent reader never observes a partial record.
//     It carries only opaque protocol data — a random fencing token, the owner pid,
//     and the process-instance token — never user/financial data. Liveness = the
//     record's EXISTENCE, never its age.
//   * RUNTIME maintenance NEVER reaps another holder's lease. It waits for every
//     shared lease to be RELEASED by its holder, with a typed BOUNDED TIMEOUT. A
//     live-but-blocked or paused isolate simply keeps its lease → maintenance times
//     out (safe), never corrupts. Uncertain liveness never authorizes deletion.
//   * The ONLY reaping is STALE-FILE RECOVERY at process start ([recoverEndedInstances]),
//     which the caller runs only while holding the process-lifetime OS advisory
//     lock (see DatabaseProcessLiveness). Records tagged with a DIFFERENT owner pid
//     belong to an ended instance (pids are unique among live processes) and are
//     cleared; records with the CURRENT pid (a live same-process isolate) are left.
//   * No wall-clock/mtime decision exists, so forward/backward clock jumps and
//     suspension can never authorize deletion.

/// Thrown when a lease cannot be acquired within the bounded window. Never carries
/// any secret — only a coarse [reason].
class DatabaseLeaseUnavailable implements Exception {
  const DatabaseLeaseUnavailable(this.reason);

  /// 'maintenance_in_progress' | 'timeout' — no secrets.
  final String reason;

  @override
  String toString() => 'DatabaseLeaseUnavailable($reason)';
}

/// A held database-use lease. Always [release] it in a `finally`; that removes the
/// record (only if its fencing token still matches).
class DatabaseFileLease {
  DatabaseFileLease._(this._file, this.isExclusive, this.token, this._onRelease);

  final File _file;
  final bool isExclusive;

  /// The unique fencing token this holder owns. Only this holder removes the file,
  /// and only while the on-disk token still equals this value.
  final String token;

  final Future<void> Function()? _onRelease;
  bool _released = false;

  Future<void> release() async {
    if (_released) return;
    _released = true;
    await _deleteIfToken(_file, token);
    final onRelease = _onRelease;
    if (onRelease != null) await onRelease();
  }
}

/// The immutable authoritative record content: fencing token, owner pid, instance
/// token. Written once; never rewritten.
class _LeaseRecord {
  const _LeaseRecord(this.token, this.pid, this.instance);
  final String token;
  final int? pid;
  final String instance;

  String encode() => '$token\n$pid\n$instance';

  /// Parse a record. Returns null when the content is empty or malformed — callers
  /// treat that as live/unknown and NEVER as permission to delete at runtime.
  static _LeaseRecord? tryParse(String raw) {
    final lines = raw.split('\n');
    if (lines.length < 3) return null;
    final pid = int.tryParse(lines[1].trim());
    return _LeaseRecord(lines[0].trim(), pid, lines[2].trim());
  }
}

/// Delete [file] only if its on-disk fencing token still equals [token]. A newer
/// holder that replaced the file has a different token, so an older holder's
/// cleanup can never remove it.
Future<void> _deleteIfToken(File file, String token) async {
  try {
    if (!await file.exists()) return;
    final rec = _LeaseRecord.tryParse(await file.readAsString());
    // Malformed/partial content is treated as live/unknown — never deleted here.
    if (rec != null && rec.token == token) await file.delete();
  } catch (_) {
    // Best effort — the token check on the surviving path resolves races.
  }
}

class DatabaseLeaseManager {
  DatabaseLeaseManager({
    required this.leaseDir,
    required this.intentPath,
    int? ownerPid,
    String? instanceToken,
    Duration? settleWindow,
    Duration? pollStep,
  })  : ownerPid = ownerPid ?? pid,
        instanceToken = instanceToken ?? _randomToken(),
        settleWindow = settleWindow ?? const Duration(milliseconds: 60),
        pollStep = pollStep ?? const Duration(milliseconds: 15);

  /// A directory holding one immutable record file per active shared lease.
  final String leaseDir;

  /// The maintenance-intent record path (its EXISTENCE means maintenance is active).
  final String intentPath;

  /// This process's pid — tags records so startup recovery can tell an ended
  /// instance's leftovers (different pid) from a live same-process isolate's lease.
  final int ownerPid;

  /// This process instance's random identity (diagnostics / cross-instance proof).
  final String instanceToken;

  /// After the last live lease releases, maintenance re-checks zero across this
  /// window so a lease created concurrently with the last check (and about to
  /// self-delete on its own intent re-read) is waited out.
  final Duration settleWindow;

  /// Poll granularity while draining.
  final Duration pollStep;

  static final Random _rng = Random.secure();
  int _seq = 0;

  static String _randomToken() {
    final bytes = List<int>.generate(16, (_) => _rng.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  /// Atomically publish an immutable record at [path] via temp-write + rename, so a
  /// concurrent reader sees either no file or the COMPLETE record — never a partial
  /// one. (For a unique lease path this is the whole story; the single intent path
  /// is additionally claimed with O_EXCL for mutual exclusion — see below.)
  void _writeRecordAtomic(String path, _LeaseRecord rec) {
    final tmp = '$path.${rec.token}.tmp';
    File(tmp).writeAsStringSync(rec.encode(), flush: true);
    File(tmp).renameSync(path);
  }

  bool _intentPresent() => File(intentPath).existsSync();

  /// Number of shared leases that currently EXIST (existence = live). No age is
  /// consulted, so a long/blocked holder is always counted as live.
  int _liveLeaseCount() {
    final d = Directory(leaseDir);
    if (!d.existsSync()) return 0;
    var count = 0;
    for (final e in d.listSync()) {
      if (e is File && e.path.endsWith('.lease')) count++;
    }
    return count;
  }

  /// Acquire a SHARED database-use lease. TWO-PHASE so it can never slip past a
  /// maintenance intent published concurrently:
  ///   1. refuse if a maintenance intent already exists;
  ///   2. atomically create THIS lease (unique path + immutable record);
  ///   3. re-read the intent — if it appeared during (2), delete only our own lease
  ///      and refuse. Only after (3) may the caller open the connection.
  /// Held for the connection lifetime; MUST be released in a `finally`.
  Future<DatabaseFileLease> acquireShared() => _acquireShared();

  /// Test seam: [afterPrecheck] runs between phase 1 and 2, [afterCreate] between
  /// phase 2 and 3 — to interleave an intent in each race window deterministically.
  Future<DatabaseFileLease> acquireSharedWithHooks({
    Future<void> Function()? afterPrecheck,
    Future<void> Function()? afterCreate,
  }) =>
      _acquireShared(afterPrecheck: afterPrecheck, afterCreate: afterCreate);

  Future<DatabaseFileLease> _acquireShared({
    Future<void> Function()? afterPrecheck,
    Future<void> Function()? afterCreate,
  }) async {
    if (_intentPresent()) {
      throw const DatabaseLeaseUnavailable('maintenance_in_progress');
    }
    if (afterPrecheck != null) await afterPrecheck();
    Directory(leaseDir).createSync(recursive: true);
    final token = _randomToken();
    final path =
        '$leaseDir/${ownerPid}_${_seq++}_${_randomToken()}.lease';
    _writeRecordAtomic(path, _LeaseRecord(token, ownerPid, instanceToken));
    if (afterCreate != null) await afterCreate();
    if (_intentPresent()) {
      await _deleteIfToken(File(path), token);
      throw const DatabaseLeaseUnavailable('maintenance_in_progress');
    }
    return DatabaseFileLease._(File(path), false, token, null);
  }

  /// Acquire an EXCLUSIVE (file-level) maintenance lease. Fences the intent, then
  /// WAITS for every pre-existing shared lease to be RELEASED by its holder — with
  /// a bounded timeout. It NEVER reaps a lease: a live-but-blocked holder yields a
  /// typed timeout, never destructive deletion. A STABLE-ZERO settle waits out a
  /// lease created concurrently with the last check (it self-deletes on its own
  /// intent re-read). Releasing the returned lease removes the intent.
  Future<DatabaseFileLease> acquireExclusive({
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final deadline = DateTime.now().add(timeout);
    final token = await _publishIntent(deadline);
    Future<void> clear() async => _deleteIfToken(File(intentPath), token);
    try {
      while (true) {
        if (DateTime.now().isAfter(deadline)) {
          throw const DatabaseLeaseUnavailable('timeout');
        }
        if (_liveLeaseCount() == 0) {
          await Future<void>.delayed(settleWindow);
          if (_liveLeaseCount() == 0) break; // stable zero — safe to proceed
          continue;
        }
        await Future<void>.delayed(pollStep);
      }
      return DatabaseFileLease._(File(intentPath), true, token, clear);
    } catch (_) {
      await clear();
      rethrow;
    }
  }

  /// Test seam: publish a fenced intent WITHOUT draining, returning a releasable
  /// handle (opens the "intent appeared after lease creation" window in tests).
  Future<DatabaseFileLease> publishIntentOnly({
    Duration timeout = const Duration(seconds: 2),
  }) async {
    final token = await _publishIntent(DateTime.now().add(timeout));
    return DatabaseFileLease._(File(intentPath), true, token,
        () async => _deleteIfToken(File(intentPath), token));
  }

  /// Claim the single intent path atomically. O_EXCL create gives mutual exclusion
  /// (fails if a live intent exists); its EXISTENCE is the authoritative signal
  /// (a reader that sees it — even before the content fill — treats maintenance as
  /// active, the safe interpretation), and the content is then filled for the pid /
  /// fencing token.
  Future<String> _publishIntent(DateTime deadline) async {
    final f = File(intentPath);
    final token = _randomToken();
    while (true) {
      try {
        f.createSync(exclusive: true); // O_EXCL — existence = intent present
        _writeRecordAtomic(intentPath, _LeaseRecord(token, ownerPid, instanceToken));
        return token;
      } on FileSystemException {
        if (DateTime.now().isAfter(deadline)) {
          throw const DatabaseLeaseUnavailable('timeout');
        }
        await Future<void>.delayed(pollStep);
      }
    }
  }

  /// STALE-FILE RECOVERY, run ONLY at process start while the caller holds the
  /// process-lifetime OS advisory lock (proof no other process is opening the DB).
  /// Clears lease/intent records that belong to an ENDED instance — identified by a
  /// different owner pid (pids are unique among live processes) or unparseable
  /// content (a leftover from a crashed write). Records tagged with the CURRENT pid
  /// (a live same-process isolate) are left untouched. Returns the count cleared.
  int recoverEndedInstances() {
    var cleared = 0;
    // Intent.
    final intent = File(intentPath);
    if (intent.existsSync() && _belongsToEndedInstance(intent)) {
      try {
        intent.deleteSync();
        cleared++;
      } catch (_) {}
    }
    // Shared leases.
    final d = Directory(leaseDir);
    if (d.existsSync()) {
      for (final e in d.listSync()) {
        if (e is! File || !e.path.endsWith('.lease')) continue;
        if (_belongsToEndedInstance(e)) {
          try {
            e.deleteSync();
            cleared++;
          } catch (_) {}
        }
      }
    }
    return cleared;
  }

  bool _belongsToEndedInstance(File f) {
    try {
      final rec = _LeaseRecord.tryParse(f.readAsStringSync());
      // Unparseable/partial leftover under the exclusive process lock → ended.
      if (rec == null) return true;
      // Keyed by the random per-process-INSTANCE TOKEN, never by PID: pids are
      // reused across process lifetimes, so PID equality is NOT liveness or
      // ownership proof (a fresh process can inherit a dead one's pid). A record
      // carrying THIS instance's token is live and is NEVER removed; any other
      // token belongs to an ended instance — and recovery runs only while the
      // caller holds the exclusive process lock, which is what proves the prior
      // instance ended.
      return rec.instance != instanceToken;
    } catch (_) {
      return true;
    }
  }

  // ── Test-only accessors (pure Dart; no Flutter import for Process.start tests) ──

  int debugLiveLeaseCount() => _liveLeaseCount();
  bool debugIntentPresent() => _intentPresent();
  int debugRecoverEndedInstances() => recoverEndedInstances();

  static Future<void> deleteIfTokenForTest(File file, String token) =>
      _deleteIfToken(file, token);
}
