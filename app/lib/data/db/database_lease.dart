import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart' show visibleForTesting;

// MALI-069n (Batch-4 closure #3) — a CROSS-ISOLATE (and cross-process) database-
// use lease. Dart's RandomAccessFile.lock uses POSIX fcntl record locks, which are
// PER-PROCESS and therefore DO NOT coordinate isolates within one process (the two
// production secondary paths run as background isolates in the app process). So the
// lease is built on the file system, which every isolate/process sees identically.
//
// Two correctness properties this file must hold (the second closure was blocked on
// both):
//
//   * RENEWABLE LIVENESS (no false stale-reap of live work). Each lease and the
//     maintenance intent carries a unique random FENCING TOKEN and a HEARTBEAT: a
//     bounded periodic mtime bump while the holder is alive. Liveness/expiry is
//     measured from the LAST heartbeat, never from creation time, so an operation
//     that legitimately runs longer than [leaseTtl] stays protected as long as its
//     heartbeat keeps beating. Stale recovery only happens after the heartbeat has
//     stopped for longer than the ttl AND a re-verification confirms the holder did
//     not beat in between — so a long restore, a paused/suspended device, or a
//     forward clock jump cannot delete a live lease. Cleanup only ever removes a
//     file whose token still matches (an older holder's cleanup can never remove a
//     newer lease/intent). A killed isolate/process simply stops beating, so its
//     file becomes recoverable after the ttl — nothing is ever permanently locked.
//
//   * NO SHARED-ACQUIRE vs MAINTENANCE-INTENT RACE. Shared acquisition is TWO-PHASE
//     (create the lease, THEN re-read the intent and back off if it appeared); the
//     maintenance side publishes its fenced intent, drains every pre-existing live
//     lease, and then requires a STABLE-ZERO settle window so any lease created
//     concurrently with the last drain check (whose own re-read will see the intent
//     and self-delete) is waited out before destructive work may begin.
//
// The lease/intent files contain ONLY a random fencing token — no user id, no
// financial data, no database path, no key material.

/// Thrown when a lease cannot be acquired within the bounded window. Never carries
/// any secret — only a coarse [reason].
class DatabaseLeaseUnavailable implements Exception {
  const DatabaseLeaseUnavailable(this.reason);

  /// 'maintenance_in_progress' | 'timeout' | 'lease_recovery' — no secrets.
  final String reason;

  @override
  String toString() => 'DatabaseLeaseUnavailable($reason)';
}

/// A held database-use lease. Its heartbeat keeps the underlying file live for the
/// FULL lifetime of the operation; always [release] it in a `finally`, which stops
/// the heartbeat and removes the file (only if its token still matches).
class DatabaseFileLease {
  DatabaseFileLease._(
    this._file,
    this.isExclusive,
    this.token,
    this._heartbeat,
    this._onRelease,
  );

  final File _file;
  final bool isExclusive;

  /// The unique fencing token this holder owns. Only this holder may remove the
  /// file, and only while the on-disk token still equals this value.
  final String token;

  final Timer _heartbeat;
  final Future<void> Function()? _onRelease;
  bool _released = false;

  Future<void> release() async {
    if (_released) return;
    _released = true;
    _heartbeat.cancel(); // stop the heartbeat in the finally-equivalent — no leak
    await _deleteIfToken(_file, token);
    final onRelease = _onRelease;
    if (onRelease != null) await onRelease();
  }
}

/// Delete [file] only if it still carries [token]. A newer holder that replaced the
/// file at the same path (a new maintenance intent) has a different token, so an
/// older holder's cleanup can never remove it.
Future<void> _deleteIfToken(File file, String token) async {
  try {
    if (!await file.exists()) return;
    final current = (await file.readAsString()).trim();
    if (current == token) await file.delete();
  } catch (_) {
    // Best effort — a concurrent legitimate holder is the only remover, and a
    // read/delete race is resolved by the token check on the surviving path.
  }
}

class DatabaseLeaseManager {
  DatabaseLeaseManager({
    required this.leaseDir,
    required this.intentPath,
    this.leaseTtl = const Duration(seconds: 15),
    Duration? heartbeatInterval,
    Duration? settleWindow,
    Duration? pollStep,
  })  : heartbeatInterval =
            heartbeatInterval ?? Duration(milliseconds: leaseTtl.inMilliseconds ~/ 4),
        settleWindow = settleWindow ??
            Duration(milliseconds: leaseTtl.inMilliseconds ~/ 4),
        pollStep = pollStep ?? const Duration(milliseconds: 25);

  /// A directory holding one file per active shared lease.
  final String leaseDir;

  /// The maintenance-intent marker path.
  final String intentPath;

  /// A lease/intent whose LAST heartbeat is older than this is a stale candidate
  /// (its holder crashed) — but it is only reaped after a re-verification, so a
  /// live heartbeat always keeps it protected.
  final Duration leaseTtl;

  /// How often a live holder bumps its file's mtime. Must be < [leaseTtl].
  final Duration heartbeatInterval;

  /// After the last live lease drains, maintenance re-checks zero across this
  /// window so a lease created concurrently with the last check (and about to
  /// self-delete on its own intent re-read) is waited out.
  final Duration settleWindow;

  /// Poll granularity while draining.
  final Duration pollStep;

  final Random _rng = Random.secure();
  int _seq = 0;

  String _newToken() {
    final bytes = List<int>.generate(16, (_) => _rng.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  DateTime? _mtimeOrNull(File f) {
    try {
      return f.statSync().modified;
    } catch (_) {
      return null;
    }
  }

  /// Live iff the last heartbeat is within [leaseTtl]. A future-dated mtime (clock
  /// moved backwards) is treated conservatively as LIVE, never as stale.
  bool _within(DateTime? mtime) {
    if (mtime == null) return false;
    final age = DateTime.now().difference(mtime);
    return age <= leaseTtl; // negative age (future mtime) => live
  }

  Timer _startHeartbeat(File file, String token) {
    return Timer.periodic(heartbeatInterval, (t) {
      try {
        // Rewrite the token to bump mtime with SUB-SECOND precision. (A plain
        // setLastModified truncates to whole seconds on some platforms — too
        // coarse for a bounded ttl.) Only if the file still exists, so a lease
        // that was legitimately reaped is never resurrected; a dead holder's
        // isolate/timer is already gone, so it cannot recreate anything.
        if (file.existsSync()) {
          file.writeAsStringSync(token);
        } else {
          t.cancel();
        }
      } catch (_) {
        // Gone or unwritable (holder tearing down) — stop beating; no timer leak.
        t.cancel();
      }
    });
  }

  /// Conservatively reap [file] only if its heartbeat has genuinely stopped:
  /// require it to remain stale, with an UNCHANGED token and mtime, across a
  /// [heartbeatInterval] re-verification. A live holder bumps mtime within that
  /// window and is spared.
  Future<void> _reapIfStale(File file) async {
    final mtime = _mtimeOrNull(file);
    if (mtime == null || _within(mtime)) return;
    String token;
    try {
      token = (await file.readAsString()).trim();
    } catch (_) {
      return; // vanished or unreadable — nothing to reap
    }
    await Future<void>.delayed(heartbeatInterval);
    final mtime2 = _mtimeOrNull(file);
    if (mtime2 == null) return; // already gone
    if (mtime2 != mtime) return; // holder beat in between → live, spare it
    if (_within(mtime2)) return; // became live via clock change → spare it
    await _deleteIfToken(file, token);
  }

  /// True while a LIVE maintenance intent exists (stale intent is reaped first, so
  /// a crashed maintainer never permanently blocks secondaries).
  Future<bool> _intentLive() async {
    final f = File(intentPath);
    final mtime = _mtimeOrNull(f);
    if (mtime == null) return false; // fast path: no intent
    if (_within(mtime)) return true;
    await _reapIfStale(f);
    return _within(_mtimeOrNull(f));
  }

  /// Count LIVE shared leases. Stale files (heartbeat stopped) are not counted; a
  /// crashed holder can never keep maintenance waiting past the ttl.
  int _liveLeaseCount() {
    final d = Directory(leaseDir);
    if (!d.existsSync()) return 0;
    var count = 0;
    for (final e in d.listSync()) {
      if (e is! File || !e.path.endsWith('.lease')) continue;
      if (_within(_mtimeOrNull(e))) count++;
    }
    return count;
  }

  Future<void> _reapStaleLeases() async {
    final d = Directory(leaseDir);
    if (!d.existsSync()) return;
    for (final e in d.listSync()) {
      if (e is! File || !e.path.endsWith('.lease')) continue;
      await _reapIfStale(e);
    }
  }

  /// Acquire a SHARED database-use lease (a normal main/secondary user). TWO-PHASE
  /// so it can never slip past a maintenance intent that is published concurrently:
  ///   1. refuse if a live maintenance intent already exists;
  ///   2. atomically create THIS lease (unique path + fencing token + heartbeat);
  ///   3. re-read the intent — if it appeared/changed during (2), delete only our
  ///      own lease and refuse. Only after (3) may the caller open the connection.
  /// The lease heartbeats for the whole connection lifetime and MUST be released in
  /// a `finally`.
  Future<DatabaseFileLease> acquireShared() => _acquireShared();

  /// Test-only variant that can interleave the maintenance intent EXACTLY in each
  /// of the two race windows: [afterPrecheck] runs between phase 1 and phase 2,
  /// [afterCreate] runs between phase 2 and phase 3.
  @visibleForTesting
  Future<DatabaseFileLease> acquireSharedWithHooks({
    Future<void> Function()? afterPrecheck,
    Future<void> Function()? afterCreate,
  }) =>
      _acquireShared(afterPrecheck: afterPrecheck, afterCreate: afterCreate);

  Future<DatabaseFileLease> _acquireShared({
    Future<void> Function()? afterPrecheck,
    Future<void> Function()? afterCreate,
  }) async {
    // Phase 1 — pre-check.
    if (await _intentLive()) {
      throw const DatabaseLeaseUnavailable('maintenance_in_progress');
    }
    if (afterPrecheck != null) await afterPrecheck();
    Directory(leaseDir).createSync(recursive: true);
    final token = _newToken();
    final path =
        '$leaseDir/${pid}_${_seq++}_${DateTime.now().microsecondsSinceEpoch}.lease';
    final file = File(path);
    // Phase 2 — atomically create THIS lease, then start its heartbeat.
    await file.create(exclusive: true);
    await file.writeAsString(token, flush: true);
    final heartbeat = _startHeartbeat(file, token);
    if (afterCreate != null) await afterCreate();
    // Phase 3 — re-check: if maintenance intent appeared while we were registering,
    // back off so a secondary never coexists with file-exclusive maintenance.
    if (await _intentLive()) {
      heartbeat.cancel();
      await _deleteIfToken(file, token);
      throw const DatabaseLeaseUnavailable('maintenance_in_progress');
    }
    return DatabaseFileLease._(file, false, token, heartbeat, null);
  }

  /// Acquire an EXCLUSIVE (file-level) maintenance lease. Publishes a fenced intent
  /// (refusing NEW shared leases), drains every pre-existing live lease, then
  /// requires a STABLE-ZERO settle so a lease created concurrently with the last
  /// drain check (which will self-delete on its own intent re-read) is waited out
  /// before returning. Releasing the returned lease stops the intent heartbeat and
  /// removes the (token-matched) intent marker.
  Future<DatabaseFileLease> acquireExclusive({
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final deadline = DateTime.now().add(timeout);
    final token = await _publishIntent(deadline);
    final heartbeat = _startHeartbeat(File(intentPath), token);
    Future<void> clear() async {
      heartbeat.cancel();
      await _deleteIfToken(File(intentPath), token);
    }

    try {
      await _reapStaleLeases();
      // Drain + stable-zero.
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
      return DatabaseFileLease._(File(intentPath), true, token, heartbeat, clear);
    } catch (_) {
      await clear();
      rethrow;
    }
  }

  /// Test-only: publish a fenced maintenance intent WITHOUT draining leases (the
  /// drain is what [acquireExclusive] adds). Returns a releasable handle so a test
  /// can open the exact "intent appeared after lease creation" window.
  @visibleForTesting
  Future<DatabaseFileLease> publishIntentOnly({
    Duration timeout = const Duration(seconds: 2),
  }) async {
    final token = await _publishIntent(DateTime.now().add(timeout));
    final heartbeat = _startHeartbeat(File(intentPath), token);
    return DatabaseFileLease._(File(intentPath), true, token, heartbeat, () async {
      await _deleteIfToken(File(intentPath), token);
    });
  }

  /// Test-only: the number of LIVE shared leases the filesystem currently shows.
  @visibleForTesting
  int debugLiveLeaseCount() => _liveLeaseCount();

  /// Test-only: whether a live maintenance intent exists right now.
  @visibleForTesting
  Future<bool> debugIntentLive() => _intentLive();

  /// Test-only: the fencing delete used by [DatabaseFileLease.release] — deletes
  /// [file] only when its on-disk token still equals [token].
  @visibleForTesting
  static Future<void> deleteIfTokenForTest(File file, String token) =>
      _deleteIfToken(file, token);

  /// Atomically create the intent marker with a fresh fencing token. If a live
  /// intent already exists we wait (another maintainer holds it); a stale one is
  /// reaped and the create retried. Returns the token this maintainer owns.
  Future<String> _publishIntent(DateTime deadline) async {
    final f = File(intentPath);
    while (true) {
      final token = _newToken();
      try {
        await f.create(exclusive: true); // O_EXCL — fails if a marker exists
        await f.writeAsString(token, flush: true);
        return token;
      } on FileSystemException {
        if (!await _intentLive()) {
          continue; // the existing marker was stale and got reaped — retry
        }
        if (DateTime.now().isAfter(deadline)) {
          throw const DatabaseLeaseUnavailable('timeout');
        }
        await Future<void>.delayed(pollStep);
      }
    }
  }
}
