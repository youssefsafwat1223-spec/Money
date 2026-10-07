// In-memory emulation of the WP-2 RPC contract (migration 0107) for client
// tests: sync_insert_if_absent / sync_cas_update / sync_cas_tombstone with the
// outcomes inserted | adopted | ack | applied | conflict | not_found |
// epoch_mismatch. Mirrors supabase/migrations/0107_sync_cas_rpcs.sql.
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/sync/revision_cas.dart';
import 'package:money_companion/data/sync/seq_pull.dart';
import 'package:money_companion/data/sync/server_capabilities.dart';

const _identity = {'user_transactions': 'client_request_id'};
const _serverManaged = {
  'user_id', 'local_id', 'client_request_id', 'created_at', 'updated_at',
  'metadata', 'saved_amount', 'paid_count', 'last_notified_spent_amount',
  'last_notified_period_start', 'last_notified_saved_amount', 'source',
  'confidence', 'balance_after', 'comparison_timestamp',
  'comparison_timestamp_source', 'local_account_id',
};

class FakeCasServer implements CasRemote {
  FakeCasServer({this.epoch = 'e1'});

  String epoch;

  /// table -> server id -> row
  final Map<String, Map<String, Map<String, dynamic>>> tables = {};
  final List<String> calls = [];
  int _ids = 0;

  /// Makes the next write land on the server but throw to the client (lost ACK).
  bool loseNextAck = false;

  /// Runs while a write is "on the wire" (before the server handles it).
  Future<void> Function()? onWire;

  Map<String, Map<String, dynamic>> _t(String t) => tables.putIfAbsent(t, () => {});

  /// Test helper: a row written by another device / earlier state.
  Map<String, dynamic> seed(String table, Map<String, dynamic> row,
      {String? id, int revision = 1, String? lastOpId, String? deletedAt}) {
    final sid = id ?? 'srv-${++_ids}';
    final r = {
      ...row,
      'id': sid,
      'revision': revision,
      'last_op_id': lastOpId,
      'deleted_at': deletedAt,
      'updated_at': '2026-09-01T00:00:00.000Z',
    };
    _t(table)[sid] = r;
    return r;
  }

  void foreignEdit(String table, String id, Map<String, dynamic> patch) {
    final r = _t(table)[id]!;
    r.addAll(patch);
    r['revision'] = (r['revision'] as int) + 1;
    r['last_op_id'] = 'foreign-op';
  }

  void foreignTombstone(String table, String id) {
    final r = _t(table)[id]!;
    r['deleted_at'] = '2026-09-04T00:00:00.000Z';
    r['revision'] = (r['revision'] as int) + 1;
    r['last_op_id'] = 'foreign-op';
  }

  Map<String, dynamic>? byIdentity(String table, Object key) {
    final col = _identity[table] ?? 'local_id';
    for (final r in _t(table).values) {
      if (r[col] == key) return r;
    }
    return null;
  }

  CasResult _res(CasOutcome o, Map<String, dynamic>? row, {String? reason}) {
    if (loseNextAck && (o == CasOutcome.inserted || o == CasOutcome.applied)) {
      loseNextAck = false;
      throw StateError('ack lost');
    }
    return CasResult(o, row == null ? null : Map<String, dynamic>.from(row),
        reason: reason);
  }

  static Object? _n(Object? v) {
    if (v is num) return num.parse(v.toStringAsFixed(6));
    if (v is String) {
      final n = num.tryParse(v);
      if (n != null) return num.parse(n.toStringAsFixed(6));
      final t = v.trim();
      return t.isEmpty ? null : t;
    }
    return v;
  }

  @override
  Future<CasResult> insertIfAbsent({
    required String table,
    required String epoch,
    required String opId,
    required Map<String, dynamic> row,
  }) async {
    calls.add('insert:$table');
    await onWire?.call();
    if (epoch != this.epoch) return const CasResult(CasOutcome.epochMismatch, null);
    final col = _identity[table] ?? 'local_id';
    final existing = byIdentity(table, row[col] as Object);
    if (existing != null) {
      if (existing['deleted_at'] != null) return _res(CasOutcome.conflict, existing);
      if (existing['last_op_id'] == opId) return _res(CasOutcome.ack, existing);
      final keys = row.keys.where((k) => !_serverManaged.contains(k));
      final equal = keys.every((k) => _n(row[k]) == _n(existing[k]));
      return _res(equal ? CasOutcome.adopted : CasOutcome.conflict, existing);
    }
    final sid = 'srv-${++_ids}';
    final r = {
      ...row,
      'id': sid,
      'revision': 1,
      'last_op_id': opId,
      'deleted_at': null,
      'updated_at': '2026-09-02T00:00:00.000Z',
    };
    _t(table)[sid] = r;
    return _res(CasOutcome.inserted, r);
  }

  @override
  Future<CasResult> casUpdate({
    required String table,
    required String epoch,
    required String opId,
    required String serverId,
    required int expectedRevision,
    required Map<String, dynamic> patch,
  }) async {
    calls.add('update:$table');
    await onWire?.call();
    if (epoch != this.epoch) return const CasResult(CasOutcome.epochMismatch, null);
    final r = _t(table)[serverId];
    if (r == null) return const CasResult(CasOutcome.notFound, null);
    if (r['revision'] == expectedRevision && r['deleted_at'] == null) {
      patch.forEach((k, v) {
        if (k != 'user_id' && k != 'local_id') r[k] = v;
      });
      r['revision'] = expectedRevision + 1;
      r['last_op_id'] = opId;
      r['updated_at'] = '2026-09-03T00:00:00.000Z';
      return _res(CasOutcome.applied, r);
    }
    if (r['last_op_id'] == opId) return _res(CasOutcome.ack, r);
    return _res(CasOutcome.conflict, r);
  }

  @override
  Future<CasResult> casTombstone({
    required String table,
    required String epoch,
    required String opId,
    required String serverId,
    required int expectedRevision,
  }) async {
    calls.add('tombstone:$table');
    await onWire?.call();
    if (epoch != this.epoch) return const CasResult(CasOutcome.epochMismatch, null);
    final r = _t(table)[serverId];
    if (r == null) return const CasResult(CasOutcome.notFound, null);
    if (r['revision'] == expectedRevision && r['deleted_at'] == null) {
      r['deleted_at'] = '2026-09-03T00:00:00.000Z';
      r['revision'] = expectedRevision + 1;
      r['last_op_id'] = opId;
      return _res(CasOutcome.applied, r);
    }
    if (r['deleted_at'] != null) return _res(CasOutcome.ack, r);
    return _res(CasOutcome.conflict, r);
  }

  @override
  Future<Map<String, dynamic>?> fetchRow(String table, String serverId) async {
    final r = _t(table)[serverId];
    return r == null ? null : Map<String, dynamic>.from(r);
  }
}

class _FixedHead implements SeqRemote {
  const _FixedHead(this.epoch);
  final String epoch;
  @override
  Future<SyncHead?> fetchHead(String userId) async =>
      SyncHead(lastSeq: 0, epoch: epoch);
  @override
  Future<List<Map<String, dynamic>>> fetchRowsBySeq({
    required String table,
    required String userId,
    required int afterSeq,
    required int limit,
    String select = '*',
  }) async =>
      const [];
}

/// A gate reporting `revision_cas` verified (or another state) with [epoch].
RevisionCasGate casGate(
  AppDatabase db, {
  String epoch = 'e1',
  ServerCapabilityState capability = ServerCapabilityState.verified,
}) =>
    RevisionCasGate(
      db: db,
      capability: () async => capability,
      remote: _FixedHead(epoch),
    );
