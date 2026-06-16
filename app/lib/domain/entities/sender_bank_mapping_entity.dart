enum SenderBankMappingStatus { pending, confirmed, rejected }

enum SenderBankMappingSource { gemini, userManual, remote }

enum SenderBankMappingSyncStatus { pending, synced, failed }

class SenderBankMappingEntity {
  const SenderBankMappingEntity({
    required this.id,
    required this.senderId,
    required this.normalizedSenderId,
    required this.suggestedBankName,
    required this.suggestedCountry,
    required this.confidence,
    required this.status,
    required this.source,
    required this.firstSeenAt,
    required this.lastSeenAt,
    required this.createdAt,
    required this.updatedAt,
    required this.syncStatus,
    this.bankKey,
    this.reason,
    this.confirmedAt,
    this.rejectedAt,
    this.rejectionExpiresAt,
    this.syncedAt,
  });

  final String id;
  final String senderId;
  final String normalizedSenderId;
  final String? bankKey;
  final String suggestedBankName;
  final String suggestedCountry;
  final double confidence;
  final String? reason;
  final SenderBankMappingStatus status;
  final SenderBankMappingSource source;
  final DateTime firstSeenAt;
  final DateTime lastSeenAt;
  final DateTime? confirmedAt;
  final DateTime? rejectedAt;
  final DateTime? rejectionExpiresAt;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? syncedAt;
  final SenderBankMappingSyncStatus syncStatus;

  bool get isTrusted => status == SenderBankMappingStatus.confirmed;

  bool suppressesDiscovery(DateTime now) {
    if (status == SenderBankMappingStatus.confirmed) return true;
    if (status != SenderBankMappingStatus.rejected) return false;
    final expires = rejectionExpiresAt;
    return expires == null || expires.isAfter(now);
  }

  SenderBankMappingEntity copyWith({
    String? id,
    String? senderId,
    String? normalizedSenderId,
    Object? bankKey = _sentinel,
    String? suggestedBankName,
    String? suggestedCountry,
    double? confidence,
    Object? reason = _sentinel,
    SenderBankMappingStatus? status,
    SenderBankMappingSource? source,
    DateTime? firstSeenAt,
    DateTime? lastSeenAt,
    Object? confirmedAt = _sentinel,
    Object? rejectedAt = _sentinel,
    Object? rejectionExpiresAt = _sentinel,
    DateTime? createdAt,
    DateTime? updatedAt,
    Object? syncedAt = _sentinel,
    SenderBankMappingSyncStatus? syncStatus,
  }) {
    return SenderBankMappingEntity(
      id: id ?? this.id,
      senderId: senderId ?? this.senderId,
      normalizedSenderId: normalizedSenderId ?? this.normalizedSenderId,
      bankKey: bankKey == _sentinel ? this.bankKey : bankKey as String?,
      suggestedBankName: suggestedBankName ?? this.suggestedBankName,
      suggestedCountry: suggestedCountry ?? this.suggestedCountry,
      confidence: confidence ?? this.confidence,
      reason: reason == _sentinel ? this.reason : reason as String?,
      status: status ?? this.status,
      source: source ?? this.source,
      firstSeenAt: firstSeenAt ?? this.firstSeenAt,
      lastSeenAt: lastSeenAt ?? this.lastSeenAt,
      confirmedAt: confirmedAt == _sentinel
          ? this.confirmedAt
          : confirmedAt as DateTime?,
      rejectedAt:
          rejectedAt == _sentinel ? this.rejectedAt : rejectedAt as DateTime?,
      rejectionExpiresAt: rejectionExpiresAt == _sentinel
          ? this.rejectionExpiresAt
          : rejectionExpiresAt as DateTime?,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      syncedAt: syncedAt == _sentinel ? this.syncedAt : syncedAt as DateTime?,
      syncStatus: syncStatus ?? this.syncStatus,
    );
  }
}

const Object _sentinel = Object();
