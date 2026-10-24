/// WP-5 client side of the WP-2 RPCs `sync_insert_if_absent`, `sync_cas_update`
/// and `sync_cas_tombstone` (migration 0107), gated by the `revision_cas`
/// capability. When the capability is not verified no service uses anything in
/// this file and the legacy guarded push runs unchanged.
library;

import 'dart:async';

import '../../core/session/account_fence_authority.dart';
import '../../core/session/admission_authority.dart';
import '../../core/sync/outbox_failure.dart';
import '../../core/sync/sync_health.dart';

import '../../core/sync/account_fence_retry.dart';

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

  /// Outside a [CasMutationObservation] scope this is the original single
  /// `await _client.rpc(...)`. Inside one, the SDK future is built synchronously
  /// (outside any tagging catch) after the scope admitted exactly this call, and
  /// only awaiting THAT future can mint a mutation-await proof.
  Future<CasResult> _send(String rpc, Map<String, dynamic> params) async {
    final scope = CasMutationObservation._current();
    if (scope == null) {
      return CasResult.fromJson(await _client.rpc(rpc, params: params));
    }
    final frozen = scope._admit(rpc, params);
    final PostgrestFilterBuilder<dynamic> call =
        _client.rpc(rpc, params: frozen);
    final Object? raw;
    try {
      raw = await call;
    } on PostgrestException catch (error) {
      final proof = scope._mint(error);
      if (proof != null) throw proof;
      rethrow;
    }
    return CasResult.fromJson(raw);
  }

  @override
  Future<CasResult> insertIfAbsent({
    required String table,
    required String epoch,
    required String opId,
    required Map<String, dynamic> row,
  }) =>
      _send('sync_insert_if_absent', _insertParams(table, epoch, opId, row));

  @override
  Future<CasResult> casUpdate({
    required String table,
    required String epoch,
    required String opId,
    required String serverId,
    required int expectedRevision,
    required Map<String, dynamic> patch,
  }) =>
      _send('sync_cas_update',
          _updateParams(table, epoch, opId, serverId, expectedRevision, patch));

  @override
  Future<CasResult> casTombstone({
    required String table,
    required String epoch,
    required String opId,
    required String serverId,
    required int expectedRevision,
  }) =>
      // D1: a category delete must re-parent its dependants, so it has its own
      // RPC (0116); every other family uses the generic one (0107).
      _send(_tombstoneRpc(table),
          _tombstoneParams(table, epoch, opId, serverId, expectedRevision));

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

Map<String, dynamic> _insertParams(
        String table, String epoch, String opId, Map<String, dynamic> row) =>
    {
      'p_table': table,
      'p_expected_epoch': epoch,
      'p_op_id': opId,
      'p_row': row,
    };

Map<String, dynamic> _updateParams(String table, String epoch, String opId,
        String serverId, int expectedRevision, Map<String, dynamic> patch) =>
    {
      'p_table': table,
      'p_expected_epoch': epoch,
      'p_op_id': opId,
      'p_id': serverId,
      'p_expected_revision': expectedRevision,
      'p_patch': patch,
    };

String _tombstoneRpc(String table) => table == 'user_categories'
    ? 'sync_cas_tombstone_category'
    : 'sync_cas_tombstone';

Map<String, dynamic> _tombstoneParams(String table, String epoch, String opId,
        String serverId, int expectedRevision) =>
    {
      if (table != 'user_categories') 'p_table': table,
      'p_expected_epoch': epoch,
      'p_op_id': opId,
      'p_id': serverId,
      'p_expected_revision': expectedRevision,
    };

/// Recursively frozen JSON (string-keyed maps, lists, null/bool/String, finite
/// num with int/double preserved). Anything else, a non-finite double or a cycle
/// is rejected before any dispatch.
Object? _freezeJson(Object? value, List<Object> path) {
  if (value == null || value is bool || value is String || value is int) {
    return value;
  }
  if (value is double) {
    if (!value.isFinite) throw ArgumentError('non-finite number');
    return value;
  }
  if (value is Map || value is List) {
    if (path.any((ancestor) => identical(ancestor, value))) {
      throw ArgumentError('cyclic value');
    }
    path.add(value);
    try {
      if (value is Map) {
        final out = <String, Object?>{};
        for (final entry in value.entries) {
          final key = entry.key;
          if (key is! String) throw ArgumentError('non-string key');
          out[key] = _freezeJson(entry.value, path);
        }
        return Map<String, Object?>.unmodifiable(out);
      }
      return List<Object?>.unmodifiable(
          [for (final item in value as List) _freezeJson(item, path)]);
    } finally {
      path.removeLast();
    }
  }
  throw ArgumentError('unsupported value');
}

bool _jsonEquals(Object? a, Object? b) {
  if (a == null || b == null) return a == null && b == null;
  if (a is bool || a is String) return b.runtimeType == a.runtimeType && a == b;
  if (a is int) return b is int && a == b;
  if (a is double) return b is double && a == b;
  if (a is Map) {
    if (b is! Map || a.length != b.length) return false;
    for (final key in a.keys) {
      if (!b.containsKey(key) || !_jsonEquals(a[key], b[key])) return false;
    }
    return true;
  }
  if (a is List) {
    if (b is! List || a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!_jsonEquals(a[i], b[i])) return false;
    }
    return true;
  }
  return false;
}

final Object _casObservationKey = Object();

/// Proof that THIS scope's sole concrete SDK dispatch was awaited and refused
/// with a structured QD code. Created only inside [SupabaseCasRemote]; it carries
/// no public raw value and nothing is logged.
final class CasMutationAwaitDenial implements Exception {
  CasMutationAwaitDenial._(this._owner, this._raw);
  final CasMutationObservation _owner;
  final PostgrestException _raw;
  @override
  String toString() => 'CasMutationAwaitDenial';
}

/// A scope was misused (reused, mismatched, unsupported input) or an expired
/// scope was inherited by a delegated dispatch. Nothing reached the network.
final class CasMutationObservationRejected implements Exception {
  CasMutationObservationRejected._(this.reason);
  final String reason;
  @override
  String toString() => 'CasMutationObservationRejected:$reason';
}

/// One expected semantic CAS mutation. [run] executes its action once; inside it
/// the real [SupabaseCasRemote] admits exactly one dispatch whose actual RPC and
/// frozen parameters equal the expectation. The observation carries no authority.
final class CasMutationObservation {
  CasMutationObservation._(this._rpc, Map<String, dynamic> params)
      : _expected = _freezeJson(params, <Object>[]) as Map<String, Object?>;

  factory CasMutationObservation.insertIfAbsent({
    required String table,
    required String epoch,
    required String opId,
    required Map<String, dynamic> row,
  }) =>
      CasMutationObservation._(
          'sync_insert_if_absent', _insertParams(table, epoch, opId, row));

  factory CasMutationObservation.update({
    required String table,
    required String epoch,
    required String opId,
    required String serverId,
    required int expectedRevision,
    required Map<String, dynamic> patch,
  }) =>
      CasMutationObservation._('sync_cas_update',
          _updateParams(table, epoch, opId, serverId, expectedRevision, patch));

  factory CasMutationObservation.tombstone({
    required String table,
    required String epoch,
    required String opId,
    required String serverId,
    required int expectedRevision,
  }) =>
      CasMutationObservation._(_tombstoneRpc(table),
          _tombstoneParams(table, epoch, opId, serverId, expectedRevision));

  final String _rpc;
  final Map<String, Object?> _expected;
  bool _ran = false;
  bool _active = false;
  bool _claimed = false;
  bool _taken = false;
  void Function()? _requireCurrent;
  CasMutationAwaitDenial? _minted;
  CasMutationAwaitDenial? _escaped;

  Future<T> run<T>(Future<T> Function() action,
      {required void Function() requireCurrent}) async {
    if (_ran) throw CasMutationObservationRejected._('reused');
    _ran = true;
    _requireCurrent = requireCurrent;
    _active = true;
    try {
      return await runZoned(action, zoneValues: {_casObservationKey: this});
    } catch (error) {
      if (error is CasMutationAwaitDenial && identical(error, _minted)) {
        _escaped = error;
      }
      rethrow;
    } finally {
      _active = false;
    }
  }

  /// The raw refusal, once, and only for the exact proof that escaped this
  /// scope's own failed run.
  PostgrestException? takeDenial(Object error) {
    if (error is! CasMutationAwaitDenial ||
        _taken ||
        !identical(error, _escaped) ||
        !identical(error._owner, this)) {
      return null;
    }
    _taken = true;
    return error._raw;
  }

  /// Null when no scope is installed (the unscoped path); throws for an
  /// installed scope that is no longer active.
  static CasMutationObservation? _current() {
    final scope = Zone.current[_casObservationKey];
    if (scope == null) return null;
    if (scope is! CasMutationObservation || !scope._active) {
      throw CasMutationObservationRejected._('expired');
    }
    return scope;
  }

  /// Claims the sole dispatch, matches it to the expectation, then re-validates
  /// the original lifetime immediately before the caller builds the SDK future.
  Map<String, Object?> _admit(String rpc, Map<String, dynamic> params) {
    if (_claimed) throw CasMutationObservationRejected._('reused');
    _claimed = true;
    final Map<String, Object?> actual;
    try {
      actual = _freezeJson(params, <Object>[]) as Map<String, Object?>;
    } on ArgumentError {
      throw CasMutationObservationRejected._('unsupported');
    }
    if (rpc != _rpc || !_jsonEquals(_expected, actual)) {
      throw CasMutationObservationRejected._('mismatch');
    }
    _requireCurrent!();
    return actual;
  }

  CasMutationAwaitDenial? _mint(PostgrestException error) {
    if (!_active ||
        !_claimed ||
        _minted != null ||
        decodeParentAccountDenial(error) == null) {
      return null;
    }
    return _minted = CasMutationAwaitDenial._(this, error);
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
    final epoch = await epochOrNull(userId);
    return epoch == null
        ? const CasPlan(CasMode.stopped)
        : CasPlan(CasMode.cas, epoch);
  }

  /// Ledger-only entrance; legacy planning callers keep plan/epochOrNull.
  Future<CasPlan> planForLedger(String userId, {
      required AccountFenceAuthority authority, required AccountFenceHandle handle,
      required AppDatabase database}) async {
    void check() {
      if (!identical(database, _db) || authority.ownerUid(handle) != userId) {
        throw const LedgerDeliveryStopped(LedgerDeliveryStopReason.stale);
      }
      authority.requireCurrentForDatabase(handle, database);
    }
    check();
    final ServerCapabilityState cap;
    try {
      cap = await _capability();
      check();
    } on LedgerDeliveryStopped {
      rethrow;
    } on StaleAdmissionException {
      rethrow;
    } catch (_) {
      check();
      return const CasPlan(CasMode.stopped);
    }
    if (cap == ServerCapabilityState.unsupported) {
      return const CasPlan(CasMode.legacy);
    }
    if (cap == ServerCapabilityState.unknown) return const CasPlan(CasMode.stopped);
    final recorded = await authority.runCurrentLocal(handle, database,
        () => readRecordedSyncEpoch(_db, userId));
    check();
    if (recorded != null) return CasPlan(CasMode.cas, recorded.epoch);
    try {
      check();
      final head = await _remote.fetchHead(userId);
      check();
      return head == null ? const CasPlan(CasMode.stopped)
          : CasPlan(CasMode.cas, head.epoch);
    } on LedgerDeliveryStopped {
      rethrow;
    } on StaleAdmissionException {
      rethrow;
    } catch (_) {
      check();
      return const CasPlan(CasMode.stopped);
    }
  }

  Future<CasPlan> planForAccounts(String userId, {
      required AccountFenceAuthority authority, required AccountFenceHandle handle,
      required AppDatabase database}) async {
    void check() {
      if (!identical(database, _db) || authority.ownerUid(handle) != userId) {
        throw const AccountsDeliveryStopped(AccountsDeliveryStopReason.stale);
      }
      authority.requireCurrentForDatabase(handle, database);
    }
    check();
    final ServerCapabilityState cap;
    try {
      cap = await _capability();
      check();
    } on AccountFenceDeliveryCancellation {
      rethrow;
    } on StaleAdmissionException {
      rethrow;
    } catch (_) {
      check();
      return const CasPlan(CasMode.stopped);
    }
    if (cap == ServerCapabilityState.unsupported) {
      return const CasPlan(CasMode.legacy);
    }
    if (cap == ServerCapabilityState.unknown) return const CasPlan(CasMode.stopped);
    final recorded = await authority.runCurrentLocal(handle, database,
        () => readRecordedSyncEpoch(_db, userId));
    check();
    if (recorded != null) return CasPlan(CasMode.cas, recorded.epoch);
    try {
      check();
      final head = await _remote.fetchHead(userId);
      check();
      return head == null ? const CasPlan(CasMode.stopped)
          : CasPlan(CasMode.cas, head.epoch);
    } on AccountFenceDeliveryCancellation {
      rethrow;
    } on StaleAdmissionException {
      rethrow;
    } catch (_) {
      check();
      return const CasPlan(CasMode.stopped);
    }
  }

  Future<CasPlan> planForPlanningParent(String userId, {
      required AccountFenceAuthority authority, required AccountFenceHandle handle,
      required AppDatabase database}) async {
    void check() {
      if (!identical(database, _db) || authority.ownerUid(handle) != userId) {
        throw const PlanningDeliveryStopped(PlanningDeliveryStopReason.stale);
      }
      authority.requireCurrentForDatabase(handle, database);
    }
    check();
    final ServerCapabilityState cap;
    try {
      cap = await _capability();
      check();
    } on AccountFenceDeliveryCancellation {
      rethrow;
    } on StaleAdmissionException {
      rethrow;
    } catch (_) {
      check();
      return const CasPlan(CasMode.stopped);
    }
    if (cap == ServerCapabilityState.unsupported) {
      return const CasPlan(CasMode.legacy);
    }
    if (cap == ServerCapabilityState.unknown) return const CasPlan(CasMode.stopped);
    final recorded = await authority.runCurrentLocal(handle, database,
        () => readRecordedSyncEpoch(_db, userId));
    check();
    if (recorded != null) return CasPlan(CasMode.cas, recorded.epoch);
    try {
      check();
      final head = await _remote.fetchHead(userId);
      check();
      return head == null ? const CasPlan(CasMode.stopped)
          : CasPlan(CasMode.cas, head.epoch);
    } on AccountFenceDeliveryCancellation {
      rethrow;
    } on StaleAdmissionException {
      rethrow;
    } catch (_) {
      check();
      return const CasPlan(CasMode.stopped);
    }
  }

  /// The replica's epoch: the recorded one, else the server's current one; null
  /// when neither can be read. Also used by the one legacy-path call that has
  /// no other way to learn it (goal-contribution delete, D1).
  /// Child delete protocol: stopped is distinct from unavailable legacy epoch.
  Future<String?> deleteEpochForChildren(String userId,{required AccountFenceAuthority authority,
      required AccountFenceHandle handle,required AppDatabase database,required SyncPhaseBinding phase})async{
    void check(){
      if(!phase.isBound||!phase.isCurrent||!identical(phase.database,database)){throw const ChildDeliveryStopped(ChildDeliveryStopReason.stale);}
      if(!identical(database,_db)||authority.ownerUid(handle)!=userId){throw const ChildDeliveryStopped(ChildDeliveryStopReason.stale);}
      authority.requireCurrentForDatabase(handle,database);
    }
    check();final ServerCapabilityState cap;
    try{cap=await _capability();check();}
    on AccountFenceDeliveryCancellation{rethrow;}
    on StaleAdmissionException{rethrow;}
    catch(error){if(decodeChildAccountDenial(error)!=null){throw const ChildDeliveryStopped(ChildDeliveryStopReason.nonMutationRefusal);}check();throw const CasEpochMismatch();}
    if(cap==ServerCapabilityState.unknown){throw const CasEpochMismatch();}
    final recorded=await authority.runCurrentLocal(handle,database,()=>readRecordedSyncEpoch(_db,userId));
    check();if(recorded!=null)return recorded.epoch;
    String? epoch;
    try{epoch=(await _remote.fetchHead(userId))?.epoch;check();}
    on AccountFenceDeliveryCancellation{rethrow;}
    on StaleAdmissionException{rethrow;}
    catch(error){if(decodeChildAccountDenial(error)!=null){throw const ChildDeliveryStopped(ChildDeliveryStopReason.nonMutationRefusal);}check();epoch=null;}
    if(epoch==null&&cap==ServerCapabilityState.verified){throw const CasEpochMismatch();}
    return epoch;
  }

  Future<String?> epochOrNull(String userId) async {
    final recorded = await readRecordedSyncEpoch(_db, userId);
    if (recorded != null) return recorded.epoch;
    try {
      return (await _remote.fetchHead(userId))?.epoch;
    } catch (_) {
      return null;
    }
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
    final r = await retryAccountFenceMutation(() => _remote.insertIfAbsent(
        table: table, epoch: epoch, opId: opId, row: row));
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
        send: (rev) => retryAccountFenceMutation(() => _remote.casUpdate(
            table: table,
            epoch: epoch,
            opId: opId,
            serverId: serverId,
            expectedRevision: rev,
            patch: patch)),
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
      send: (rev) => retryAccountFenceMutation(() => _remote.casTombstone(
          table: table,
          epoch: epoch,
          opId: opId,
          serverId: serverId,
          expectedRevision: rev)),
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
