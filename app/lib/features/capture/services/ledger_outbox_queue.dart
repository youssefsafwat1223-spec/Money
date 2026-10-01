import 'dart:convert';

import '../../../core/sync/outbox_failure.dart';
import '../../../core/sync/outbox_owner.dart';
import '../../../core/utils/id_generator.dart';
import '../../../data/db/app_database.dart';
import '../../../data/db/planning_cutover.dart';
import '../../../data/db/sql_value_codec.dart';
import '../../../data/sync/transaction_server_mappers.dart';
import '../../../domain/entities/transaction_entity.dart';
import '../../../domain/finance/money.dart';
import '../../../domain/finance/money_transport.dart';
import 'ledger_payload.dart';

enum OutboxOperation { create, update, delete }

class OutboxItem {
  const OutboxItem({
    required this.id,
    required this.transactionId,
    required this.operation,
    required this.payloadJson,
    required this.attemptCount,
    this.opSeq = 0,
    this.ownerUid,
    this.lastError,
    this.nextRetryAt,
  });

  final String id;
  final String transactionId;
  final OutboxOperation operation;
  final Map<String, dynamic> payloadJson;
  final int attemptCount;

  /// A-2 (G3): the row's edit counter when it was read. An ACK deletes the row
  /// only while this still matches, so an edit folded in while the push was in
  /// flight is never lost.
  final int opSeq;

  /// A-2 (G18): the local-data owner the row was recorded for (null = legacy).
  final String? ownerUid;
  final String? lastError;
  final DateTime? nextRetryAt;
}

class LedgerOutboxQueue {
  LedgerOutboxQueue({
    required AppDatabase db,
    required bool Function() isPushEnabled,
    required Future<String?> Function() getAuthUserId,
    // A-2 (G18/G5): the LOCAL DATA OWNER uid (AppSession's owner marker) — the
    // identity admitted as owner of this local DB. Rows are stamped with it and
    // intent is recorded whenever it exists, even if the live session is
    // momentarily absent. Defaults to [getAuthUserId] for callers that have no
    // separate owner concept.
    Future<String?> Function()? getOwnerUid,
    void Function()? onQueued,
    // MALI-026 (B8-2.10 §10): the money-authority mode. Legacy (v29 today) emits
    // the current JSON-number wire shape; canonical emits the exact decimal
    // STRING. Defaults to legacy, so today's payloads are byte-identical.
    PlanningCutoverCoordinator coordinator =
        const SchemaV29PlanningCutoverCoordinator(),
  })  : _db = db,
        _isPushEnabled = isPushEnabled,
        _getAuthUserId = getAuthUserId,
        _getOwnerUid = getOwnerUid ?? getAuthUserId,
        _onQueued = onQueued,
        _coordinator = coordinator;

  final AppDatabase _db;
  final bool Function() _isPushEnabled;
  final Future<String?> Function() _getAuthUserId;
  final Future<String?> Function() _getOwnerUid;
  final void Function()? _onQueued;
  final PlanningCutoverCoordinator _coordinator;

  Future<void> enqueue(
    OutboxOperation op,
    TransactionEntity tx,
  ) async {
    // A-2 (G5): a local mutation records sync intent whenever a local owner
    // identity exists — even with no live session right now or the push flag off
    // (the push service still requires both before anything is sent). ONLY a
    // true guest (no owner uid and no session) stays local-only with no intent.
    final intent = await resolveOutboxIntent(_getOwnerUid, _getAuthUserId);
    if (intent == null) return;
    final ownerUid = intent.ownerUid;

    final now = dateTimeToSql(DateTime.now().toUtc());
    final payload = _buildPayload(op, tx);

    // MALI-022 / 0068 — attach the locally-cached server revision as the CAS
    // base token. Phase-9K: deletes carry it too, so the tombstone is a GUARDED
    // compare-and-set (a stale delete can never overwrite a newer accepted
    // update), not an unconditional overwrite. Null (unknown revision) is left
    // absent → the push uses the guarded server_updated_at compare.
    final revRow = await _db
        .customSelect(
          'SELECT server_revision FROM transactions '
          'WHERE id = ${sqlString(tx.id)} LIMIT 1;',
        )
        .getSingleOrNull();
    final baseRevision = revRow?.readNullable<int>('server_revision');
    if (baseRevision != null) payload['server_revision'] = baseRevision;

    await _db.transaction(() async {
      // MALI-052n: coalesce into any existing PENDING row for this transaction
      // (or a row parked by the A-2 self-healing layer, which is never in
      // flight). Every coalesce bumps op_seq (A-2 G3).
      final existing = await _db
          .customSelect(
            "SELECT id, operation, status, in_flight_seq FROM ledger_sync_outbox "
            "WHERE transaction_id = ${sqlString(tx.id)} AND $kOutboxCoalescibleSql "
            "ORDER BY created_at ASC LIMIT 1;",
          )
          .getSingleOrNull();
      if (existing != null) {
        final existingId = existing.read<String>('id');
        final coalesced = coalesceOutboxOperation(
            existing.read<String>('operation'), op.name);
        if (coalesced == null &&
            (existing.read<String>('status') == 'parked' ||
                existing.readNullable<int>('in_flight_seq') == null)) {
          // Never on the wire (parked, or never handed to a push — the durable
          // in_flight_seq marker is NULL): create+delete truly cancels.
          await _db.customStatement(
            'DELETE FROM ledger_sync_outbox WHERE id = ${sqlString(existingId)};',
          );
        } else {
          // A-2 (G3): a create cancelled by a delete while it is IN FLIGHT is
          // never dropped — it becomes a delete. The push resolves it by
          // client_request_id: confirmed-absent is ACKed, a row that landed is
          // tombstoned. Nothing is silently lost.
          await _db.customStatement('''
            UPDATE ledger_sync_outbox
            SET operation = ${sqlString(coalesced ?? 'delete')},
                payload_json = ${sqlString(jsonEncode(payload))},
                attempt_count = 0, status = 'pending', failure_class = NULL,
                last_error = NULL, next_retry_at = NULL,
                op_seq = op_seq + 1,
                owner_uid = COALESCE(owner_uid, ${sqlNullableString(ownerUid)}),
                updated_at = ${sqlString(now)}
            WHERE id = ${sqlString(existingId)};
          ''');
        }
      } else {
        await _db.customStatement('''
          INSERT INTO ledger_sync_outbox(
            id, transaction_id, operation, payload_json,
            attempt_count, status, created_at, updated_at, op_seq, owner_uid
          ) VALUES (
            ${sqlString(IdGenerator.next())}, ${sqlString(tx.id)},
            ${sqlString(op.name)}, ${sqlString(jsonEncode(payload))},
            0, 'pending', ${sqlString(now)}, ${sqlString(now)},
            1, ${sqlNullableString(ownerUid)}
          );
        ''');
      }
      await _db.customStatement('''
        UPDATE transactions
        SET sync_status = 'pending'
        WHERE id = ${sqlString(tx.id)};
      ''');
    });
    if (_isPushEnabled()) _onQueued?.call();
  }

  Future<List<OutboxItem>> pendingItems({int limit = 50}) async {
    final now = dateTimeToSql(DateTime.now().toUtc());
    // A-3: hand-out and the durable "possibly sent" marker are ONE transaction.
    final rows = await _db.transaction(() async {
      final picked = await _db.customSelect('''
        SELECT id, transaction_id, operation, payload_json,
               attempt_count, last_error, next_retry_at, op_seq, owner_uid
        FROM ledger_sync_outbox
        WHERE status = 'pending'
          AND (next_retry_at IS NULL OR next_retry_at <= ${sqlString(now)})
        ORDER BY created_at ASC
        LIMIT $limit;
      ''').get();
      for (final row in picked) {
        await _db.customStatement(
          'UPDATE ledger_sync_outbox SET in_flight_seq = op_seq '
          'WHERE id = ${sqlString(row.read<String>('id'))};',
        );
      }
      return picked;
    });
    return rows.map((row) {
      final opStr = row.read<String>('operation');
      final op = OutboxOperation.values.firstWhere(
        (e) => e.name == opStr,
        orElse: () => OutboxOperation.update,
      );
      final retryStr = row.readNullable<String>('next_retry_at');
      return OutboxItem(
        id: row.read<String>('id'),
        transactionId: row.read<String>('transaction_id'),
        operation: op,
        payloadJson:
            (jsonDecode(row.read<String>('payload_json')) as Map).cast(),
        attemptCount: row.read<int>('attempt_count'),
        opSeq: row.read<int>('op_seq'),
        ownerUid: row.readNullable<String>('owner_uid'),
        lastError: row.readNullable<String>('last_error'),
        nextRetryAt:
            retryStr == null ? null : DateTime.tryParse(retryStr)?.toUtc(),
      );
    }).toList();
  }

  /// A-2 (G3): ACK [item]. The row is deleted ONLY while its `op_seq` still
  /// equals the one that was pushed. If the entity was edited while the push was
  /// in flight the edit was folded into this same row (op_seq bumped): the row
  /// stays pending, carrying the server id/version this ACK just produced as its
  /// new base, so the next cycle is an UPDATE of the same server row — and the
  /// caller must NOT mark the entity synced. Returns true when the row was
  /// consumed.
  Future<bool> acknowledge(
    OutboxItem item, {
    String? serverId,
    String? serverUpdatedAt,
    int? serverRevision,
  }) {
    return _db.transaction(() async {
      final deleted = await _db.customUpdate(
        'DELETE FROM ledger_sync_outbox '
        'WHERE id = ${sqlString(item.id)} AND op_seq = ${item.opSeq};',
      );
      if (deleted > 0) return true;
      final row = await _db
          .customSelect(
            'SELECT operation, payload_json FROM ledger_sync_outbox '
            'WHERE id = ${sqlString(item.id)} LIMIT 1;',
          )
          .getSingleOrNull();
      if (row == null) return false;
      final payload =
          (jsonDecode(row.read<String>('payload_json')) as Map).cast<String, dynamic>();
      if (serverId != null) payload['server_id'] = serverId;
      if (serverUpdatedAt != null) {
        payload['server_updated_at'] = serverUpdatedAt;
      } else {
        payload.remove('server_updated_at');
      }
      if (serverRevision != null) {
        payload['server_revision'] = serverRevision;
      } else {
        payload.remove('server_revision');
      }
      final op = row.read<String>('operation');
      final now = dateTimeToSql(DateTime.now().toUtc());
      await _db.customStatement('''
        UPDATE ledger_sync_outbox
        SET payload_json = ${sqlString(jsonEncode(payload))},
            operation = ${sqlString(op == 'create' && serverId != null ? 'update' : op)},
            attempt_count = 0, next_retry_at = NULL, in_flight_seq = NULL,
            updated_at = ${sqlString(now)}
        WHERE id = ${sqlString(item.id)};
      ''');
      return false;
    });
  }

  /// ACK without a server row to persist (conflict/abandon/idempotent delete).
  Future<bool> markSuccess(OutboxItem item) => acknowledge(item);

  /// A-2 (G18): park rows recorded for another owner / unverified legacy rows,
  /// and re-arm the ones whose owner is the current identity again. Runs at the
  /// start of every push cycle, so nothing is ever sent under a different uid.
  Future<void> reconcileOwnership(String currentUid) async {
    await reconcileOutboxOwnership(
      db: _db,
      table: 'ledger_sync_outbox',
      currentUid: currentUid,
      ownershipVerified: await isOutboxOwnerVerified(_getOwnerUid, currentUid),
    );
  }

  /// MALI-023: typed failure handling. Permanent failures dead-letter
  /// immediately (no retry storm). Retryable failures use bounded exponential
  /// backoff and dead-letter after [kOutboxMaxAttempts]. Conflicts are handled
  /// by the push (markConflict), never here.
  Future<void> markFailed(
    String id,
    String error,
    OutboxFailureClass failureClass,
  ) async {
    final row = await _db
        .customSelect(
          'SELECT attempt_count FROM ledger_sync_outbox WHERE id = ${sqlString(id)} LIMIT 1;',
        )
        .getSingleOrNull();
    if (row == null) return;
    final now = dateTimeToSql(DateTime.now().toUtc());

    // A-3: the marker is cleared on a definite outcome. A transport/5xx failure
    // is AMBIGUOUS (the request may have landed), so the row stays possibly-sent.
    if (failureClass != OutboxFailureClass.transientNetwork &&
        failureClass != OutboxFailureClass.serverError) {
      await _db.customStatement(
        'UPDATE ledger_sync_outbox SET in_flight_seq = NULL WHERE id = ${sqlString(id)};',
      );
    }

    if (failureClass.isPermanent) {
      await _db.customStatement('''
        UPDATE ledger_sync_outbox
        SET status = 'dead_letter', failure_class = ${sqlString(failureClass.reason)},
            last_error = ${sqlString(error)}, updated_at = ${sqlString(now)}
        WHERE id = ${sqlString(id)};
      ''');
      return;
    }

    final attempts = row.read<int>('attempt_count') + 1;
    if (attempts >= kOutboxMaxAttempts) {
      await _db.customStatement('''
        UPDATE ledger_sync_outbox
        SET status = 'dead_letter', attempt_count = $attempts,
            failure_class = ${sqlString(failureClass.reason)},
            last_error = ${sqlString(error)}, updated_at = ${sqlString(now)}
        WHERE id = ${sqlString(id)};
      ''');
      return;
    }

    final nextRetry = dateTimeToSql(
      DateTime.now().toUtc().add(Duration(seconds: _backoff(attempts))),
    );
    await _db.customStatement('''
      UPDATE ledger_sync_outbox
      SET attempt_count = $attempts, failure_class = ${sqlString(failureClass.reason)},
          last_error = ${sqlString(error)}, next_retry_at = ${sqlString(nextRetry)},
          updated_at = ${sqlString(now)}
      WHERE id = ${sqlString(id)};
    ''');
  }

  /// MALI-023: re-arm dead-lettered rows (e.g. after an app/schema upgrade that
  /// may fix a previously-permanent failure). Returns the number re-armed.
  Future<int> reArmDeadLetter() async {
    final now = dateTimeToSql(DateTime.now().toUtc());
    return _db.customUpdate('''
      UPDATE ledger_sync_outbox
      SET status = 'pending', attempt_count = 0, next_retry_at = NULL,
          failure_class = NULL, updated_at = ${sqlString(now)}
      WHERE status = 'dead_letter';
    ''');
  }

  /// MALI-026 (B8-2.10 §8): park a canonical money row whose exact push transport
  /// is unverified. Reuses the Phase-3 status+reason model: a distinct `parked`
  /// status (excluded from [pendingItems], so never sent/retried) carrying the
  /// [reason]. The local write already stands; the row is retained DURABLY, is
  /// NOT marked synced, and does NOT consume a retry attempt. Only pending rows
  /// park (a dead-lettered row stays dead-lettered).
  Future<void> park(String id, String reason) async {
    final now = dateTimeToSql(DateTime.now().toUtc());
    await _db.customStatement('''
      UPDATE ledger_sync_outbox
      SET status = 'parked', failure_class = ${sqlString(reason)},
          last_error = NULL, next_retry_at = NULL, in_flight_seq = NULL,
          updated_at = ${sqlString(now)}
      WHERE id = ${sqlString(id)} AND status = 'pending';
    ''');
  }

  /// MALI-026 (B8-2.10 §9): re-arm parked rows once exact push transport is
  /// verified. The SAME durable rows become drainable again (their payload was
  /// already built as the exact decimal string). Returns the number re-armed.
  Future<int> reArmParked() async {
    final now = dateTimeToSql(DateTime.now().toUtc());
    return _db.customUpdate('''
      UPDATE ledger_sync_outbox
      SET status = 'pending', failure_class = NULL, next_retry_at = NULL,
          updated_at = ${sqlString(now)}
      WHERE status = 'parked'
        AND COALESCE(failure_class, '') NOT IN $kOutboxSelfHealingParkReasonsSql;
    ''');
  }

  /// Parked-row count for diagnostics (no financial payload exposed).
  Future<int> parkedCount() async {
    final row = await _db
        .customSelect(
          "SELECT COUNT(*) AS n FROM ledger_sync_outbox WHERE status = 'parked';",
        )
        .getSingle();
    return row.read<int>('n');
  }

  /// Queue health for diagnostics (no financial payload exposed).
  Future<int> deadLetterCount() async {
    final row = await _db
        .customSelect(
          "SELECT COUNT(*) AS n FROM ledger_sync_outbox WHERE status = 'dead_letter';",
        )
        .getSingle();
    return row.read<int>('n');
  }

  // Capped exponential backoff (30s → ~64min) for retryable failures.
  static int _backoff(int attempt) => 30 * (1 << (attempt - 1).clamp(0, 7));

  Map<String, dynamic> _buildPayload(OutboxOperation op, TransactionEntity tx) {
    if (op == OutboxOperation.delete) {
      return {
        'local_id': tx.id,
        'server_id': tx.serverId,
        // Phase-9K optimistic base token: the guarded tombstone compares this
        // against the live server row when the CAS revision is unknown, so a
        // stale delete never clobbers a newer accepted update.
        'server_updated_at': tx.serverUpdatedAt?.toUtc().toIso8601String(),
      };
    }

    // MALI-026 (B8-2.10 §10): canonical mode serializes money as the EXACT
    // decimal STRING (Money -> moneyToNumericText -> NUMERIC); legacy mode keeps
    // the JSON-number shape. No Money.toDouble() ever runs on the canonical path.
    final canonical = _coordinator.state() == PlanningCutoverState.canonical;
    Object amountWire(Money m) =>
        canonical ? moneyToNumericText(m) : moneyToLegacyJsonNumber(m);
    Object? amountWireOrNull(Money? m) => canonical
        ? moneyToNumericTextOrNull(m)
        : moneyToLegacyJsonNumberOrNull(m);

    final payload = <String, dynamic>{
      'local_id': tx.id,
      'server_id': tx.serverId,
      'amount': amountWire(tx.amountMoney),
      'currency': tx.currency,
      'type': _mapType(tx.type),
      'merchant': tx.rawMerchant,
      'note': tx.note,
      'occurred_at': tx.occurredAt.toUtc().toIso8601String(),
      'account_id': tx.accountId,
      'card_last4': tx.cardLast4,
      'confidence': tx.parseConfidence,
      // Fields the push previously dropped — without these the server row lands
      // with no category, empty metadata and no card link, so a sync round-trip
      // (2nd device / reinstall) returns the transaction uncategorized and
      // unlinked. Kept in parity with TransactionsBackfillService.
      'category_id': tx.categoryId,
      'balance_after': amountWireOrNull(tx.balanceAfterMoney),
      'foreign_amount': amountWireOrNull(tx.foreignMoney),
      'foreign_currency': tx.foreignCurrency,
      // Confirmation state must round-trip (MALI-010): without it a locally
      // confirmed relay capture stays 'pending' on the server and re-imports
      // as pending on every other device.
      'status': tx.status.name,
      // Optimistic-concurrency base token (MALI-009): the server version this
      // change was made against. The push conflict check compares it with the
      // live row before updating — omitted, the check could never fire.
      'server_updated_at': tx.serverUpdatedAt?.toUtc().toIso8601String(),
      // MALI-056n — the explicit, versioned canonical payload. These preserve
      // the EXACT type/source/direction through the server round-trip (the
      // coarse server columns cannot). The legacy 'type' above is kept for
      // downgrade safety (an older build ignores these and reads 'type').
      'payload_version': kLedgerPayloadVersion,
      'canonical_type': tx.type.name,
      'canonical_source': tx.source.name,
      // Null direction is carried as absent → the pull derives it from the
      // canonical type (lossless for income/refund/payment/withdrawal).
      'canonical_direction': tx.direction?.name,
    };

    // Include source only for create operations.
    // For updates, omitting source means the server row keeps its original value
    // (e.g. 'ios_shortcut' for relay-imported transactions via process-ios-sms).
    if (op == OutboxOperation.create) {
      payload['source'] = _mapSource(tx.source);
    }

    return payload;
  }

  static String _mapType(TransactionTypeEntity type) => switch (type) {
        TransactionTypeEntity.income => 'credit',
        TransactionTypeEntity.transfer => 'transfer',
        // Refund must survive the round-trip (MALI-010): collapsing it to
        // 'debit' made the server store it as an EXPENSE, flipping its
        // meaning on every other device. The server accepts 'refund'
        // (migration 0022's transaction_type check).
        TransactionTypeEntity.refund => 'refund',
        _ => 'debit',
      };

  // Every create carries its real provenance via the canonical server mapping:
  // captured transactions push as their true source (bank/card/ai → import/
  // share_extension), manual adds as 'manual'. Updates strip source (see
  // LedgerPushService._pushUpdate) so a server source already set by the relay
  // is never clobbered.
  static String _mapSource(TransactionSourceEntity source) =>
      transactionSourceToServer(source);
}
