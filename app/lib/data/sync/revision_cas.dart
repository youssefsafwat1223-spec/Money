/// WP-5 client side of the WP-2 RPCs `sync_insert_if_absent`, `sync_cas_update`
/// and `sync_cas_tombstone` (migration 0107), gated by the `revision_cas`
/// capability. When the capability is not verified no service uses anything in
/// this file and the legacy guarded push runs unchanged.
library;

import 'package:supabase_flutter/supabase_flutter.dart';

import '../db/app_database.dart';
import 'seq_pull.dart';
import 'server_capabilities.dart';
import 'sync_cursor.dart';

enum CasOutcome {
  inserted,
  adopted,
  ack,
  applied,
  conflict,
  notFound,
  epochMismatch,
}

class CasResult {
  const CasResult(this.outcome, this.row, {this.reason});
  final CasOutcome outcome;
  final Map<String, dynamic>? row;
  final String? reason;

  factory CasResult.fromJson(Object? raw) {
    if (raw is! Map) throw const FormatException('cas result is not an object');
    final name = switch (raw['outcome']) {
      'inserted' => CasOutcome.inserted,
      'adopted' => CasOutcome.adopted,
      'ack' => CasOutcome.ack,
      'applied' => CasOutcome.applied,
      'conflict' => CasOutcome.conflict,
      'not_found' => CasOutcome.notFound,
      'epoch_mismatch' => CasOutcome.epochMismatch,
      _ => throw const FormatException('unknown cas outcome'),
    };
    final row = raw['row'];
    return CasResult(
      name,
      row is Map ? Map<String, dynamic>.from(row) : null,
      reason: raw['reason'] as String?,
    );
  }
}

/// The server says this replica's epoch is not the current one. Nothing was
/// written; the operation stays queued and the push cycle stops (WP-7 owns the
/// rebootstrap).
class CasEpochMismatch implements Exception {
  const CasEpochMismatch();
  @override
  String toString() => 'CasEpochMismatch';
}

abstract interface class CasRemote {
  Future<CasResult> insertIfAbsent({
    required String table,
    required String epoch,
    required String opId,
    required Map<String, dynamic> row,
  });

  Future<CasResult> casUpdate({
    required String table,
    required String epoch,
    required String opId,
    required String serverId,
    required int expectedRevision,
    required Map<String, dynamic> patch,
  });

  Future<CasResult> casTombstone({
    required String table,
    required String epoch,
    required String opId,
    required String serverId,
    required int expectedRevision,
  });

  /// The current cloud row (revision, updated_at, deleted_at, last_op_id), or
  /// null when it is gone. Used only to resolve a missing base revision.
  Future<Map<String, dynamic>?> fetchRow(String table, String serverId);
}

class SupabaseCasRemote implements CasRemote {
  const SupabaseCasRemote();

  SupabaseClient get _client => Supabase.instance.client;

  @override
  Future<CasResult> insertIfAbsent({
    required String table,
    required String epoch,
    required String opId,
    required Map<String, dynamic> row,
  }) async =>
      CasResult.fromJson(await _client.rpc('sync_insert_if_absent', params: {
        'p_table': table,
        'p_expected_epoch': epoch,
        'p_op_id': opId,
        'p_row': row,
      }));

  @override
  Future<CasResult> casUpdate({
    required String table,
    required String epoch,
    required String opId,
    required String serverId,
    required int expectedRevision,
    required Map<String, dynamic> patch,
  }) async =>
      CasResult.fromJson(await _client.rpc('sync_cas_update', params: {
        'p_table': table,
        'p_expected_epoch': epoch,
        'p_op_id': opId,
        'p_id': serverId,
        'p_expected_revision': expectedRevision,
        'p_patch': patch,
      }));

  @override
  Future<CasResult> casTombstone({
    required String table,
    required String epoch,
    required String opId,
    required String serverId,
    required int expectedRevision,
  }) async =>
      CasResult.fromJson(await _client.rpc('sync_cas_tombstone', params: {
        'p_table': table,
        'p_expected_epoch': epoch,
        'p_op_id': opId,
        'p_id': serverId,
        'p_expected_revision': expectedRevision,
      }));

  @override
  Future<Map<String, dynamic>?> fetchRow(String table, String serverId) async {
    final row = await _client
        .from(table)
        .select('id, revision, updated_at, deleted_at, last_op_id')
        .eq('id', serverId)
        .maybeSingle();
    return row == null ? null : Map<String, dynamic>.from(row);
  }
}

enum CasMode { legacy, cas, stopped }

class CasPlan {
  const CasPlan(this.mode, [this.epoch]);
  final CasMode mode;
  final String? epoch;
  bool get isCas => mode == CasMode.cas;
}

/// One decision per push cycle: legacy (capability absent), CAS with the
/// replica's epoch, or stopped (capability/epoch not provable right now; the
/// queue is left untouched and no attempt is consumed).
class RevisionCasGate {
  RevisionCasGate({
    required AppDatabase db,
    required Future<ServerCapabilityState> Function() capability,
    SeqRemote remote = const SupabaseSeqRemote(),
  })  : _db = db,
        _capability = capability,
        _remote = remote;

  final AppDatabase _db;
  final Future<ServerCapabilityState> Function() _capability;
  final SeqRemote _remote;

  Future<CasPlan> plan(String userId) async {
    final ServerCapabilityState cap;
    try {
      cap = await _capability();
    } catch (_) {
      return const CasPlan(CasMode.stopped);
    }
    if (cap == ServerCapabilityState.unsupported) {
      return const CasPlan(CasMode.legacy);
    }
    if (cap == ServerCapabilityState.unknown) {
      return const CasPlan(CasMode.stopped);
    }
    final recorded = await readRecordedSyncEpoch(_db, userId);
    if (recorded != null) return CasPlan(CasMode.cas, recorded.epoch);
    try {
      final head = await _remote.fetchHead(userId);
      if (head != null) return CasPlan(CasMode.cas, head.epoch);
    } catch (_) {}
    return const CasPlan(CasMode.stopped);
  }
}

enum CasDecisionKind {
  /// The cloud has our write (applied, lost-ACK receipt, adopted or inserted).
  acked,

  /// Delete converged (already tombstoned or absent): nothing more to do.
  gone,

  /// A real conflict; [CasDecision.row] is the cloud row when known.
  conflict,

  /// An update/CAS found no cloud row at all.
  missing,
}

class CasDecision {
  const CasDecision(this.kind, [this.row, this.reason]);
  final CasDecisionKind kind;
  final Map<String, dynamic>? row;
  final String? reason;

  bool get cloudTombstoned => row != null && row!['deleted_at'] != null;
}

/// The outcome logic shared by every family. Pure RPC choreography: the caller
/// owns the local ACK / conflict bookkeeping.
class RevisionCasEngine {
  RevisionCasEngine(this._remote);
  final CasRemote _remote;

  Future<CasDecision> create({
    required String table,
    required String epoch,
    required String opId,
    required Map<String, dynamic> row,
  }) async {
    final r = await _remote.insertIfAbsent(
        table: table, epoch: epoch, opId: opId, row: row);
    return switch (r.outcome) {
      CasOutcome.inserted ||
      CasOutcome.adopted ||
      CasOutcome.ack =>
        CasDecision(CasDecisionKind.acked, r.row),
      CasOutcome.conflict =>
        CasDecision(CasDecisionKind.conflict, r.row, r.reason),
      CasOutcome.epochMismatch => throw const CasEpochMismatch(),
      _ => throw StateError('unexpected insert outcome ${r.outcome.name}'),
    };
  }

  Future<CasDecision> update({
    required String table,
    required String epoch,
    required String opId,
    required List<String> priorOpIds,
    required String serverId,
    required int? baseRevision,
    required String? baseUpdatedAt,
    required Map<String, dynamic> patch,
  }) =>
      _cas(
        table: table,
        serverId: serverId,
        baseRevision: baseRevision,
        baseUpdatedAt: baseUpdatedAt,
        priorOpIds: priorOpIds,
        send: (rev) => _remote.casUpdate(
            table: table,
            epoch: epoch,
            opId: opId,
            serverId: serverId,
            expectedRevision: rev,
            patch: patch),
      );

  Future<CasDecision> tombstone({
    required String table,
    required String epoch,
    required String opId,
    required List<String> priorOpIds,
    required String serverId,
    required int? baseRevision,
    required String? baseUpdatedAt,
  }) async {
    final d = await _cas(
      table: table,
      serverId: serverId,
      baseRevision: baseRevision,
      baseUpdatedAt: baseUpdatedAt,
      priorOpIds: priorOpIds,
      send: (rev) => _remote.casTombstone(
          table: table,
          epoch: epoch,
          opId: opId,
          serverId: serverId,
          expectedRevision: rev),
    );
    // Absent or already tombstoned: the delete's goal is met.
    if (d.kind == CasDecisionKind.missing) {
      return const CasDecision(CasDecisionKind.gone);
    }
    if (d.kind == CasDecisionKind.conflict && d.cloudTombstoned) {
      return CasDecision(CasDecisionKind.gone, d.row);
    }
    return d;
  }

  Future<CasDecision> _cas({
    required String table,
    required String serverId,
    required int? baseRevision,
    required String? baseUpdatedAt,
    required List<String> priorOpIds,
    required Future<CasResult> Function(int revision) send,
  }) async {
    var base = baseRevision;
    if (base == null) {
      // No explicit base revision (queued before WP-5): the edit's base is the
      // legacy updated_at token. Use it only if the cloud row is still exactly
      // at that token; otherwise it moved and this is a conflict. Never blind.
      final cloud = await _remote.fetchRow(table, serverId);
      if (cloud == null) return const CasDecision(CasDecisionKind.missing);
      if (cloud['deleted_at'] != null) {
        return CasDecision(CasDecisionKind.conflict, cloud);
      }
      final token = canonicalServerTimestamp(baseUpdatedAt);
      final current = canonicalServerTimestamp(cloud['updated_at'] as String?);
      final rev = (cloud['revision'] as num?)?.toInt();
      if (token == null || token != current || rev == null) {
        return CasDecision(CasDecisionKind.conflict, cloud);
      }
      base = rev;
    }
    for (var attempt = 0; attempt < 2; attempt++) {
      final r = await send(base!);
      switch (r.outcome) {
        case CasOutcome.applied || CasOutcome.ack:
          return CasDecision(CasDecisionKind.acked, r.row);
        case CasOutcome.notFound:
          return const CasDecision(CasDecisionKind.missing);
        case CasOutcome.epochMismatch:
          throw const CasEpochMismatch();
        case CasOutcome.conflict:
          final row = r.row;
          final last = row?['last_op_id'] as String?;
          final rev = (row?['revision'] as num?)?.toInt();
          // A still-live row whose last writer is one of OUR earlier operations
          // for this entity (sent, ACK lost, then edited again): the cloud only
          // holds our own writes, so re-base on it and retry once.
          if (attempt == 0 &&
              row != null &&
              row['deleted_at'] == null &&
              rev != null &&
              last != null &&
              priorOpIds.contains(last)) {
            base = rev;
            continue;
          }
          return CasDecision(CasDecisionKind.conflict, row, r.reason);
        default:
          throw StateError('unexpected cas outcome ${r.outcome.name}');
      }
    }
    throw StateError('unreachable');
  }
}
