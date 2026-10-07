import 'dart:convert';

import '../../data/db/app_database.dart';
import '../../data/db/sql_value_codec.dart';
import '../sync/conflict_policy.dart';
import '../sync/outbox_operation_id.dart';
import '../sync/sync_conflict_store.dart';
import '../utils/id_generator.dart';

/// WP-7 / manifest §4.10 — the recovery of one replica's unsynced work into the
/// FRESH replica a rebootstrap built from the server.
///
/// [old] is only ever read; every write goes to [fresh], one local transaction
/// per step, and every step is decided from what [fresh] already holds, so a
/// step a crash interrupted is simply run again (the durable phase marker lives
/// in the replica registry, see `RebootstrapPhase`).
///
/// Rules (all keyed by `client_request_id`, which for the ledger IS the local
/// transaction id, I-5 / §4.11):
///   * a recovered row replaces the pulled copy of the same entity but keeps its
///     OLD base tokens (`server_updated_at`, `server_revision`), so the push
///     compare-and-set detects every server change since and raises the normal
///     conflict; nothing is overwritten silently;
///   * a cloud TOMBSTONE always wins over an older recovered create or edit: the
///     recovered transaction is stored as an ignored conflict record, never as
///     an active transaction;
///   * a pending create whose identity the server already holds is adopted when
///     the client-owned fields are equal, and otherwise kept as a conflict;
///   * the outbox is replayed as NEW operations (fresh ids; the old operation id
///     is remembered as a prior op so a lost ACK is still recognised).
///
/// Server-owned columns never need copying: the fresh replica was pulled to the
/// server head. Device-local state that is not in the ledger (consent) is copied
/// by [seedDeviceLocalState] before that pull.
class ReplicaRecovery {
  ReplicaRecovery({
    required this.old,
    required this.fresh,
    required this.lookup,
  });

  final AppDatabase old;
  final AppDatabase fresh;
  final LedgerServerLookup lookup;

  late final SyncConflictStore _conflicts = SyncConflictStore(fresh);
  final Map<String, List<String>> _cols = {};

  // ---------------------------------------------------------------- plumbing

  Future<List<Rec>> _select(AppDatabase db, String sql) async =>
      [for (final r in await db.customSelect(sql).get()) Rec.of(r.data)];

  Future<Rec?> _one(AppDatabase db, String sql) async {
    final rows = await _select(db, '$sql LIMIT 1');
    return rows.isEmpty ? null : rows.single;
  }

  Future<List<String>> _columns(AppDatabase db, String table) async {
    final key = '${identical(db, old) ? 'o' : 'f'}:$table';
    return _cols[key] ??= [
      for (final r in await db.customSelect('PRAGMA table_info($table);').get())
        r.read<String>('name'),
    ];
  }

  /// [row] reduced to the columns [fresh] has (the two replicas run the same
  /// schema; this only protects against a column the build adds later).
  Future<Rec> _fit(String table, Rec row) async {
    final have = (await _columns(fresh, table)).toSet();
    return Rec.of({
      for (final e in row.entries)
        if (have.contains(e.key)) e.key: e.value,
    });
  }

  Future<void> _put(String table, Rec row, {String verb = 'INSERT'}) async {
    final r = await _fit(table, row);
    final cols = r.keys.toList();
    await fresh.customStatement(
      '$verb INTO $table(${cols.join(', ')}) '
      'VALUES (${List.filled(cols.length, '?').join(', ')});',
      [for (final c in cols) r[c]],
    );
  }

  Future<bool> _freshHas(String table, String where) async =>
      (await _one(fresh, 'SELECT 1 AS x FROM $table WHERE $where')) != null;

  // ------------------------------------------------- device-local seed (pre-pull)

  /// Copies the device-local settings row (consent, preferences) so the pull into
  /// the fresh replica runs under the consent the user already gave; without it
  /// the consent-gated pull would not run at all.
  Future<void> seedDeviceLocalState() async {
    final rows = await _select(old, 'SELECT * FROM user_settings');
    await fresh.transaction(() async {
      for (final r in rows) {
        await _put('user_settings', r, verb: 'INSERT OR REPLACE');
      }
    });
  }

  // ------------------------------------------------------------- receipts

  /// Capture receipts and the review rows they point at (I-3). Copied BEFORE any
  /// row merge, so a capture whose receipt committed can never be imported again
  /// from the native queue.
  Future<void> recoverReceipts() async {
    final receipts = await _select(
        old, "SELECT * FROM dedup_hashes WHERE hash LIKE 'capture_payload:%'");
    final reviews = await _select(
        old, "SELECT * FROM smart_inbox_items WHERE id LIKE 'local_capture:%'");
    await fresh.transaction(() async {
      for (final r in receipts) {
        await _put('dedup_hashes', r, verb: 'INSERT OR IGNORE');
      }
      for (final r in reviews) {
        await _put('smart_inbox_items', r, verb: 'INSERT OR IGNORE');
      }
    });
  }

  // ---------------------------------------------------------------- row merge

  static const _parents = <_Family>[
    _Family('accounts', ConflictEntities.account, {}),
    _Family('cards', ConflictEntities.card, {'account_id': 'accounts'}),
    _Family('budgets', ConflictEntities.budget,
        {'account_id': 'accounts', 'category_id': 'categories'}),
    _Family('goals', ConflictEntities.goal, {'account_id': 'accounts'}),
    _Family('subscriptions', ConflictEntities.subscription,
        {'account_id': 'accounts', 'merchant_id': 'merchants'}),
    _Family('plans', ConflictEntities.plan, {}),
  ];

  static const _transactions = _Family(
    'transactions',
    ConflictEntities.transaction,
    {
      'account_id': 'accounts',
      'category_id': 'categories',
      'merchant_id': 'merchants',
    },
  );

  /// Immutable children: dirty exactly when the old planning outbox holds an op
  /// for them. (table, entity type, fk map, primary-key columns.)
  static const _children = <_Child>[
    _Child('goal_contributions', ConflictEntities.goalContribution,
        {'goal_id': 'goals'}, ['id']),
    _Child('bill_payments', ConflictEntities.billPayment,
        {'bill_id': 'subscriptions', 'transaction_id': 'transactions'}, ['id']),
  ];

  /// Rows that reference a replaced parent (so they can be re-pointed to the
  /// recovered id before the pulled copy is deleted).
  static const _dependents = <String, List<(String, String)>>{
    'accounts': [
      ('transactions', 'account_id'),
      ('cards', 'account_id'),
      ('budgets', 'account_id'),
      ('goals', 'account_id'),
      ('subscriptions', 'account_id'),
    ],
    'goals': [('goal_contributions', 'goal_id')],
    'subscriptions': [('bill_payments', 'bill_id')],
    'plans': [('plan_transaction_links', 'plan_id')],
    'transactions': [
      ('plan_transaction_links', 'transaction_id'),
      ('bill_payments', 'transaction_id'),
    ],
  };

  String _dirty(String table, String entity) => '''
    (t.sync_status IN ('pending','conflict','local_only') OR t.server_id IS NULL
     OR EXISTS(SELECT 1 FROM ${entity == ConflictEntities.transaction ? "ledger_sync_outbox o WHERE o.transaction_id = t.id" : "planning_sync_outbox o WHERE o.entity_type = ${sqlString(entity)} AND o.entity_id = t.id"}))
    AND NOT (${table == 'transactions' ? "t.status = 'ignored'" : 't.deleted_at IS NOT NULL'}
             AND t.server_id IS NULL
             AND NOT EXISTS(SELECT 1 FROM ${entity == ConflictEntities.transaction ? "ledger_sync_outbox o WHERE o.transaction_id = t.id" : "planning_sync_outbox o WHERE o.entity_type = ${sqlString(entity)} AND o.entity_id = t.id"}))''';

  Future<List<Rec>> _dirtyRows(_Family f) =>
      _select(old, 'SELECT t.* FROM ${f.table} t WHERE ${_dirty(f.table, f.entity)} ORDER BY t.id');

  /// Merges every recoverable local row (parents, then transactions, then
  /// children) into [fresh]. Throws [RecoveryIncompleteException] when a row
  /// cannot be placed (the swap must not happen).
  Future<void> mergeRows() async {
    final txs = await _dirtyRows(_transactions);
    // The cloud's view of the recovered creates, read before the local
    // transaction (it is the only network step of the merge).
    final createIds = {
      for (final t in txs)
        if (t['server_id'] == null) t['id']! as String,
    };
    final cloud = createIds.isEmpty
        ? const <String, Map<String, dynamic>>{}
        : await lookup.byClientRequestId(createIds);

    var unplaced = 0;
    await fresh.transaction(() async {
      await fresh.customStatement('PRAGMA defer_foreign_keys = ON;');
      for (final f in _parents) {
        for (final t in await _dirtyRows(f)) {
          if (!await _mergeParent(f, t)) unplaced++;
        }
      }
      for (final t in txs) {
        if (!await _mergeTransaction(t, cloud[t['id']])) unplaced++;
      }
      for (final c in _children) {
        final rows = await _select(old, '''
          SELECT t.* FROM ${c.table} t WHERE EXISTS(SELECT 1 FROM planning_sync_outbox o
            WHERE o.entity_type = ${sqlString(c.entity)} AND o.entity_id = t.id)
          ORDER BY t.id''');
        for (final t in rows) {
          if (!await _mergeChild(c, t)) unplaced++;
        }
      }
      for (final r in await _select(old, '''
          SELECT l.* FROM plan_transaction_links l WHERE l.deleted_at IS NULL AND EXISTS(
            SELECT 1 FROM planning_sync_outbox o WHERE
              o.entity_type = ${sqlString(ConflictEntities.planLink)}
              AND o.entity_id = l.plan_id || ':' || l.transaction_id)''')) {
        if (!await _mergePlanLink(r)) unplaced++;
      }
    });
    if (unplaced > 0) throw RecoveryIncompleteException(unplaced);
  }

  /// Old local id -> the id the same entity has in [fresh] (copying a missing
  /// category / merchant by its natural key). Null when it has no counterpart.
  Future<String?> _remap(String parent, String? oldId) async {
    if (oldId == null) return null;
    switch (parent) {
      case 'categories':
        final o = await _one(
            old, 'SELECT * FROM categories WHERE id = ${sqlString(oldId)}');
        if (o == null) return null;
        final f = await _one(fresh,
            'SELECT id FROM categories WHERE key = ${sqlString(o['key']! as String)}');
        if (f != null) return f['id']! as String;
        await _put('categories', o, verb: 'INSERT OR IGNORE');
        return oldId;
      case 'merchants':
        final o = await _one(
            old, 'SELECT * FROM merchants WHERE id = ${sqlString(oldId)}');
        if (o == null) return null;
        final f = await _one(fresh,
            'SELECT id FROM merchants WHERE normalized_name = ${sqlString(o['normalized_name']! as String)}');
        if (f != null) return f['id']! as String;
        await _put('merchants', o, verb: 'INSERT OR IGNORE');
        return oldId;
      default:
        // Old ids stay valid everywhere (payloads, links): a pulled twin is
        // re-keyed to the old id instead of the recovered row taking a new one.
        if (await _freshHas(parent, 'id = ${sqlString(oldId)}')) return oldId;
        final o = await _one(
            old, 'SELECT server_id FROM $parent WHERE id = ${sqlString(oldId)}');
        final serverId = o?['server_id'] as String?;
        if (serverId == null) return null;
        final f = await _one(fresh,
            'SELECT id FROM $parent WHERE server_id = ${sqlString(serverId)}');
        if (f == null) return null;
        await _rekey(parent, f['id']! as String, oldId);
        return oldId;
    }
  }

  Future<void> _rekey(String table, String from, String to) async {
    for (final (dep, col) in _dependents[table] ?? const []) {
      await fresh.customStatement(
          'UPDATE $dep SET $col = ${sqlString(to)} WHERE $col = ${sqlString(from)};');
    }
    await fresh.customStatement(
        'UPDATE $table SET id = ${sqlString(to)} WHERE id = ${sqlString(from)};');
  }

  /// [row] with every foreign key re-pointed into [fresh]. Null when a required
  /// parent has no counterpart (the row cannot be placed).
  Future<Rec?> _remapRow(Rec row, Map<String, String> fk,
      {required Set<String> required}) async {
    final out = Rec.of(row);
    for (final e in fk.entries) {
      final mapped = await _remap(e.value, row[e.key] as String?);
      if (mapped == null && row[e.key] != null && required.contains(e.key)) {
        return null;
      }
      out[e.key] = mapped;
    }
    return out;
  }

  Future<Rec?> _freshFor(String table, Rec t) async {
    var f = await _one(fresh,
        'SELECT * FROM $table WHERE id = ${sqlString(t['id']! as String)}');
    final serverId = t['server_id'] as String?;
    if (f == null && serverId != null) {
      f = await _one(fresh,
          'SELECT * FROM $table WHERE server_id = ${sqlString(serverId)}');
    }
    return f;
  }

  /// The pulled copy is a live synced row: the only state a recovery may replace.
  bool _isPulled(Rec f) => f['server_id'] != null && f['sync_status'] == 'synced';

  /// Re-points rows that reference [fromId] and deletes the pulled copy.
  Future<void> _replacePulled(String table, Rec f, String newId) async {
    final fromId = f['id']! as String;
    if (fromId != newId) {
      for (final (dep, col) in _dependents[table] ?? const []) {
        await fresh.customStatement(
            'UPDATE $dep SET $col = ${sqlString(newId)} WHERE $col = ${sqlString(fromId)};');
      }
    }
    await fresh
        .customStatement('DELETE FROM $table WHERE id = ${sqlString(fromId)};');
  }

  Future<bool> _mergeParent(_Family fam, Rec t) async {
    final f = await _freshFor(fam.table, t);
    if (f != null && !_isPulled(f)) return true; // already recovered
    final m = await _remapRow(t, fam.fk, required: {'category_id'});
    if (m == null) return false;
    if (t['server_id'] == null) {
      if (f != null) return true; // a server twin of a never-synced row: adopt
      await _put(fam.table, m);
      return true;
    }
    if (f == null) {
      // The cloud no longer has it (deleted elsewhere): the local row stays,
      // flagged, exactly as a pulled tombstone against a pending edit does.
      await _put(fam.table, m);
      await _conflicts.flag(
          entityType: fam.entity,
          localId: t['id']! as String,
          kind: SyncConflictKind.tombstone,
          serverId: t['server_id'] as String?);
      return true;
    }
    await _replacePulled(fam.table, f, t['id']! as String);
    await _put(fam.table, m);
    return true;
  }

  Future<bool> _mergeTransaction(Rec t, Map<String, dynamic>? cloudRow) async {
    final id = t['id']! as String;
    final f = await _freshFor('transactions', t);
    if (f != null && !_isPulled(f)) return true; // already recovered
    final m = await _remapRow(t, _transactions.fk, required: const {});
    if (m == null) return false;

    final tombstoned = cloudRow != null && cloudRow['deleted_at'] != null;
    final serverBacked = t['server_id'] != null;

    // §4.10: a tombstone wins over an older recovered create or edit. The
    // recovered record is kept as an IGNORED conflict (its original values stay
    // in the conflict's `mine`), so it can never count as an active transaction.
    if (tombstoned || (serverBacked && f == null)) {
      final mine = await _snapshot(t);
      if (f != null) await _replacePulled('transactions', f, id);
      await _put('transactions', {
        ...m,
        'status': 'ignored',
        'sync_status': 'conflict',
      });
      await _conflicts.flag(
        entityType: ConflictEntities.transaction,
        localId: id,
        kind: SyncConflictKind.tombstone,
        serverId: (cloudRow?['id'] ?? t['server_id']) as String?,
        mine: mine,
        theirs: tombstoned ? cloudRow : null,
        theirsRevision: (cloudRow?['revision'] as num?)?.toInt(),
      );
      return true;
    }

    if (!serverBacked) {
      if (f == null) {
        await _put('transactions', m); // the cloud never saw it: recreate by op
        return true;
      }
      // The server already holds this identity. Equal client-owned fields: adopt
      // the cloud row (A17). Different: keep the user's version as a conflict.
      if (await _sameClientFields(t, f)) return true;
      final mine = await _snapshot(t);
      await _replacePulled('transactions', f, id);
      await _put('transactions', {...m, 'sync_status': 'conflict'});
      await _conflicts.flag(
        entityType: ConflictEntities.transaction,
        localId: id,
        kind: SyncConflictKind.create,
        serverId: f['server_id'] as String?,
        mine: mine,
        theirs: cloudRow,
        theirsRevision: (cloudRow?['revision'] as num?)?.toInt(),
      );
      return true;
    }

    // A previously synced row with local work: it replaces the pulled copy and
    // keeps its old base, so the push detects whatever the server did since.
    await _replacePulled('transactions', f!, id);
    await _put('transactions', m);
    return true;
  }

  static const _clientFields = [
    'amount_minor',
    'currency',
    'type',
    'direction',
    'status',
    'occurred_at',
    'raw_merchant',
    'note',
    'card_last4',
    'foreign_amount_minor',
    'foreign_currency',
  ];

  Future<bool> _sameClientFields(Rec a, Rec b) async {
    for (final c in _clientFields) {
      if ('${a[c]}' != '${b[c]}') return false;
    }
    return await _categoryKey(old, a['category_id'] as String?) ==
        await _categoryKey(fresh, b['category_id'] as String?);
  }

  Future<String?> _categoryKey(AppDatabase db, String? id) async => id == null
      ? null
      : (await _one(db, 'SELECT key FROM categories WHERE id = ${sqlString(id)}'))?['key']
          as String?;

  /// The recovered row as the conflict store snapshots a local record, taken from
  /// [old] (the user's version), with its stable category key.
  Future<Map<String, dynamic>> _snapshot(Rec t) async => {
        ...t,
        'category_key': await _categoryKey(old, t['category_id'] as String?),
      };

  Future<bool> _mergeChild(_Child c, Rec t) async {
    if (await _freshHas(c.table, 'id = ${sqlString(t['id']! as String)}')) {
      return true;
    }
    final m = await _remapRow(t, c.fk, required: {for (final k in c.fk.keys) k});
    if (m == null) return false;
    await _put(c.table, m, verb: 'INSERT OR IGNORE');
    return true;
  }

  Future<bool> _mergePlanLink(Rec t) async {
    final m = await _remapRow(
        t, {'plan_id': 'plans', 'transaction_id': 'transactions'},
        required: {'plan_id', 'transaction_id'});
    if (m == null) return false;
    await _put('plan_transaction_links', m, verb: 'INSERT OR IGNORE');
    return true;
  }

  // ------------------------------------------------------------------- outbox

  /// Replays the old outbox as NEW operations against the recovered rows. An op
  /// is replayed only for a row that is still pending in [fresh]: an adopted
  /// (synced) row has nothing left to send and a conflicted row waits for its
  /// resolution, which re-enqueues. The old operation id is remembered as a prior
  /// op, so an op that had reached the server before the ACK was lost is still
  /// recognised as ours.
  Future<void> recoverOutbox() async {
    final ledger = await _select(
        old, 'SELECT * FROM ledger_sync_outbox ORDER BY op_seq, created_at, id');
    final planning = await _select(old,
        'SELECT * FROM planning_sync_outbox ORDER BY op_seq, created_at, id');
    await fresh.transaction(() async {
      for (final op in ledger) {
        final txId = op['transaction_id']! as String;
        final row = await _one(fresh,
            'SELECT sync_status, server_revision FROM transactions WHERE id = ${sqlString(txId)}');
        if (row == null || row['sync_status'] == 'conflict') continue;
        if (row['sync_status'] == 'synced') continue;
        if (await _freshHas(
            'ledger_sync_outbox', 'transaction_id = ${sqlString(txId)}')) {
          continue;
        }
        await _replay('ledger_sync_outbox', op, row['server_revision'] as int?);
      }
      for (final op in planning) {
        final entity = op['entity_type']! as String;
        final id = op['entity_id']! as String;
        final target = _planningTarget(entity, id);
        if (target == null) continue; // a command with no row to replay against
        final row = await _one(fresh,
            'SELECT sync_status, ${target.hasRevision ? 'server_revision' : 'NULL'} AS server_revision FROM ${target.table} WHERE ${target.where}');
        if (row == null || row['sync_status'] == 'conflict') continue;
        if (row['sync_status'] == 'synced') continue;
        if (await _freshHas('planning_sync_outbox',
            'entity_type = ${sqlString(entity)} AND entity_id = ${sqlString(id)}')) {
          continue;
        }
        await _replay('planning_sync_outbox', op, row['server_revision'] as int?);
      }
    });
  }

  ({String table, String where, bool hasRevision})? _planningTarget(
      String entity, String id) {
    final byId = 'id = ${sqlString(id)}';
    return switch (entity) {
      ConflictEntities.account =>
        (table: 'accounts', where: byId, hasRevision: true),
      ConflictEntities.card => (table: 'cards', where: byId, hasRevision: true),
      ConflictEntities.budget =>
        (table: 'budgets', where: byId, hasRevision: true),
      ConflictEntities.goal => (table: 'goals', where: byId, hasRevision: true),
      ConflictEntities.subscription =>
        (table: 'subscriptions', where: byId, hasRevision: true),
      ConflictEntities.plan => (table: 'plans', where: byId, hasRevision: true),
      ConflictEntities.settings =>
        (table: 'user_settings', where: byId, hasRevision: true),
      ConflictEntities.goalContribution =>
        (table: 'goal_contributions', where: byId, hasRevision: false),
      ConflictEntities.billPayment =>
        (table: 'bill_payments', where: byId, hasRevision: false),
      ConflictEntities.planLink => id.contains(':')
          ? (
              table: 'plan_transaction_links',
              where:
                  "plan_id = ${sqlString(id.split(':').first)} AND transaction_id = ${sqlString(id.split(':').last)}",
              hasRevision: false,
            )
          : null,
      _ => null,
    };
  }

  Future<void> _replay(String table, Rec op, int? baseRevision) async {
    final payload = (jsonDecode(op['payload_json']! as String) as Map)
        .cast<String, dynamic>();
    final oldOpId = op['operation_id'] as String?;
    if (oldOpId != null) {
      final prior = priorOpIdsOf(payload);
      if (!prior.contains(oldOpId)) payload[kPriorOpIdsKey] = [...prior, oldOpId];
    }
    final now = dateTimeToSql(DateTime.now().toUtc());
    await _put(table, {
      ...op,
      'id': IdGenerator.next(),
      'payload_json': jsonEncode(payload),
      'attempt_count': 0,
      'last_error': null,
      'next_retry_at': null,
      'status': 'pending',
      'failure_class': null,
      'in_flight_seq': null,
      'operation_id': IdGenerator.uuidV4(),
      'base_revision':
          op['operation'] == 'create' ? null : (baseRevision ?? op['base_revision']),
      'created_at': op['created_at'],
      'updated_at': now,
    });
  }

  // ---------------------------------------------------------------- conflicts

  /// Carries the unresolved conflicts over (the record, and the entity flag). A
  /// conflict the merge already raised in [fresh] is kept as it is.
  Future<void> mergeConflicts() async {
    final open = await _select(old,
        'SELECT * FROM sync_conflicts WHERE resolved_at IS NULL ORDER BY created_at, id');
    await fresh.transaction(() async {
      for (final c in open) {
        final entity = c['entity_type']! as String;
        final localId = c['local_id']! as String;
        if (await _freshHas('sync_conflicts',
            'entity_type = ${sqlString(entity)} AND local_id = ${sqlString(localId)} AND resolved_at IS NULL')) {
          continue;
        }
        final table = conflictPolicyFor(entity).localTable;
        if (!await _freshHas(table, 'id = ${sqlString(localId)}')) continue;
        await _put('sync_conflicts', {...c, 'id': IdGenerator.next()});
        await fresh.customStatement(
            "UPDATE $table SET sync_status = 'conflict' WHERE id = ${sqlString(localId)};");
      }
      // Quarantined pull rows (integrity / retry) are kept for diagnostics.
      for (final r in await _select(old, 'SELECT * FROM parked_child_rows')) {
        await _put('parked_child_rows', r, verb: 'INSERT OR IGNORE');
      }
      // Smart Inbox changes the user made that were not pushed yet.
      for (final r in await _select(
          old, 'SELECT * FROM smart_inbox_items WHERE pending_sync = 1')) {
        await _put('smart_inbox_items', r, verb: 'INSERT OR REPLACE');
      }
    });
  }

  // ------------------------------------------------------------------- verify

  /// Nothing recoverable may be missing from [fresh] before the swap. Throws
  /// [RecoveryIncompleteException] (count only, never content) otherwise; the
  /// old replica is untouched either way.
  Future<void> verify() async {
    var missing = 0;
    for (final r in await _select(old,
        "SELECT hash FROM dedup_hashes WHERE hash LIKE 'capture_payload:%'")) {
      if (!await _freshHas(
          'dedup_hashes', 'hash = ${sqlString(r['hash']! as String)}')) {
        missing++;
      }
    }
    for (final t in await _dirtyRows(_transactions)) {
      if (await _freshFor('transactions', t) == null) missing++;
    }
    for (final f in _parents) {
      for (final t in await _dirtyRows(f)) {
        if (await _freshFor(f.table, t) == null) missing++;
      }
    }
    for (final c in await _select(
        old, 'SELECT entity_type, local_id FROM sync_conflicts WHERE resolved_at IS NULL')) {
      final table = conflictPolicyFor(c['entity_type']! as String).localTable;
      final rowThere =
          await _freshHas(table, 'id = ${sqlString(c['local_id']! as String)}');
      if (rowThere &&
          !await _freshHas('sync_conflicts',
              'entity_type = ${sqlString(c['entity_type']! as String)} AND local_id = ${sqlString(c['local_id']! as String)} AND resolved_at IS NULL')) {
        missing++;
      }
    }
    if (missing > 0) throw RecoveryIncompleteException(missing);
  }
}

typedef Rec = Map<String, Object?>;

class _Family {
  const _Family(this.table, this.entity, this.fk);
  final String table;
  final String entity;
  final Map<String, String> fk;
}

class _Child {
  const _Child(this.table, this.entity, this.fk, this.pk);
  final String table;
  final String entity;
  final Map<String, String> fk;
  final List<String> pk;
}

/// The cloud's rows for a set of client request ids, tombstones INCLUDED
/// (`deleted_at` set). Implemented over PostgREST in the app.
abstract interface class LedgerServerLookup {
  Future<Map<String, Map<String, dynamic>>> byClientRequestId(Set<String> ids);
}

/// A recoverable item could not be placed in the fresh replica. Carries a count
/// only. The swap does not happen and the old replica stays authoritative.
class RecoveryIncompleteException implements Exception {
  const RecoveryIncompleteException(this.count);
  final int count;
  @override
  String toString() => 'RecoveryIncompleteException($count)';
}
