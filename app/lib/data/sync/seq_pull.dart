/// WP-4 sequence pull shared by every pull service.
///
/// One gate per app: it asks the `sync_seq` capability, reads the server head
/// (`user_sync_state.last_seq` + epoch) ONCE per short window for all services,
/// records/compares the epoch (rebootstrap is WP-7, not here) and fetches pages
/// `sync_seq > cursor` ordered by `sync_seq`. Each table keeps its own seq cursor
/// (see [seqCursorEntity]); a service advances it inside the same local
/// transaction as the page it covers. When the capability is not verified the
/// services keep their legacy timestamp pull unchanged.
library;

import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/sync/sync_health.dart';
import '../db/app_database.dart';
import 'server_capabilities.dart';
import 'sync_cursor.dart';

/// The server's per-user change-stream head (`user_sync_state`).
class SyncHead {
  const SyncHead({
    required this.lastSeq,
    required this.epoch,
    this.epochReason,
  });
  final int lastSeq;
  final String epoch;
  final String? epochReason;
}

/// Why a sequence pull deliberately did nothing (typed state, no content).
enum SyncPullStop {
  /// Recorded epoch differs from the server's: history is no longer
  /// continuous. Rebootstrap is WP-7; pulling stops here.
  epochMismatch,

  /// The `sync_seq` capability could not be confirmed (auth/network error).
  capabilityUnknown,

  /// The server head could not be read this cycle.
  headUnavailable,
}

abstract interface class SeqRemote {
  /// Rows of [userId] with `sync_seq > afterSeq`, ordered by `sync_seq`.
  Future<List<Map<String, dynamic>>> fetchRowsBySeq({
    required String table,
    required String userId,
    required int afterSeq,
    required int limit,
    String select,
  });

  Future<SyncHead?> fetchHead(String userId);
}

class SupabaseSeqRemote implements SeqRemote {
  const SupabaseSeqRemote();

  SupabaseClient get _client => Supabase.instance.client;

  @override
  Future<List<Map<String, dynamic>>> fetchRowsBySeq({
    required String table,
    required String userId,
    required int afterSeq,
    required int limit,
    String select = '*',
  }) async {
    // Explicit user_id filter is defence in depth on top of RLS.
    final response = await _client
        .from(table)
        .select(select)
        .eq('user_id', userId)
        .gt('sync_seq', afterSeq)
        .order('sync_seq', ascending: true)
        .limit(limit);
    return (response as List)
        .map((r) => Map<String, dynamic>.from(r as Map))
        .toList(growable: false);
  }

  @override
  Future<SyncHead?> fetchHead(String userId) async {
    final row = await _client
        .from('user_sync_state')
        .select('last_seq, epoch, epoch_reason')
        .eq('user_id', userId)
        .maybeSingle();
    if (row == null) return null;
    return SyncHead(
      lastSeq: (row['last_seq'] as num).toInt(),
      epoch: row['epoch'] as String,
      epochReason: row['epoch_reason'] as String?,
    );
  }
}

enum SeqMode { legacy, seq, stopped }

class SeqPlan {
  const SeqPlan(this.mode, [this.head]);
  final SeqMode mode;

  /// The head read for this cycle (null: no state row yet, no short-circuit).
  final SyncHead? head;

  /// True when this table has already seen everything up to the head: the pull
  /// is skipped with no table call (an idle pull costs one head call).
  bool isIdle(int cursor) => head != null && head!.lastSeq <= cursor;
}

class SeqPullGate {
  SeqPullGate({
    required AppDatabase db,
    required Future<ServerCapabilityState> Function() capability,
    SeqRemote remote = const SupabaseSeqRemote(),
    DateTime Function()? clock,
    this.headTtl = const Duration(seconds: 5),
  })  : _db = db,
        _capability = capability,
        _remote = remote,
        _clock = clock ?? DateTime.now;

  final AppDatabase _db;
  final Future<ServerCapabilityState> Function() _capability;
  final SeqRemote _remote;
  final DateTime Function() _clock;

  /// One head read serves every service of the same sync cycle.
  final Duration headTtl;

  /// The last typed reason a plan stopped (null after a successful plan).
  SyncPullStop? lastStop;

  String? _headUid;
  SyncHead? _head;
  DateTime? _headAt;

  /// Never throws: any failure becomes a typed [SeqMode.stopped]. The outcome is
  /// also reported to [SyncHealth.shared] for the diagnostics (WP-8).
  Future<SeqPlan> plan(String userId) async {
    final result = await _plan(userId);
    SyncHealth.shared.recordPullPlan(
      stop: result.mode == SeqMode.stopped ? lastStop : null,
      headSeq: result.head?.lastSeq,
    );
    return result;
  }

  Future<SeqPlan> _plan(String userId) async {
    final ServerCapabilityState cap;
    try {
      cap = await _capability();
    } catch (_) {
      lastStop = SyncPullStop.capabilityUnknown;
      return const SeqPlan(SeqMode.stopped);
    }
    if (cap == ServerCapabilityState.unknown) {
      lastStop = SyncPullStop.capabilityUnknown;
      return const SeqPlan(SeqMode.stopped);
    }
    lastStop = null;
    if (cap == ServerCapabilityState.unsupported) {
      return const SeqPlan(SeqMode.legacy);
    }
    final SyncHead? head;
    try {
      head = await _readHead(userId);
    } catch (_) {
      lastStop = SyncPullStop.headUnavailable;
      return const SeqPlan(SeqMode.stopped);
    }
    if (head != null) {
      final recorded = await readRecordedSyncEpoch(_db, userId);
      if (recorded == null) {
        await writeRecordedSyncEpoch(_db, userId, head.epoch, head.epochReason);
      } else if (recorded.epoch != head.epoch) {
        lastStop = SyncPullStop.epochMismatch;
        return const SeqPlan(SeqMode.stopped);
      }
    }
    return SeqPlan(SeqMode.seq, head);
  }

  Future<SyncHead?> _readHead(String userId) async {
    final at = _headAt;
    if (_headUid == userId && at != null && _clock().difference(at) < headTtl) {
      return _head;
    }
    final head = await _remote.fetchHead(userId);
    _headUid = userId;
    _head = head;
    _headAt = _clock();
    return head;
  }

  Future<List<Map<String, dynamic>>> fetch({
    required String table,
    required String userId,
    required int afterSeq,
    required int limit,
    String select = '*',
  }) =>
      _remote.fetchRowsBySeq(
        table: table,
        userId: userId,
        afterSeq: afterSeq,
        limit: limit,
        select: select,
      );

  /// A table that reached EOF has seen every row up to the head read BEFORE its
  /// fetches (commit order == seq order), so its cursor may move to the head.
  /// That is what lets the next idle pull short-circuit.
  Future<void> markCaughtUp(
    String userId,
    String entity,
    int cursor,
    SeqPlan plan,
  ) async {
    final head = plan.head;
    if (head != null && head.lastSeq > cursor) {
      await writeSeqCursor(_db, userId, entity, head.lastSeq);
    }
  }
}

/// The advancing `sync_seq` of a page's last row. A missing or non-advancing
/// value throws: continuing would loop forever or skip rows.
int nextSeqOf(List<Map<String, dynamic>> rows, int cursor) {
  final v = rows.last['sync_seq'];
  if (v is! num || v.toInt() <= cursor) {
    throw const FormatException('Pull row has no advancing sync_seq');
  }
  return v.toInt();
}
