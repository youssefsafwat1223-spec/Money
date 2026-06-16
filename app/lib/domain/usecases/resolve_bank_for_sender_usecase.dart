import '../../engine/parser/bank_profile.dart';
import '../../engine/parser/normalizer.dart';
import '../entities/sender_bank_mapping_entity.dart';
import '../repositories/sender_bank_mapping_repository.dart';

enum BankSenderResolutionSource {
  directProfile,
  confirmedMapping,
  rejectedMapping,
  pendingMapping,
  unknown,
}

class BankSenderResolution {
  const BankSenderResolution({
    required this.source,
    required this.bankProfiles,
    this.profile,
    this.mapping,
  });

  final BankSenderResolutionSource source;
  final List<BankProfile> bankProfiles;
  final BankProfile? profile;
  final SenderBankMappingEntity? mapping;

  bool get hasTrustedProfile =>
      source == BankSenderResolutionSource.directProfile ||
      (source == BankSenderResolutionSource.confirmedMapping &&
          profile != null);

  bool get suppressesDiscovery =>
      source == BankSenderResolutionSource.confirmedMapping ||
      source == BankSenderResolutionSource.rejectedMapping;
}

class ResolveBankForSenderUseCase {
  const ResolveBankForSenderUseCase({
    required SenderBankMappingRepository mappingRepository,
  }) : _mappingRepository = mappingRepository;

  final SenderBankMappingRepository _mappingRepository;

  Future<BankSenderResolution> call({
    required String rawMessage,
    required String? senderId,
    required List<BankProfile> bankProfiles,
    DateTime? now,
  }) async {
    final text = Normalizer.normalizeCurrencyTokens(
      Normalizer.normalize(rawMessage),
    );
    final direct = BankProfiles.detect(
      text,
      senderId: senderId,
      extraProfiles: bankProfiles,
    );
    if (direct != null) {
      return BankSenderResolution(
        source: BankSenderResolutionSource.directProfile,
        bankProfiles: bankProfiles,
        profile: direct,
      );
    }

    final cleanSender = senderId?.trim();
    if (cleanSender == null || cleanSender.isEmpty) {
      return BankSenderResolution(
        source: BankSenderResolutionSource.unknown,
        bankProfiles: bankProfiles,
      );
    }

    final mapping = await _mappingRepository.getBySender(cleanSender);
    if (mapping == null) {
      return BankSenderResolution(
        source: BankSenderResolutionSource.unknown,
        bankProfiles: bankProfiles,
      );
    }

    if (mapping.status == SenderBankMappingStatus.confirmed) {
      final mappedProfile = mapping.bankKey == null
          ? null
          : BankProfiles.findByKey(
              mapping.bankKey!,
              extraProfiles: bankProfiles,
            );
      final profiles = mappedProfile == null
          ? bankProfiles
          : _upsertProfileWithSenderAlias(
              bankProfiles,
              mappedProfile,
              cleanSender,
            );
      return BankSenderResolution(
        source: BankSenderResolutionSource.confirmedMapping,
        bankProfiles: profiles,
        profile: mappedProfile,
        mapping: mapping,
      );
    }

    if (mapping.status == SenderBankMappingStatus.rejected &&
        mapping.suppressesDiscovery(now ?? DateTime.now().toUtc())) {
      return BankSenderResolution(
        source: BankSenderResolutionSource.rejectedMapping,
        bankProfiles: bankProfiles,
        mapping: mapping,
      );
    }

    if (mapping.status == SenderBankMappingStatus.pending) {
      return BankSenderResolution(
        source: BankSenderResolutionSource.pendingMapping,
        bankProfiles: bankProfiles,
        mapping: mapping,
      );
    }

    return BankSenderResolution(
      source: BankSenderResolutionSource.unknown,
      bankProfiles: bankProfiles,
      mapping: mapping,
    );
  }

  List<BankProfile> _upsertProfileWithSenderAlias(
    List<BankProfile> bankProfiles,
    BankProfile profile,
    String senderId,
  ) {
    final aliased = _withSenderAlias(profile, senderId);
    final profiles = <BankProfile>[];
    var replaced = false;
    for (final existing in bankProfiles) {
      if (existing.bankKey == aliased.bankKey) {
        profiles.add(aliased);
        replaced = true;
      } else {
        profiles.add(existing);
      }
    }
    if (!replaced) profiles.add(aliased);
    return profiles;
  }

  BankProfile _withSenderAlias(BankProfile profile, String senderId) {
    if (profile.matchesSender(senderId)) return profile;
    return profile.copyWith(
      senderIds: [...profile.senderIds, senderId],
    );
  }
}
