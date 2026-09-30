import '../../domain/entities/sender_bank_mapping_entity.dart';
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
