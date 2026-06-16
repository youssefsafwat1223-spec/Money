import '../entities/sender_bank_mapping_entity.dart';

class SenderBankMappingDraft {
  const SenderBankMappingDraft({
    required this.senderId,
    required this.suggestedBankName,
    required this.suggestedCountry,
    required this.confidence,
    this.bankKey,
    this.reason,
    this.source = SenderBankMappingSource.gemini,
    this.now,
  });

  final String senderId;
  final String? bankKey;
  final String suggestedBankName;
  final String suggestedCountry;
  final double confidence;
  final String? reason;
  final SenderBankMappingSource source;
  final DateTime? now;
}

abstract class SenderBankMappingRepository {
  Future<SenderBankMappingEntity?> getBySender(String senderId);

  Future<SenderBankMappingEntity?> getConfirmedBySender(String senderId);

  Future<SenderBankMappingEntity?> getActiveSuggestionBySender(
    String senderId, {
    DateTime? now,
  });

  Future<bool> suppressesDiscoveryPrompt(
    String senderId, {
    DateTime? now,
  });

  Future<SenderBankMappingEntity> saveSuggestion(SenderBankMappingDraft draft);

  Future<SenderBankMappingEntity> confirm({
    required String mappingId,
    String? bankKey,
    DateTime? now,
  });

  Future<SenderBankMappingEntity> reject({
    required String mappingId,
    required Duration cooldown,
    DateTime? now,
  });

  Future<List<SenderBankMappingEntity>> getAll();

  Future<List<SenderBankMappingEntity>> pendingSync();

  Future<void> markSynced(String id, {DateTime? now});

  Future<void> markSyncFailed(String id, {DateTime? now});

  Future<void> delete(String id);
}
