import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/repositories/drift_sender_bank_mapping_repository.dart';
import 'package:money_companion/domain/entities/sender_bank_mapping_entity.dart';
import 'package:money_companion/domain/repositories/sender_bank_mapping_repository.dart';
import 'package:money_companion/domain/usecases/resolve_bank_for_sender_usecase.dart';
import 'package:money_companion/engine/parser/bank_profile.dart';

class _FakeSenderBankMappingRepository implements SenderBankMappingRepository {
  final Map<String, SenderBankMappingEntity> _mappings = {};

  void seed(SenderBankMappingEntity mapping) {
    _mappings[mapping.normalizedSenderId] = mapping;
  }

  @override
  Future<SenderBankMappingEntity?> getBySender(String senderId) async {
    return _mappings[DriftSenderBankMappingRepository.normalizeSenderId(
      senderId,
    )];
  }

  @override
  Future<SenderBankMappingEntity?> getConfirmedBySender(String senderId) async {
    final mapping = await getBySender(senderId);
    return mapping?.status == SenderBankMappingStatus.confirmed
        ? mapping
        : null;
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
        mapping.suppressesDiscovery(now ?? DateTime.now().toUtc())) {
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
    return mapping?.suppressesDiscovery(now ?? DateTime.now().toUtc()) ?? false;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  const adibSms =
      'Trx. of AED 50.00 on your a/c ****0535 at ABU DHABI NATIONAL OIL '
      'ABU DHABI AE. Avl Bal is AED 12956.50';

  test('confirmed ADIB mapping resolves sender ADIB to an existing profile',
      () async {
    final repo = _FakeSenderBankMappingRepository()
      ..seed(_mapping(
        senderId: 'ADIB',
        bankKey: 'dubai_bank',
        status: SenderBankMappingStatus.confirmed,
      ));
    final resolver = ResolveBankForSenderUseCase(mappingRepository: repo);

    final resolution = await resolver(
      rawMessage: adibSms,
      senderId: 'ADIB',
      bankProfiles: const [],
      now: DateTime.utc(2026, 6, 16),
    );

    expect(resolution.source, BankSenderResolutionSource.confirmedMapping);
    expect(resolution.profile?.bankKey, 'dubai_bank');
    expect(resolution.suppressesDiscovery, isTrue);
    expect(
      BankProfiles.detect(
        adibSms,
        senderId: 'ADIB',
        extraProfiles: resolution.bankProfiles,
      )?.bankKey,
      'dubai_bank',
    );
  });

  test('rejected mapping prevents discovery eligibility during cooldown',
      () async {
    final now = DateTime.utc(2026, 6, 16);
    final repo = _FakeSenderBankMappingRepository()
      ..seed(_mapping(
        senderId: 'ADIB',
        status: SenderBankMappingStatus.rejected,
        rejectedAt: now.subtract(const Duration(days: 1)),
        rejectionExpiresAt: now.add(const Duration(days: 29)),
      ));
    final resolver = ResolveBankForSenderUseCase(mappingRepository: repo);

    final resolution = await resolver(
      rawMessage: adibSms,
      senderId: 'ADIB',
      bankProfiles: const [],
      now: now,
    );

    expect(resolution.source, BankSenderResolutionSource.rejectedMapping);
    expect(resolution.profile, isNull);
    expect(resolution.suppressesDiscovery, isTrue);
  });

  test('pending mapping is not trusted', () async {
    final repo = _FakeSenderBankMappingRepository()
      ..seed(_mapping(
        senderId: 'ADIB',
        bankKey: 'dubai_bank',
        status: SenderBankMappingStatus.pending,
      ));
    final resolver = ResolveBankForSenderUseCase(mappingRepository: repo);

    final resolution = await resolver(
      rawMessage: adibSms,
      senderId: 'ADIB',
      bankProfiles: const [],
      now: DateTime.utc(2026, 6, 16),
    );

    expect(resolution.source, BankSenderResolutionSource.pendingMapping);
    expect(resolution.hasTrustedProfile, isFalse);
    expect(resolution.profile, isNull);
    expect(resolution.suppressesDiscovery, isFalse);
  });

  test('unknown sender remains generic-parser eligible', () async {
    final resolver = ResolveBankForSenderUseCase(
      mappingRepository: _FakeSenderBankMappingRepository(),
    );

    final resolution = await resolver(
      rawMessage: adibSms,
      senderId: 'UNKNOWNBANK',
      bankProfiles: const [],
      now: DateTime.utc(2026, 6, 16),
    );

    expect(resolution.source, BankSenderResolutionSource.unknown);
    expect(resolution.profile, isNull);
    expect(resolution.bankProfiles, isEmpty);
    expect(resolution.suppressesDiscovery, isFalse);
  });
}

SenderBankMappingEntity _mapping({
  required String senderId,
  required SenderBankMappingStatus status,
  String? bankKey,
  DateTime? rejectedAt,
  DateTime? rejectionExpiresAt,
}) {
  final now = DateTime.utc(2026, 6, 16);
  return SenderBankMappingEntity(
    id: 'mapping-$senderId-${status.name}',
    senderId: senderId,
    normalizedSenderId: DriftSenderBankMappingRepository.normalizeSenderId(
      senderId,
    ),
    bankKey: bankKey,
    suggestedBankName: 'Abu Dhabi Islamic Bank',
    suggestedCountry: 'AE',
    confidence: 0.98,
    status: status,
    source: SenderBankMappingSource.userManual,
    firstSeenAt: now,
    lastSeenAt: now,
    confirmedAt: status == SenderBankMappingStatus.confirmed ? now : null,
    rejectedAt: rejectedAt,
    rejectionExpiresAt: rejectionExpiresAt,
    createdAt: now,
    updatedAt: now,
    syncedAt: null,
    syncStatus: SenderBankMappingSyncStatus.pending,
  );
}
