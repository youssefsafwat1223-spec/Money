import 'dart:convert';

import '../../../core/utils/id_generator.dart';
import '../../../data/db/app_database.dart';
import '../../../data/db/sql_value_codec.dart';
import '../../../domain/entities/transaction_entity.dart';

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
  })  : _db = db,
        _isPushEnabled = isPushEnabled,
        _getAuthUserId = getAuthUserId;

  static const int _maxAttempts = 5;

  final AppDatabase _db;
  final bool Function() _isPushEnabled;
  final Future<String?> Function() _getAuthUserId;

  Future<void> enqueue(
    OutboxOperation op,
    TransactionEntity tx,
  ) async {
    if (!_isPushEnabled()) return;
    final userId = await _getAuthUserId();
    if (userId == null) return;

    final now = dateTimeToSql(DateTime.now().toUtc());
    final payload = _buildPayload(op, tx);
    final id = IdGenerator.next();

    await _db.customStatement('''
      INSERT INTO ledger_sync_outbox(
        id, transaction_id, operation, payload_json,
        attempt_count, created_at, updated_at
      ) VALUES (
        ${sqlString(id)},
        ${sqlString(tx.id)},
        ${sqlString(op.name)},
        ${sqlString(jsonEncode(payload))},
        0,
        ${sqlString(now)},
        ${sqlString(now)}
      );
    ''');
  }

  Future<List<OutboxItem>> pendingItems({int limit = 50}) async {
    final now = dateTimeToSql(DateTime.now().toUtc());
    final rows = await _db.customSelect('''
      SELECT id, transaction_id, operation, payload_json,
             attempt_count, last_error, next_retry_at
      FROM ledger_sync_outbox
      WHERE attempt_count < $_maxAttempts
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

  Future<void> markFailed(String id, String error) async {
    final row = await _db.customSelect(
      'SELECT attempt_count FROM ledger_sync_outbox WHERE id = ${sqlString(id)} LIMIT 1;',
    ).getSingleOrNull();
    if (row == null) return;

    final attempts = row.read<int>('attempt_count') + 1;
    final backoffSeconds = _backoff(attempts);
    final nextRetry = dateTimeToSql(
      DateTime.now().toUtc().add(Duration(seconds: backoffSeconds)),
    );
    final now = dateTimeToSql(DateTime.now().toUtc());

    await _db.customStatement('''
      UPDATE ledger_sync_outbox
      SET attempt_count = $attempts,
          last_error = ${sqlString(error)},
          next_retry_at = ${sqlString(nextRetry)},
          updated_at = ${sqlString(now)}
      WHERE id = ${sqlString(id)};
    ''');
  }

  // Exponential backoff: 30s, 2m, 8m, 32m, 128m.
  static int _backoff(int attempt) => 30 * (1 << (attempt - 1).clamp(0, 7));

  Map<String, dynamic> _buildPayload(OutboxOperation op, TransactionEntity tx) {
    if (op == OutboxOperation.delete) {
      return {
        'local_id': tx.id,
        'server_id': tx.serverId,
      };
    }

    final payload = <String, dynamic>{
      'local_id': tx.id,
      'server_id': tx.serverId,
      'amount': tx.amount,
      'currency': tx.currency,
      'type': _mapType(tx.type),
      'merchant': tx.rawMerchant,
      'note': tx.note,
      'occurred_at': tx.occurredAt.toUtc().toIso8601String(),
      'account_id': tx.accountId,
      'card_last4': tx.cardLast4,
      'confidence': tx.parseConfidence,
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
        _ => 'debit',
      };

  // All user-initiated creates map to 'manual'.
  // Relay-imported transactions (bank/ios_shortcut/android_sms) bypass the
  // outbox entirely for creates — CaptureSyncService constructs
  // DriftTransactionRepository(db) directly without the outbox parameter.
  static String _mapSource(TransactionSourceEntity source) => 'manual';
}
