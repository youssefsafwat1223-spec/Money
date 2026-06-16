import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as supabase;

import '../../domain/entities/sender_bank_mapping_entity.dart';
import '../../domain/repositories/sender_bank_mapping_repository.dart';

class RemoteSenderBankMapping {
  const RemoteSenderBankMapping({
    required this.remoteId,
    required this.userId,
    required this.mapping,
  });

  final String remoteId;
  final String userId;
  final SenderBankMappingEntity mapping;

  Map<String, Object?> toJson() {
    return {
      if (_looksLikeUuid(remoteId)) 'id': remoteId,
      'user_id': userId,
      'sender_id': mapping.senderId,
      'normalized_sender_id': mapping.normalizedSenderId,
      'bank_key': mapping.bankKey,
      'suggested_bank_name': mapping.suggestedBankName,
      'suggested_country': mapping.suggestedCountry,
      'confidence': mapping.confidence,
      'reason': mapping.reason,
      'status': _statusToSql(mapping.status),
      'source': _sourceToSql(mapping.source),
      'first_seen_at': mapping.firstSeenAt.toIso8601String(),
      'last_seen_at': mapping.lastSeenAt.toIso8601String(),
      'confirmed_at': mapping.confirmedAt?.toIso8601String(),
      'rejected_at': mapping.rejectedAt?.toIso8601String(),
      'rejection_expires_at': mapping.rejectionExpiresAt?.toIso8601String(),
      'created_at': mapping.createdAt.toIso8601String(),
      'updated_at': mapping.updatedAt.toIso8601String(),
    };
  }

  factory RemoteSenderBankMapping.fromJson(Map<String, dynamic> json) {
    final remoteId = json['id']?.toString() ?? '';
    final userId = json['user_id']?.toString() ?? '';
    return RemoteSenderBankMapping(
      remoteId: remoteId,
      userId: userId,
      mapping: SenderBankMappingEntity(
        id: remoteId.isEmpty
            ? json['normalized_sender_id'].toString()
            : remoteId,
        senderId: json['sender_id'] as String,
        normalizedSenderId: json['normalized_sender_id'] as String,
        bankKey: json['bank_key'] as String?,
        suggestedBankName: json['suggested_bank_name'] as String,
        suggestedCountry: json['suggested_country'] as String,
        confidence: (json['confidence'] as num).toDouble(),
        reason: json['reason'] as String?,
        status: _statusFromSql(json['status'] as String),
        source: _sourceFromSql(json['source'] as String),
        firstSeenAt: _dateTime(json['first_seen_at']),
        lastSeenAt: _dateTime(json['last_seen_at']),
        confirmedAt: _nullableDateTime(json['confirmed_at']),
        rejectedAt: _nullableDateTime(json['rejected_at']),
        rejectionExpiresAt: _nullableDateTime(json['rejection_expires_at']),
        createdAt: _dateTime(json['created_at']),
        updatedAt: _dateTime(json['updated_at']),
        syncedAt: null,
        syncStatus: SenderBankMappingSyncStatus.synced,
      ),
    );
  }

  static DateTime _dateTime(Object? value) =>
      DateTime.parse(value.toString()).toUtc();

  static DateTime? _nullableDateTime(Object? value) =>
      value == null ? null : _dateTime(value);

  static SenderBankMappingStatus _statusFromSql(String value) {
    switch (value) {
      case 'pending':
        return SenderBankMappingStatus.pending;
      case 'confirmed':
        return SenderBankMappingStatus.confirmed;
      case 'rejected':
        return SenderBankMappingStatus.rejected;
      default:
        throw FormatException('Unknown mapping status: $value');
    }
  }

  static String _statusToSql(SenderBankMappingStatus value) {
    switch (value) {
      case SenderBankMappingStatus.pending:
        return 'pending';
      case SenderBankMappingStatus.confirmed:
        return 'confirmed';
      case SenderBankMappingStatus.rejected:
        return 'rejected';
    }
  }

  static SenderBankMappingSource _sourceFromSql(String value) {
    switch (value) {
      case 'gemini':
        return SenderBankMappingSource.gemini;
      case 'user_manual':
        return SenderBankMappingSource.userManual;
      case 'remote':
        return SenderBankMappingSource.remote;
      default:
        throw FormatException('Unknown mapping source: $value');
    }
  }

  static String _sourceToSql(SenderBankMappingSource value) {
    switch (value) {
      case SenderBankMappingSource.gemini:
        return 'gemini';
      case SenderBankMappingSource.userManual:
        return 'user_manual';
      case SenderBankMappingSource.remote:
        return 'remote';
    }
  }
}

abstract class SenderBankMappingRemoteStore {
  Future<List<RemoteSenderBankMapping>> download(String userId);

  Future<void> upload(List<RemoteSenderBankMapping> mappings);
}

class SupabaseSenderBankMappingRemoteStore
    implements SenderBankMappingRemoteStore {
  SupabaseSenderBankMappingRemoteStore(this._client);

  final supabase.SupabaseClient _client;

  @override
  Future<List<RemoteSenderBankMapping>> download(String userId) async {
    final rows = await _client
        .from('sender_bank_mappings')
        .select()
        .eq('user_id', userId);
    return rows
        .whereType<Map<Object?, Object?>>()
        .map((row) => row.map((key, value) => MapEntry(key.toString(), value)))
        .map(RemoteSenderBankMapping.fromJson)
        .toList(growable: false);
  }

  @override
  Future<void> upload(List<RemoteSenderBankMapping> mappings) async {
    if (mappings.isEmpty) return;
    await _client.from('sender_bank_mappings').upsert(
          mappings.map((mapping) => mapping.toJson()).toList(),
          onConflict: 'user_id,normalized_sender_id',
        );
  }
}

class SenderBankMappingSyncService {
  SenderBankMappingSyncService({
    required SenderBankMappingRepository repository,
    required SenderBankMappingRemoteStore remoteStore,
    required String? Function() currentUserId,
    DateTime Function()? now,
  })  : _repository = repository,
        _remoteStore = remoteStore,
        _currentUserId = currentUserId,
        _now = now ?? (() => DateTime.now().toUtc());

  final SenderBankMappingRepository _repository;
  final SenderBankMappingRemoteStore _remoteStore;
  final String? Function() _currentUserId;
  final DateTime Function() _now;

  Future<void> sync() async {
    final userId = _currentUserId();
    if (userId == null || userId.trim().isEmpty) return;
    try {
      await download();
      await uploadPending();
    } catch (error, stackTrace) {
      debugPrint('Sender bank mapping sync skipped: $error');
      debugPrintStack(stackTrace: stackTrace);
    }
  }

  Future<void> download() async {
    final userId = _currentUserId();
    if (userId == null || userId.trim().isEmpty) return;
    final remoteRows = await _remoteStore.download(userId);
    final syncTime = _now().toUtc();
    for (final row in remoteRows) {
      await _repository.upsertRemote(row.mapping, syncedAt: syncTime);
    }
  }

  Future<void> uploadPending() async {
    final userId = _currentUserId();
    if (userId == null || userId.trim().isEmpty) return;
    final pending = await _repository.pendingSync();
    final uploadable = pending
        .where((mapping) =>
            mapping.status == SenderBankMappingStatus.confirmed ||
            mapping.status == SenderBankMappingStatus.rejected)
        .map((mapping) => RemoteSenderBankMapping(
              remoteId: _remoteIdFor(mapping),
              userId: userId,
              mapping: mapping,
            ))
        .toList(growable: false);
    if (uploadable.isEmpty) return;
    try {
      await _remoteStore.upload(uploadable);
      final syncTime = _now().toUtc();
      for (final mapping in uploadable) {
        await _repository.markSynced(mapping.mapping.id, now: syncTime);
      }
    } catch (_) {
      final failedAt = _now().toUtc();
      for (final mapping in uploadable) {
        await _repository.markSyncFailed(mapping.mapping.id, now: failedAt);
      }
      rethrow;
    }
  }

  String _remoteIdFor(SenderBankMappingEntity mapping) {
    return mapping.id;
  }
}

bool _looksLikeUuid(String value) {
  return RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
  ).hasMatch(value);
}
