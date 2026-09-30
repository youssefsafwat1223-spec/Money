import '../../domain/entities/sender_bank_mapping_entity.dart';
import '../../engine/parser/bank_profile.dart';
import '../../domain/repositories/sender_bank_mapping_repository.dart';

class BankDiscoveryController {
  const BankDiscoveryController({
    required SenderBankMappingRepository repository,
    this.rejectCooldown = const Duration(days: 30),
  }) : _repository = repository;

  final SenderBankMappingRepository _repository;
  final Duration rejectCooldown;

  Future<SenderBankMappingEntity> confirm(SenderBankMappingEntity mapping) {
    return _repository.confirm(
      mappingId: mapping.id,
      bankKey: mapping.bankKey,
    );
  }

  /// The user names the bank themselves. Only the sender -> bank matching is
  /// stored; the mapping is saved as [SenderBankMappingSource.userManual] and
  /// confirmed with the chosen catalog profile's key.
  Future<SenderBankMappingEntity> chooseBank(
    SenderBankMappingEntity mapping,
    BankProfile profile,
  ) async {
    final saved = await _repository.saveSuggestion(SenderBankMappingDraft(
      senderId: mapping.senderId,
      bankKey: profile.bankKey,
      suggestedBankName: profile.displayName,
      suggestedCountry: profile.country ?? mapping.suggestedCountry,
      confidence: 1.0,
      source: SenderBankMappingSource.userManual,
    ));
    return _repository.confirm(mappingId: saved.id, bankKey: profile.bankKey);
  }

  Future<SenderBankMappingEntity> reject(SenderBankMappingEntity mapping) {
    return _repository.reject(
      mappingId: mapping.id,
      cooldown: rejectCooldown,
    );
  }

  Future<void> askLater(SenderBankMappingEntity mapping) async {
    // Intentionally keep the mapping pending. The next UX layer can decide when
    // to surface it again.
  }
}
