import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/theme/app_colors.dart';
import 'package:money_companion/domain/entities/bank_discovery_models.dart';
import 'package:money_companion/domain/entities/sender_bank_mapping_entity.dart';
import 'package:money_companion/domain/repositories/sender_bank_mapping_repository.dart';
import 'package:money_companion/domain/services/bank_discovery_service.dart';
import 'package:money_companion/engine/ai/bank_discovery_client.dart';
import 'package:money_companion/engine/parser/parse_result.dart';
import 'package:money_companion/features/bank_discovery/bank_discovery_confirmation_sheet.dart';
import 'package:money_companion/features/bank_discovery/bank_discovery_controller.dart';
import 'package:money_companion/features/capture/capture_runtime.dart';

class _MemorySenderBankMappingRepository
    implements SenderBankMappingRepository {
  _MemorySenderBankMappingRepository(this.mapping);

  SenderBankMappingEntity mapping;

  @override
  Future<SenderBankMappingEntity?> getBySender(String senderId) async {
    return mapping.senderId.toLowerCase() == senderId.toLowerCase()
        ? mapping
        : null;
  }

  @override
  Future<SenderBankMappingEntity?> getConfirmedBySender(String senderId) async {
    final value = await getBySender(senderId);
    return value?.status == SenderBankMappingStatus.confirmed ? value : null;
  }

  @override
  Future<SenderBankMappingEntity?> getActiveSuggestionBySender(
    String senderId, {
    DateTime? now,
  }) async {
    final value = await getBySender(senderId);
    if (value == null) return null;
    if (value.status == SenderBankMappingStatus.pending) return value;
    if (value.status == SenderBankMappingStatus.rejected &&
        value.suppressesDiscovery(now ?? DateTime.now().toUtc())) {
      return value;
    }
    return null;
  }

  @override
  Future<bool> suppressesDiscoveryPrompt(
    String senderId, {
    DateTime? now,
  }) async {
    final value = await getBySender(senderId);
    return value?.suppressesDiscovery(now ?? DateTime.now().toUtc()) ?? false;
  }

  @override
  Future<SenderBankMappingEntity> saveSuggestion(
    SenderBankMappingDraft draft,
  ) async {
    final now = (draft.now ?? DateTime.now()).toUtc();
    mapping = SenderBankMappingEntity(
      id: mapping.id,
      senderId: draft.senderId,
      normalizedSenderId: draft.senderId.toUpperCase(),
      bankKey: draft.bankKey,
      suggestedBankName: draft.suggestedBankName,
      suggestedCountry: draft.suggestedCountry,
      confidence: draft.confidence,
      reason: draft.reason,
      status: SenderBankMappingStatus.pending,
      source: draft.source,
      firstSeenAt: now,
      lastSeenAt: now,
      confirmedAt: null,
      rejectedAt: null,
      rejectionExpiresAt: null,
      createdAt: now,
      updatedAt: now,
      syncedAt: null,
      syncStatus: SenderBankMappingSyncStatus.pending,
    );
    return mapping;
  }

  @override
  Future<SenderBankMappingEntity> confirm({
    required String mappingId,
    String? bankKey,
    DateTime? now,
  }) async {
    final timestamp = (now ?? DateTime.now()).toUtc();
    mapping = mapping.copyWith(
      status: SenderBankMappingStatus.confirmed,
      bankKey: bankKey,
      confirmedAt: timestamp,
      rejectedAt: null,
      rejectionExpiresAt: null,
      updatedAt: timestamp,
    );
    return mapping;
  }

  @override
  Future<SenderBankMappingEntity> reject({
    required String mappingId,
    required Duration cooldown,
    DateTime? now,
  }) async {
    final timestamp = (now ?? DateTime.now()).toUtc();
    mapping = mapping.copyWith(
      status: SenderBankMappingStatus.rejected,
      confirmedAt: null,
      rejectedAt: timestamp,
      rejectionExpiresAt: timestamp.add(cooldown),
      updatedAt: timestamp,
    );
    return mapping;
  }

  @override
  Future<List<SenderBankMappingEntity>> getAll() async => [mapping];

  @override
  Future<List<SenderBankMappingEntity>> pendingSync() async => [mapping];

  @override
  Future<void> markSynced(String id, {DateTime? now}) async {}

  @override
  Future<void> markSyncFailed(String id, {DateTime? now}) async {}

  @override
  Future<void> delete(String id) async {}
}

class _CountingBankDiscoveryClient implements BankDiscoveryClient {
  int callCount = 0;

  @override
  Future<BankDiscoverySuggestion?> detectBank(
    BankDiscoveryRequest request,
  ) async {
    callCount++;
    return const BankDiscoverySuggestion(
      suggestedBankName: 'Abu Dhabi Islamic Bank',
      bankKeySuggestion: 'adib_ae',
      country: 'AE',
      confidence: 0.97,
      reason: 'High confidence ADIB sender match.',
    );
  }
}

void main() {
  test('CaptureRuntime emits pending bank discovery UI trigger state',
      () async {
    final mapping = _pendingMapping();
    final next = CaptureRuntime.instance.bankDiscoveryRequests.first;

    CaptureRuntime.instance.requestBankDiscoveryConfirmation(mapping);

    expect(await next, mapping);
  });

  test('confirm updates mapping to confirmed', () async {
    final repository = _MemorySenderBankMappingRepository(_pendingMapping());
    final controller = BankDiscoveryController(repository: repository);

    final confirmed = await controller.confirm(repository.mapping);

    expect(confirmed.status, SenderBankMappingStatus.confirmed);
    expect(confirmed.confirmedAt, isNotNull);
  });

  test('reject updates mapping to rejected with cooldown', () async {
    final repository = _MemorySenderBankMappingRepository(_pendingMapping());
    final controller = BankDiscoveryController(repository: repository);

    final rejected = await controller.reject(repository.mapping);

    expect(rejected.status, SenderBankMappingStatus.rejected);
    expect(rejected.rejectedAt, isNotNull);
    expect(rejected.rejectionExpiresAt, isNotNull);
  });

  test('ask later leaves mapping pending', () async {
    final repository = _MemorySenderBankMappingRepository(_pendingMapping());
    final controller = BankDiscoveryController(repository: repository);

    await controller.askLater(repository.mapping);

    expect(repository.mapping.status, SenderBankMappingStatus.pending);
    expect(repository.mapping.confirmedAt, isNull);
    expect(repository.mapping.rejectedAt, isNull);
  });

  test('confirmed mapping skips future Gemini calls', () async {
    final repository = _MemorySenderBankMappingRepository(_pendingMapping());
    final controller = BankDiscoveryController(repository: repository);
    await controller.confirm(repository.mapping);

    final client = _CountingBankDiscoveryClient();
    final service = BankDiscoveryService(
      mappingRepository: repository,
      client: client,
      loadAiConsent: () async => true,
    );

    final result = await service.discoverIfEligible(
      rawSms: 'Dear customer, ADIB alerts are enabled.',
      senderId: 'ADIB',
      availableProfiles: const [],
      parseResult: ParseResult.notTransaction(),
    );

    expect(client.callCount, 0);
    expect(result.status, BankDiscoveryResultStatus.skipped);
    expect(result.reason, 'confirmed_mapping');
  });

  testWidgets('bottom sheet renders suggestion and confirm action',
      (tester) async {
    final repository = _MemorySenderBankMappingRepository(_pendingMapping());
    await tester.pumpWidget(_TestApp(repository: repository));

    expect(find.text('تأكيد البنك'), findsOneWidget);
    expect(find.textContaining('Abu Dhabi Islamic Bank'), findsWidgets);
    expect(find.text('ADIB'), findsOneWidget);
    expect(find.text('AE'), findsOneWidget);
    expect(find.text('97%'), findsOneWidget);
    expect(find.textContaining('ADIB sender match'), findsOneWidget);

    await tester.tap(find.text('تأكيد هذا البنك'));
    await tester.pumpAndSettle();

    expect(repository.mapping.status, SenderBankMappingStatus.confirmed);
  });
}

class _TestApp extends StatelessWidget {
  const _TestApp({required this.repository});

  final SenderBankMappingRepository repository;

  @override
  Widget build(BuildContext context) {
    return ProviderScope(
      overrides: [
        senderBankMappingRepositoryProvider.overrideWithValue(repository),
      ],
      child: MaterialApp(
        theme: ThemeData(
          extensions: const [AppColors.light],
        ),
        home: Scaffold(
          body: BankDiscoveryConfirmationSheet(mapping: _pendingMapping()),
        ),
      ),
    );
  }
}

SenderBankMappingEntity _pendingMapping() {
  final now = DateTime.utc(2026, 6, 16);
  return SenderBankMappingEntity(
    id: 'mapping-adib',
    senderId: 'ADIB',
    normalizedSenderId: 'ADIB',
    bankKey: 'adib_ae',
    suggestedBankName: 'Abu Dhabi Islamic Bank',
    suggestedCountry: 'AE',
    confidence: 0.97,
    reason: 'High confidence ADIB sender match.',
    status: SenderBankMappingStatus.pending,
    source: SenderBankMappingSource.gemini,
    firstSeenAt: now,
    lastSeenAt: now,
    confirmedAt: null,
    rejectedAt: null,
    rejectionExpiresAt: null,
    createdAt: now,
    updatedAt: now,
    syncedAt: null,
    syncStatus: SenderBankMappingSyncStatus.pending,
  );
}
