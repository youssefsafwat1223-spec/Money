import 'package:drift/drift.dart';

import '../../core/utils/id_generator.dart';
import '../../domain/entities/sender_bank_mapping_entity.dart';
import '../../domain/repositories/sender_bank_mapping_repository.dart';
import '../db/app_database.dart';
import '../db/sql_value_codec.dart';

class DriftSenderBankMappingRepository implements SenderBankMappingRepository {
  DriftSenderBankMappingRepository(this._db);

  final AppDatabase _db;

  static String normalizeSenderId(String senderId) {
    return senderId
        .trim()
        .toUpperCase()
        .replaceAll(RegExp(r'[\u061C\u200E\u200F]'), '')
        .replaceAll(RegExp(r'[\s._-]+'), '');
  }

  @override
  Future<SenderBankMappingEntity?> getBySender(String senderId) async {
    final normalized = normalizeSenderId(senderId);
    if (normalized.isEmpty) return null;
    final row = await _db.customSelect(
      '''
        SELECT *
        FROM sender_bank_mappings
        WHERE normalized_sender_id = ?
          AND deleted_at IS NULL
        LIMIT 1;
      ''',
      variables: [Variable.withString(normalized)],
    ).getSingleOrNull();
    return row == null ? null : _fromRow(row);
  }

  @override
  Future<SenderBankMappingEntity?> getConfirmedBySender(
    String senderId,
  ) async {
    final mapping = await getBySender(senderId);
    if (mapping?.status == SenderBankMappingStatus.confirmed) {
      return mapping;
    }
    return null;
  }

  @override
  Future<SenderBankMappingEntity?> getActiveSuggestionBySender(
    String senderId, {
    DateTime? now,
  }) async {
    final mapping = await getBySender(senderId);
    if (mapping == null) return null;
    if (mapping.status == SenderBankMappingStatus.pending) return mapping;
    if (mapping.status == SenderBankMappingStatus.rejected &&
        mapping.suppressesDiscovery(now?.toUtc() ?? DateTime.now().toUtc())) {
      return mapping;
    }
    return null;
  }

  @override
  Future<bool> suppressesDiscoveryPrompt(
    String senderId, {
    DateTime? now,
  }) async {
    final mapping = await getBySender(senderId);
    if (mapping == null) return false;
    return mapping.suppressesDiscovery(now?.toUtc() ?? DateTime.now().toUtc());
  }

  @override
  Future<SenderBankMappingEntity> saveSuggestion(
    SenderBankMappingDraft draft,
  ) async {
    final normalized = normalizeSenderId(draft.senderId);
    if (normalized.isEmpty) {
      throw ArgumentError.value(
        draft.senderId,
        'senderId',
        'Sender ID must not be empty.',
      );
    }
    if (draft.confidence < 0 || draft.confidence > 1) {
      throw ArgumentError.value(
        draft.confidence,
        'confidence',
        'Confidence must be between 0 and 1.',
      );
    }

    final now = (draft.now ?? DateTime.now()).toUtc();
    final existing = await getBySender(draft.senderId);
    if (existing?.status == SenderBankMappingStatus.confirmed) {
      return existing!;
    }

    final id = existing?.id ?? IdGenerator.next();
    final firstSeenAt = existing?.firstSeenAt ?? now;
    await _db.customInsert(
      '''
        INSERT INTO sender_bank_mappings(
          id, sender_id, normalized_sender_id, bank_key,
          suggested_bank_name, suggested_country, confidence,
          reason, status, source, first_seen_at, last_seen_at,
          confirmed_at, rejected_at, rejection_expires_at,
          created_at, updated_at, synced_at, sync_status
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'pending', ?, ?, ?, NULL, NULL, NULL, ?, ?, NULL, 'pending')
        ON CONFLICT(normalized_sender_id) DO UPDATE SET
          sender_id = excluded.sender_id,
          bank_key = excluded.bank_key,
          suggested_bank_name = excluded.suggested_bank_name,
          suggested_country = excluded.suggested_country,
          confidence = excluded.confidence,
          reason = excluded.reason,
          status = CASE
            WHEN sender_bank_mappings.status = 'confirmed' THEN sender_bank_mappings.status
            ELSE excluded.status
          END,
          source = excluded.source,
          last_seen_at = excluded.last_seen_at,
          confirmed_at = CASE
            WHEN sender_bank_mappings.status = 'confirmed' THEN sender_bank_mappings.confirmed_at
            ELSE NULL
          END,
          rejected_at = CASE
            WHEN sender_bank_mappings.status = 'confirmed' THEN sender_bank_mappings.rejected_at
            ELSE NULL
          END,
          rejection_expires_at = CASE
            WHEN sender_bank_mappings.status = 'confirmed' THEN sender_bank_mappings.rejection_expires_at
            ELSE NULL
          END,
          updated_at = excluded.updated_at,
          synced_at = NULL,
          -- MALI-072n — re-suggesting a sender un-tombstones it (an explicit
          -- recreate), so a locally-deleted mapping the user re-adds comes back.
          deleted_at = NULL,
          sync_status = CASE
            WHEN sender_bank_mappings.status = 'confirmed' THEN sender_bank_mappings.sync_status
            ELSE 'pending'
          END;
      ''',
      variables: [
        Variable.withString(id),
        Variable.withString(draft.senderId),
        Variable.withString(normalized),
        draft.bankKey == null
            ? const Variable<String>(null)
            : Variable.withString(draft.bankKey!),
        Variable.withString(draft.suggestedBankName),
        Variable.withString(draft.suggestedCountry),
        Variable.withReal(draft.confidence),
        draft.reason == null
            ? const Variable<String>(null)
            : Variable.withString(draft.reason!),
        Variable.withString(_sourceToSql(draft.source)),
        Variable.withString(dateTimeToSql(firstSeenAt)),
        Variable.withString(dateTimeToSql(now)),
        Variable.withString(dateTimeToSql(now)),
        Variable.withString(dateTimeToSql(now)),
      ],
    );
    return (await getBySender(draft.senderId))!;
  }

  @override
  Future<SenderBankMappingEntity> confirm({
    required String mappingId,
    String? bankKey,
    DateTime? now,
  }) async {
    final timestamp = (now ?? DateTime.now()).toUtc();
    await _db.customUpdate(
      '''
        UPDATE sender_bank_mappings
        SET status = 'confirmed',
            bank_key = ?,
            confirmed_at = ?,
            rejected_at = NULL,
            rejection_expires_at = NULL,
            updated_at = ?,
            synced_at = NULL,
            sync_status = 'pending'
        WHERE id = ?;
      ''',
      variables: [
        bankKey == null
            ? const Variable<String>(null)
            : Variable.withString(bankKey),
        Variable.withString(dateTimeToSql(timestamp)),
        Variable.withString(dateTimeToSql(timestamp)),
        Variable.withString(mappingId),
      ],
    );
    return _getById(mappingId);
  }

  @override
  Future<SenderBankMappingEntity> reject({
    required String mappingId,
    required Duration cooldown,
    DateTime? now,
  }) async {
    final timestamp = (now ?? DateTime.now()).toUtc();
    final expiresAt = timestamp.add(cooldown);
    await _db.customUpdate(
      '''
        UPDATE sender_bank_mappings
        SET status = 'rejected',
            confirmed_at = NULL,
            rejected_at = ?,
            rejection_expires_at = ?,
            updated_at = ?,
            synced_at = NULL,
            sync_status = 'pending'
        WHERE id = ?;
      ''',
      variables: [
        Variable.withString(dateTimeToSql(timestamp)),
        Variable.withString(dateTimeToSql(expiresAt)),
        Variable.withString(dateTimeToSql(timestamp)),
        Variable.withString(mappingId),
      ],
    );
    return _getById(mappingId);
  }

  @override
  Future<List<SenderBankMappingEntity>> getAll() async {
    final rows = await _db.customSelect(
      '''
        SELECT *
        FROM sender_bank_mappings
        WHERE deleted_at IS NULL
        ORDER BY updated_at DESC;
      ''',
    ).get();
    return rows.map(_fromRow).toList();
  }

  @override
  Future<List<SenderBankMappingEntity>> pendingSync() async {
    final rows = await _db.customSelect(
      '''
        SELECT *
        FROM sender_bank_mappings
        WHERE sync_status IN ('pending', 'failed')
          AND status IN ('confirmed', 'rejected')
        ORDER BY updated_at ASC;
      ''',
    ).get();
    return rows.map(_fromRow).toList();
  }

  @override
  Future<SenderBankMappingEntity> upsertRemote(
    SenderBankMappingEntity remote, {
    DateTime? syncedAt,
  }) async {
    final normalized = normalizeSenderId(remote.senderId);
    if (normalized.isEmpty) {
      throw ArgumentError.value(
        remote.senderId,
        'remote.senderId',
        'Sender ID must not be empty.',
      );
    }

    final existing = await getBySender(remote.senderId);
    if (existing != null && !_shouldApplyRemote(existing, remote)) {
      return existing;
    }

    final syncTime = (syncedAt ?? DateTime.now()).toUtc();
    final id = existing?.id ?? remote.id;
    await _db.customInsert(
      '''
        INSERT INTO sender_bank_mappings(
          id, sender_id, normalized_sender_id, bank_key,
          suggested_bank_name, suggested_country, confidence,
          reason, status, source, first_seen_at, last_seen_at,
          confirmed_at, rejected_at, rejection_expires_at,
          created_at, updated_at, synced_at, sync_status
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'synced')
        ON CONFLICT(normalized_sender_id) DO UPDATE SET
          sender_id = excluded.sender_id,
          bank_key = excluded.bank_key,
          suggested_bank_name = excluded.suggested_bank_name,
          suggested_country = excluded.suggested_country,
          confidence = excluded.confidence,
          reason = excluded.reason,
          status = excluded.status,
          source = excluded.source,
          first_seen_at = excluded.first_seen_at,
          last_seen_at = excluded.last_seen_at,
          confirmed_at = excluded.confirmed_at,
          rejected_at = excluded.rejected_at,
          rejection_expires_at = excluded.rejection_expires_at,
          created_at = excluded.created_at,
          updated_at = excluded.updated_at,
          synced_at = excluded.synced_at,
          sync_status = 'synced';
      ''',
      variables: [
        Variable.withString(id),
        Variable.withString(remote.senderId),
        Variable.withString(normalized),
        _nullableString(remote.bankKey),
        Variable.withString(remote.suggestedBankName),
        Variable.withString(remote.suggestedCountry),
        Variable.withReal(remote.confidence),
        _nullableString(remote.reason),
        Variable.withString(_statusToSql(remote.status)),
        Variable.withString(_sourceToSql(remote.source)),
        Variable.withString(dateTimeToSql(remote.firstSeenAt)),
        Variable.withString(dateTimeToSql(remote.lastSeenAt)),
        _nullableDateTime(remote.confirmedAt),
        _nullableDateTime(remote.rejectedAt),
        _nullableDateTime(remote.rejectionExpiresAt),
        Variable.withString(dateTimeToSql(remote.createdAt)),
        Variable.withString(dateTimeToSql(remote.updatedAt)),
        Variable.withString(dateTimeToSql(syncTime)),
      ],
    );
    return (await getBySender(remote.senderId))!;
  }

  bool _shouldApplyRemote(
    SenderBankMappingEntity local,
    SenderBankMappingEntity remote,
  ) {
    if (local.status == SenderBankMappingStatus.confirmed &&
        remote.status == SenderBankMappingStatus.pending) {
      return false;
    }
    if (local.status == remote.status) {
      return remote.updatedAt.isAfter(local.updatedAt);
    }
    if (local.syncStatus != SenderBankMappingSyncStatus.synced) {
      return false;
    }
    return remote.updatedAt.isAfter(local.updatedAt);
  }

  @override
  Future<void> markSynced(String id, {DateTime? now}) async {
    final timestamp = (now ?? DateTime.now()).toUtc();
    await _db.customUpdate(
      '''
        UPDATE sender_bank_mappings
        SET sync_status = 'synced',
            synced_at = ?,
            updated_at = ?
        WHERE id = ?;
      ''',
      variables: [
        Variable.withString(dateTimeToSql(timestamp)),
        Variable.withString(dateTimeToSql(timestamp)),
        Variable.withString(id),
      ],
    );
  }

  @override
  Future<void> markSyncFailed(String id, {DateTime? now}) async {
    final timestamp = (now ?? DateTime.now()).toUtc();
    await _db.customUpdate(
      '''
        UPDATE sender_bank_mappings
        SET sync_status = 'failed',
            updated_at = ?
        WHERE id = ?;
      ''',
      variables: [
        Variable.withString(dateTimeToSql(timestamp)),
        Variable.withString(id),
      ],
    );
  }

  @override
  Future<void> delete(String id) async {
    // MALI-072n — soft-delete (tombstone) so the deletion PROPAGATES: the sync
    // pushes the tombstone to the server, and other devices apply it on pull. A
    // hard delete vanished locally and silently resurrected on every sync.
    final now = dateTimeToSql(DateTime.now().toUtc());
    await _db.customUpdate(
      'UPDATE sender_bank_mappings '
      "SET deleted_at = ?, updated_at = ?, sync_status = 'pending' "
      'WHERE id = ? AND deleted_at IS NULL;',
      variables: [
        Variable.withString(now),
        Variable.withString(now),
        Variable.withString(id),
      ],
    );
  }

  Future<SenderBankMappingEntity> _getById(String id) async {
    final row = await _db.customSelect(
      'SELECT * FROM sender_bank_mappings WHERE id = ? LIMIT 1;',
      variables: [Variable.withString(id)],
    ).getSingleOrNull();
    if (row == null) {
      throw StateError('Sender bank mapping not found: $id');
    }
    return _fromRow(row);
  }

  SenderBankMappingEntity _fromRow(QueryRow row) {
    return SenderBankMappingEntity(
      id: row.read<String>('id'),
      senderId: row.read<String>('sender_id'),
      normalizedSenderId: row.read<String>('normalized_sender_id'),
      bankKey: row.readNullable<String>('bank_key'),
      suggestedBankName: row.read<String>('suggested_bank_name'),
      suggestedCountry: row.read<String>('suggested_country'),
      confidence: row.read<double>('confidence'),
      reason: row.readNullable<String>('reason'),
      status: _statusFromSql(row.read<String>('status')),
      source: _sourceFromSql(row.read<String>('source')),
      firstSeenAt: dateTimeFromSql(row.read<String>('first_seen_at')),
      lastSeenAt: dateTimeFromSql(row.read<String>('last_seen_at')),
      confirmedAt: _dateTimeOrNull(row.readNullable<String>('confirmed_at')),
      rejectedAt: _dateTimeOrNull(row.readNullable<String>('rejected_at')),
      rejectionExpiresAt:
          _dateTimeOrNull(row.readNullable<String>('rejection_expires_at')),
      createdAt: dateTimeFromSql(row.read<String>('created_at')),
      updatedAt: dateTimeFromSql(row.read<String>('updated_at')),
      syncedAt: _dateTimeOrNull(row.readNullable<String>('synced_at')),
      syncStatus: _syncStatusFromSql(row.read<String>('sync_status')),
    );
  }

  DateTime? _dateTimeOrNull(String? value) =>
      value == null ? null : dateTimeFromSql(value);

  Variable<String> _nullableString(String? value) =>
      value == null ? const Variable<String>(null) : Variable.withString(value);

  Variable<String> _nullableDateTime(DateTime? value) => value == null
      ? const Variable<String>(null)
      : Variable.withString(dateTimeToSql(value));

  SenderBankMappingStatus _statusFromSql(String value) {
    switch (value) {
      case 'pending':
        return SenderBankMappingStatus.pending;
      case 'confirmed':
        return SenderBankMappingStatus.confirmed;
      case 'rejected':
        return SenderBankMappingStatus.rejected;
      default:
        throw ArgumentError.value(value, 'value', 'Unknown mapping status.');
    }
  }

  String _statusToSql(SenderBankMappingStatus value) {
    switch (value) {
      case SenderBankMappingStatus.pending:
        return 'pending';
      case SenderBankMappingStatus.confirmed:
        return 'confirmed';
      case SenderBankMappingStatus.rejected:
        return 'rejected';
    }
  }

  SenderBankMappingSource _sourceFromSql(String value) {
    switch (value) {
      case 'gemini':
        return SenderBankMappingSource.gemini;
      case 'user_manual':
        return SenderBankMappingSource.userManual;
      case 'remote':
        return SenderBankMappingSource.remote;
      default:
        throw ArgumentError.value(value, 'value', 'Unknown mapping source.');
    }
  }

  String _sourceToSql(SenderBankMappingSource value) {
    switch (value) {
      case SenderBankMappingSource.gemini:
        return 'gemini';
      case SenderBankMappingSource.userManual:
        return 'user_manual';
      case SenderBankMappingSource.remote:
        return 'remote';
    }
  }

  SenderBankMappingSyncStatus _syncStatusFromSql(String value) {
    switch (value) {
      case 'pending':
        return SenderBankMappingSyncStatus.pending;
      case 'synced':
        return SenderBankMappingSyncStatus.synced;
      case 'failed':
        return SenderBankMappingSyncStatus.failed;
      default:
        throw ArgumentError.value(value, 'value', 'Unknown sync status.');
    }
  }
}
