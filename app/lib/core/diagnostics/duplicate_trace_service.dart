import 'package:drift/drift.dart' show QueryRow;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../data/db/app_database.dart';
import '../backend/supabase_config.dart';

/// READ-ONLY forensic tracer for duplicate transactions. Writes nothing.
///
/// Groups local `transactions` by their logical identity (the app's own
/// duplicate key: amount + currency + comparison timestamp, tolerant to the
/// minute) and, for every group with more than one row, dumps the full
/// evidence for each row and classifies which layer minted the second row.
///
/// "Server existence" runs against Supabase using the signed-in user's own
/// session (RLS-scoped), so it must be invoked on-device. When offline or
/// signed out, server columns read `unknown` rather than failing the trace.
class DuplicateTraceService {
  DuplicateTraceService(this._db);

  final AppDatabase _db;

  Future<String> run() async {
    final b = StringBuffer();
    b.writeln('══════════════ DUPLICATE TRANSACTION TRACE ══════════════');

    final rows = await _db
        .customSelect('SELECT * FROM transactions ORDER BY created_at ASC;')
        .get();
    b.writeln('total local transactions: ${rows.length}');

    final groups = <String, List<QueryRow>>{};
    for (final r in rows) {
      groups.putIfAbsent(_fingerprint(r), () => []).add(r);
    }
    final dupGroups =
        groups.entries.where((e) => e.value.length > 1).toList(growable: false);

    b.writeln('duplicate groups: ${dupGroups.length}');
    if (dupGroups.isEmpty) {
      b.writeln('✅ no duplicate transaction groups in Drift.');
      b.writeln('═════════════════════════════════════════════════════════');
      return b.toString();
    }

    final serverReachable = await _serverReachable();
    b.writeln('server reachable for existence checks: $serverReachable');

    final tally = <String, int>{};
    final accountIds = <String>{};
    var i = 0;
    for (final entry in dupGroups) {
      i++;
      final traces = <_RowTrace>[];
      for (final row in entry.value) {
        final acc = row.readNullable<String>('account_id');
        if (acc != null) accountIds.add(acc);
        traces.add(await _traceRow(row, serverReachable));
      }
      final verdict = _classify(traces);
      tally.update(verdict.label, (v) => v + 1, ifAbsent: () => 1);

      b.writeln('');
      b.writeln('════════ DUP GROUP #$i — fingerprint=${entry.key} '
          '(${traces.length} rows) ════════');
      for (var k = 0; k < traces.length; k++) {
        b.writeln(' row[$k] ${traces[k].describe()}');
      }
      b.writeln(' → CLASSIFICATION: ${verdict.label}');
      b.writeln(' → SECOND ROW PRODUCED BY: ${verdict.layer}');
      b.writeln(' → EVIDENCE: ${verdict.reason}');
    }

    await _accountsSection(b, accountIds, serverReachable);

    b.writeln('');
    b.writeln('═════════════════════ SUMMARY ═══════════════════════════');
    b.writeln('duplicate groups: ${dupGroups.length}');
    for (final e in tally.entries) {
      b.writeln('  ${e.key}: ${e.value}');
    }
    b.writeln('═════════════════════════════════════════════════════════');
    return b.toString();
  }

  /// Dumps the account picture behind the duplicates: every LOCAL account (to
  /// expose two accounts standing in for one real account), the specific
  /// account_ids referenced by the duplicate transactions, and the SERVER
  /// user_accounts rows (id + local_id) so a UUID-vs-local-id split is visible.
  Future<void> _accountsSection(
    StringBuffer b,
    Set<String> referencedAccountIds,
    bool serverReachable,
  ) async {
    b.writeln('');
    b.writeln('═════════════════════ ACCOUNTS ══════════════════════════');
    final locals = await _db
        .customSelect('SELECT id, name, currency, server_id, is_default, '
            'sort_order, deleted_at, created_at FROM accounts '
            'ORDER BY created_at ASC;')
        .get();
    b.writeln('local accounts: ${locals.length}');
    for (final a in locals) {
      b.writeln(' • id=${a.read<String>('id')} '
          'name=${a.readNullable<String>('name') ?? "-"} '
          'currency=${a.readNullable<String>('currency') ?? "-"} '
          'server_id=${a.readNullable<String>('server_id') ?? "-"} '
          'is_default=${a.readNullable<int>('is_default') ?? 0} '
          'deleted=${a.readNullable<String>('deleted_at') != null} '
          'created=${a.readNullable<String>('created_at') ?? "-"}');
    }

    b.writeln('account_ids referenced by duplicate transactions: '
        '${referencedAccountIds.length}');
    for (final id in referencedAccountIds) {
      final localRow = await _db
          .customSelect(
              "SELECT name, currency, server_id FROM accounts WHERE id = '$id' "
              'LIMIT 1;')
          .getSingleOrNull();
      var serverByLocalId = _Tri.unknown;
      var serverById = _Tri.unknown;
      if (serverReachable) {
        serverByLocalId = await _accountExists('local_id', id);
        serverById = await _accountExists('id', id);
      }
      b.writeln(' • account_id=$id '
          'local_exists=${localRow != null} '
          'local_name=${localRow?.readNullable<String>("name") ?? "-"} '
          'local_currency=${localRow?.readNullable<String>("currency") ?? "-"} '
          'local_server_id=${localRow?.readNullable<String>("server_id") ?? "-"} '
          'server(user_accounts.local_id=$id)=${serverByLocalId.s} '
          'server(user_accounts.id=$id)=${serverById.s}');
    }

    if (serverReachable) {
      try {
        final rows = await Supabase.instance.client
            .from('user_accounts')
            .select('id, local_id, name, currency, deleted_at');
        final list = (rows as List).cast<Map<String, dynamic>>();
        b.writeln('server user_accounts: ${list.length}');
        for (final s in list) {
          b.writeln('   ▸ id=${s['id']} local_id=${s['local_id']} '
              'name=${s['name']} currency=${s['currency']} '
              'deleted=${s['deleted_at'] != null}');
        }
      } catch (e) {
        b.writeln('server user_accounts: query failed ($e)');
      }
    }
    b.writeln('═════════════════════════════════════════════════════════');
  }

  Future<_Tri> _accountExists(String column, String value) async {
    try {
      final r = await Supabase.instance.client
          .from('user_accounts')
          .select('id')
          .eq(column, value)
          .maybeSingle();
      return r == null ? _Tri.no : _Tri.yes;
    } catch (_) {
      return _Tri.unknown;
    }
  }

  /// Logical identity = amount|currency|minute(comparison_ts ?? occurred_at)|
  /// merchant. This mirrors the app's own `idx_transactions_duplicate_exact`
  /// key, loosened to the minute so a re-captured SMS with a slightly different
  /// second still groups.
  String _fingerprint(QueryRow r) {
    final amount = r.readNullable<double>('amount') ?? 0;
    final currency = (r.readNullable<String>('currency') ?? '').toUpperCase();
    final ts = r.readNullable<String>('comparison_timestamp') ??
        r.read<String>('occurred_at');
    final minute = ts.length >= 16 ? ts.substring(0, 16) : ts;
    final merchant =
        (r.readNullable<String>('raw_merchant') ?? '').trim().toUpperCase();
    return '$amount|$currency|$minute|$merchant';
  }

  Future<bool> _serverReachable() async {
    if (!SupabaseConfig.isConfigured) return false;
    try {
      return Supabase.instance.client.auth.currentUser != null;
    } catch (_) {
      return false;
    }
  }

  Future<_RowTrace> _traceRow(QueryRow row, bool serverReachable) async {
    final id = row.read<String>('id');
    final serverId = row.readNullable<String>('server_id');

    final outbox = await _db.customSelect(
      "SELECT operation FROM ledger_sync_outbox WHERE transaction_id = '$id';",
    ).get();
    final outboxOps =
        outbox.map((o) => o.read<String>('operation')).toList(growable: false);

    final dedup = await _db.customSelect(
      "SELECT hash FROM dedup_hashes WHERE transaction_id = '$id';",
    ).get();
    final dedupHashes =
        dedup.map((d) => d.read<String>('hash')).toList(growable: false);

    var serverById = _Tri.unknown;
    var serverByCridLocal = _Tri.unknown;
    var serverByCridBackfill = _Tri.unknown;
    var serverDeleted = _Tri.unknown;
    if (serverReachable) {
      final client = Supabase.instance.client;
      serverById = serverId == null
          ? _Tri.no
          : await _existsById(client, serverId, (deleted) {
              serverDeleted = deleted ? _Tri.yes : _Tri.no;
            });
      serverByCridLocal = await _existsByCrid(client, id);
      serverByCridBackfill =
          await _existsByCrid(client, 'backfill_transaction_$id');
    }

    return _RowTrace(
      localId: id,
      serverId: serverId,
      amount: row.readNullable<double>('amount'),
      currency: row.readNullable<String>('currency'),
      occurredAt: row.read<String>('occurred_at'),
      comparisonTs: row.readNullable<String>('comparison_timestamp'),
      merchant: row.readNullable<String>('raw_merchant'),
      accountId: row.readNullable<String>('account_id'),
      categoryId: row.readNullable<String>('category_id'),
      source: row.read<String>('source'),
      status: row.read<String>('status'),
      syncStatus: row.readNullable<String>('sync_status'),
      duplicateStatus: row.readNullable<String>('duplicate_status'),
      possibleDuplicateOf:
          row.readNullable<String>('possible_duplicate_of_transaction_id'),
      createdAt: row.read<String>('created_at'),
      updatedAt: row.read<String>('updated_at'),
      rawMessageEmpty: row.read<String>('raw_message').isEmpty,
      outboxOps: outboxOps,
      dedupHashes: dedupHashes,
      serverById: serverById,
      serverByCridLocal: serverByCridLocal,
      serverByCridBackfill: serverByCridBackfill,
      serverDeleted: serverDeleted,
    );
  }

  Future<_Tri> _existsById(
    SupabaseClient client,
    String serverId,
    void Function(bool deleted) onDeleted,
  ) async {
    try {
      final r = await client
          .from('user_transactions')
          .select('id, deleted_at')
          .eq('id', serverId)
          .maybeSingle();
      if (r == null) return _Tri.no;
      onDeleted(r['deleted_at'] != null);
      return _Tri.yes;
    } catch (_) {
      return _Tri.unknown;
    }
  }

  Future<_Tri> _existsByCrid(SupabaseClient client, String crid) async {
    try {
      final r = await client
          .from('user_transactions')
          .select('id')
          .eq('client_request_id', crid)
          .maybeSingle();
      return r == null ? _Tri.no : _Tri.yes;
    } catch (_) {
      return _Tri.unknown;
    }
  }

  _Verdict _classify(List<_RowTrace> g) {
    // Signals across the group.
    final serverIds =
        g.map((r) => r.serverId).whereType<String>().toSet();
    final sameServerId = serverIds.length == 1 &&
        g.where((r) => r.serverId != null).length >= 2;
    final backfillPush = g.where((r) => r.serverByCridBackfill == _Tri.yes);
    final localPush = g.where((r) => r.serverByCridLocal == _Tri.yes);
    final distinctDedup = g.expand((r) => r.dedupHashes).toSet();
    final anyDoubleEnqueue = g.any((r) => r.outboxOps.length > 1);
    final importLooking = g.where((r) =>
        r.rawMessageEmpty &&
        r.dedupHashes.isEmpty &&
        r.outboxOps.isEmpty &&
        r.serverId != null);

    // 1) Two local rows pointing at the SAME server row → pull imported a copy.
    if (sameServerId) {
      return _Verdict(
        'Import collision',
        'Pull (ledger_sync_service._processRow import path)',
        'multiple local rows share server_id=${serverIds.first}; '
            '_findLocalId matched a different/none local row and re-imported.',
      );
    }
    // 2) A server row from the outbox push AND one from the backfill both exist
    //    for the same logical txn → the extra one was pulled down.
    if (backfillPush.isNotEmpty && localPush.isNotEmpty) {
      return const _Verdict(
        'Backfill collision',
        'Backfill + Pull (reconcile direct-push + outbox push, then pull)',
        'server has BOTH client_request_id=<local> and '
            'client_request_id=backfill_<local>; two server rows → pull '
            'imported the unmatched one.',
      );
    }
    // 3) Two distinct server rows exist (different server_ids) → double push.
    if (serverIds.length >= 2 &&
        g.where((r) => r.serverById == _Tri.yes).length >= 2) {
      return _Verdict(
        'Double push',
        'Push (two server rows) → Pull imported the extra',
        'group has ${serverIds.length} distinct existing server rows.',
      );
    }
    // 4) Two capture-origin rows with distinct capture-payload markers.
    if (distinctDedup.length >= 2 &&
        g.where((r) => r.dedupHashes.isNotEmpty).length >= 2) {
      return _Verdict(
        'Double capture',
        'Capture (two SMS/relay payloads ingested)',
        'distinct capture payload markers: '
            '${distinctDedup.take(4).join(", ")}',
      );
    }
    // 5) One import-looking row alongside a real one, single server row.
    if (importLooking.isNotEmpty && serverIds.length == 1) {
      return _Verdict(
        'Import collision',
        'Pull (imported a copy of the single server row)',
        'an import-looking row (empty raw_message, no dedup marker, no outbox) '
            'coexists with the origin for server_id=${serverIds.first}.',
      );
    }
    // 6) Double enqueue anomaly (does not itself mint a 2nd local row).
    if (anyDoubleEnqueue) {
      return const _Verdict(
        'Double enqueue',
        'Outbox (multiple outbox rows for one transaction_id)',
        'a transaction has >1 ledger_sync_outbox entries; verify idempotent '
            'push kept it to one server row.',
      );
    }
    // 7) All local-only with distinct capture markers → offline double capture.
    if (serverIds.isEmpty && distinctDedup.length >= 2) {
      return _Verdict(
        'Double capture',
        'Capture (offline; two payloads, not yet pushed)',
        'no server rows yet; ${distinctDedup.length} distinct payload markers.',
      );
    }
    return const _Verdict(
      'Unknown',
      'Unknown',
      'no signal matched — inspect the raw per-row evidence above.',
    );
  }
}

enum _Tri { yes, no, unknown }

extension on _Tri {
  String get s => switch (this) {
        _Tri.yes => 'YES',
        _Tri.no => 'NO',
        _Tri.unknown => '?',
      };
}

class _Verdict {
  const _Verdict(this.label, this.layer, this.reason);
  final String label;
  final String layer;
  final String reason;
}

class _RowTrace {
  _RowTrace({
    required this.localId,
    required this.serverId,
    required this.amount,
    required this.currency,
    required this.occurredAt,
    required this.comparisonTs,
    required this.merchant,
    required this.accountId,
    required this.categoryId,
    required this.source,
    required this.status,
    required this.syncStatus,
    required this.duplicateStatus,
    required this.possibleDuplicateOf,
    required this.createdAt,
    required this.updatedAt,
    required this.rawMessageEmpty,
    required this.outboxOps,
    required this.dedupHashes,
    required this.serverById,
    required this.serverByCridLocal,
    required this.serverByCridBackfill,
    required this.serverDeleted,
  });

  final String localId;
  final String? serverId;
  final double? amount;
  final String? currency;
  final String occurredAt;
  final String? comparisonTs;
  final String? merchant;
  final String? accountId;
  final String? categoryId;
  final String source;
  final String status;
  final String? syncStatus;
  final String? duplicateStatus;
  final String? possibleDuplicateOf;
  final String createdAt;
  final String updatedAt;
  final bool rawMessageEmpty;
  final List<String> outboxOps;
  final List<String> dedupHashes;
  final _Tri serverById;
  final _Tri serverByCridLocal;
  final _Tri serverByCridBackfill;
  final _Tri serverDeleted;

  String describe() {
    return 'local_id=$localId server_id=${serverId ?? "-"} '
        'amount=$amount ${currency ?? "-"} '
        'occurred=$occurredAt comparison_ts=${comparisonTs ?? "-"} '
        'merchant=${merchant ?? "-"} account=${accountId ?? "-"} '
        'category=${categoryId ?? "-"} source=$source status=$status '
        'sync_status=${syncStatus ?? "-"} dup_status=${duplicateStatus ?? "-"} '
        'possible_dup_of=${possibleDuplicateOf ?? "-"} '
        'created=$createdAt updated=$updatedAt raw_empty=$rawMessageEmpty '
        'outbox=${outboxOps.isEmpty ? "NO" : outboxOps.join("+")} '
        'dedup_markers=${dedupHashes.isEmpty ? "[]" : dedupHashes.join(",")} '
        'server(by_id)=${serverById.s} '
        'server(crid=local)=${serverByCridLocal.s} '
        'server(crid=backfill)=${serverByCridBackfill.s} '
        'server_deleted=${serverDeleted.s}';
  }
}
