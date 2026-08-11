import 'dart:convert';

import '../../../core/sync/outbox_failure.dart';
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
    this.lastError,
    this.nextRetryAt,
  });

  final String id;
  final String transactionId;
  final OutboxOperation operation;
  final Map<String, dynamic> payloadJson;
  final int attemptCount;
  final String? lastError;
  final DateTime? nextRetryAt;
}

class LedgerOutboxQueue {
  LedgerOutboxQueue({
    required AppDatabase db,
    required bool Function() isPushEnabled,
    required Future<String?> Function() getAuthUserId,
    void Function()? onQueued,
    // MALI-026 (B8-2.10 §10): the money-authority mode. Legacy (v29 today) emits
    // the current JSON-number wire shape; canonical emits the exact decimal
    // STRING. Defaults to legacy, so today's payloads are byte-identical.
    PlanningCutoverCoordinator coordinator =
        const SchemaV29PlanningCutoverCoordinator(),
  })  : _db = db,
        _isPushEnabled = isPushEnabled,
        _getAuthUserId = getAuthUserId,
        _onQueued = onQueued,
        _coordinator = coordinator;

  final AppDatabase _db;
  final bool Function() _isPushEnabled;
  final Future<String?> Function() _getAuthUserId;
  final void Function()? _onQueued;
  final PlanningCutoverCoordinator _coordinator;

  Future<void> enqueue(
    OutboxOperation op,
    TransactionEntity tx,
  ) async {
    if (!_isPushEnabled()) return;
    final userId = await _getAuthUserId();
    if (userId == null) return;

    final now = dateTimeToSql(DateTime.now().toUtc());
    final payload = _buildPayload(op, tx);

    // MALI-022 / 0068 — attach the locally-cached server revision as the CAS
    // base token (updates only; a delete tombstone applies unconditionally).
    // Null (unknown revision) is left absent → the push uses the guarded
    // server_updated_at compare, never a blind overwrite.
    if (op != OutboxOperation.delete) {
      final revRow = await _db
          .customSelect(
            'SELECT server_revision FROM transactions '
            'WHERE id = ${sqlString(tx.id)} LIMIT 1;',
          )
          .getSingleOrNull();
      final baseRevision = revRow?.readNullable<int>('server_revision');
      if (baseRevision != null) payload['server_revision'] = baseRevision;
    }

    await _db.transaction(() async {
      // MALI-052n: coalesce into any existing PENDING row for this transaction.
      final existing = await _db.customSelect(
        "SELECT id, operation FROM ledger_sync_outbox "
        "WHERE transaction_id = ${sqlString(tx.id)} AND status = 'pending' "
        "ORDER BY created_at ASC LIMIT 1;",
      ).getSingleOrNull();
      if (existing != null) {
        final coalesced =
            coalesceOutboxOperation(existing.read<String>('operation'), op.name);
        if (coalesced == null) {
          await _db.customStatement(
            'DELETE FROM ledger_sync_outbox '
            'WHERE transaction_id = ${sqlString(tx.id)} '
            "AND status = 'pending';",
          );
        } else {
          await _db.customStatement('''
            UPDATE ledger_sync_outbox
            SET operation = ${sqlString(coalesced)},
                payload_json = ${sqlString(jsonEncode(payload))},
                attempt_count = 0, status = 'pending', failure_class = NULL,
                last_error = NULL, next_retry_at = NULL,
                updated_at = ${sqlString(now)}
            WHERE transaction_id = ${sqlString(tx.id)} AND status = 'pending';
          ''');
        }
      } else {
        await _db.customStatement('''
          INSERT INTO ledger_sync_outbox(
            id, transaction_id, operation, payload_json,
            attempt_count, status, created_at, updated_at
          ) VALUES (
            ${sqlString(IdGenerator.next())}, ${sqlString(tx.id)},
            ${sqlString(op.name)}, ${sqlString(jsonEncode(payload))},
            0, 'pending', ${sqlString(now)}, ${sqlString(now)}
          );
        ''');
      }
      await _db.customStatement('''
        UPDATE transactions
        SET sync_status = 'pending'
        WHERE id = ${sqlString(tx.id)};
      ''');
    });
    _onQueued?.call();
  }

  Future<List<OutboxItem>> pendingItems({int limit = 50}) async {
    final now = dateTimeToSql(DateTime.now().toUtc());
    final rows = await _db.customSelect('''
      SELECT id, transaction_id, operation, payload_json,
             attempt_count, last_error, next_retry_at
      FROM ledger_sync_outbox
      WHERE status = 'pending'
        AND (next_retry_at IS NULL OR next_retry_at <= ${sqlString(now)})
      ORDER BY created_at ASC
      LIMIT $limit;
    ''').get();

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
        lastError: row.readNullable<String>('last_error'),
        nextRetryAt:
            retryStr == null ? null : DateTime.tryParse(retryStr)?.toUtc(),
      );
    }).toList();
  }

  Future<void> markSuccess(String id) async {
    await _db.customStatement(
      'DELETE FROM ledger_sync_outbox WHERE id = ${sqlString(id)};',
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

    if (failureClass.isPermanent) {
      await _db.customStatement('''
        UPDATE ledger_sync_outbox
        SET status = 'dead_letter', failure_class = ${sqlString(failureClass.name)},
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
            failure_class = ${sqlString(failureClass.name)},
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
      SET attempt_count = $attempts, failure_class = ${sqlString(failureClass.name)},
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
          last_error = NULL, next_retry_at = NULL, updated_at = ${sqlString(now)}
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
      WHERE status = 'parked';
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
