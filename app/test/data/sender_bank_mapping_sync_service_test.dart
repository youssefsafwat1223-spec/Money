import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/repositories/drift_sender_bank_mapping_repository.dart';
import 'package:money_companion/data/sync/sender_bank_mapping_sync_service.dart';
import 'package:money_companion/domain/entities/sender_bank_mapping_entity.dart';
import 'package:money_companion/domain/repositories/sender_bank_mapping_repository.dart';

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'memory-key';

  @override
  Future<String?> readStoredKey() async => 'memory-key';
}

class _FakeRemoteStore implements SenderBankMappingRemoteStore {
  final downloads = <RemoteSenderBankMapping>[];
  final uploads = <RemoteSenderBankMapping>[];
  bool failUpload = false;

  @override
  Future<List<RemoteSenderBankMapping>> download(String userId) async {
    return downloads.where((item) => item.userId == userId).toList();
  }

  @override
  Future<void> upload(List<RemoteSenderBankMapping> mappings) async {
    if (failUpload) throw StateError('upload failed');
    uploads.addAll(mappings);
  }
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late AppDatabase db;
  late DriftSenderBankMappingRepository repository;
  late _FakeRemoteStore remote;
  late SenderBankMappingSyncService service;

  setUp(() async {
    db = await AppDatabase.open(
      executor: NativeDatabase.memory(),
      keyStore: _MemoryKeyStore(),
    );
    repository = DriftSenderBankMappingRepository(db);
    remote = _FakeRemoteStore();
    service = SenderBankMappingSyncService(
      repository: repository,
      remoteStore: remote,
      currentUserId: () => 'user-1',
      now: () => DateTime.utc(2026, 6, 16, 12),
    );
  });

  tearDown(() async {
    await db.close();
  });

  test('uploads confirmed and rejected mappings only', () async {
    final pending = await repository.saveSuggestion(_draft('ADIB'));
    await repository.confirm(mappingId: pending.id, bankKey: 'adib_ae');

    final rejectedDraft = await repository.saveSuggestion(_draft('ENBD'));
    await repository.reject(
      mappingId: rejectedDraft.id,
      cooldown: const Duration(days: 30),
    );

    await repository.saveSuggestion(_draft('LOWCONF'));

    await service.uploadPending();

    expect(remote.uploads.map((item) => item.mapping.senderId),
        containsAll(['ADIB', 'ENBD']));
    expect(remote.uploads.map((item) => item.mapping.senderId),
        isNot(contains('LOWCONF')));
    expect((await repository.getBySender('ADIB'))?.syncStatus,
        SenderBankMappingSyncStatus.synced);
    expect((await repository.getBySender('ENBD'))?.syncStatus,
        SenderBankMappingSyncStatus.synced);
  });

  test('downloads remote mapping into local store', () async {
    remote.downloads.add(RemoteSenderBankMapping(
      remoteId: '00000000-0000-4000-8000-000000000001',
      userId: 'user-1',
      mapping: _entity(
        id: '00000000-0000-4000-8000-000000000001',
        senderId: 'ADIB',
        status: SenderBankMappingStatus.confirmed,
        updatedAt: DateTime.utc(2026, 6, 16, 10),
      ),
    ));

    await service.download();

    final local = await repository.getConfirmedBySender('adib');
    expect(local, isNotNull);
    expect(local!.bankKey, 'adib_ae');
    expect(local.syncStatus, SenderBankMappingSyncStatus.synced);
  });

  test('local confirmed wins over remote pending', () async {
    final draft = await repository.saveSuggestion(_draft('ADIB'));
    final local = await repository.confirm(
      mappingId: draft.id,
      bankKey: 'adib_ae',
      now: DateTime.utc(2026, 6, 16, 9),
    );

    await repository.upsertRemote(
      _entity(
        id: 'remote-pending',
        senderId: 'ADIB',
        status: SenderBankMappingStatus.pending,
        updatedAt: DateTime.utc(2026, 6, 16, 11),
      ),
    );

    final after = await repository.getBySender('ADIB');
    expect(after?.id, local.id);
    expect(after?.status, SenderBankMappingStatus.confirmed);
  });

  test('latest updated_at wins for same status', () async {
    final draft = await repository.saveSuggestion(_draft('ADIB'));
    await repository.reject(
      mappingId: draft.id,
      cooldown: const Duration(days: 30),
      now: DateTime.utc(2026, 6, 16, 9),
    );

    await repository.upsertRemote(
      _entity(
        id: 'remote-rejected',
        senderId: 'ADIB',
        suggestedBankName: 'Remote ADIB',
        status: SenderBankMappingStatus.rejected,
        updatedAt: DateTime.utc(2026, 6, 16, 11),
      ),
    );

    final after = await repository.getBySender('ADIB');
    expect(after?.suggestedBankName, 'Remote ADIB');
    expect(after?.status, SenderBankMappingStatus.rejected);
  });

  test('remote payload excludes raw financial SMS fields', () async {
    final draft = await repository.saveSuggestion(_draft('ADIB'));
    final confirmed = await repository.confirm(
      mappingId: draft.id,
      bankKey: 'adib_ae',
    );
    final json = RemoteSenderBankMapping(
      remoteId: confirmed.id,
      userId: 'user-1',
      mapping: confirmed,
    ).toJson();

    expect(json.keys, isNot(contains('raw_sms')));
    expect(json.keys, isNot(contains('raw_message')));
    expect(json.keys, isNot(contains('amount')));
    expect(json.keys, isNot(contains('merchant')));
    expect(json['sender_id'], 'ADIB');
  });
}

SenderBankMappingDraft _draft(String senderId) {
  return SenderBankMappingDraft(
    senderId: senderId,
    bankKey: '${senderId.toLowerCase()}_key',
    suggestedBankName: '$senderId Bank',
    suggestedCountry: 'AE',
    confidence: 0.97,
    reason: 'User-confirmed sender mapping.',
    now: DateTime.utc(2026, 6, 16, 8),
  );
}

SenderBankMappingEntity _entity({
  required String id,
  required String senderId,
  required SenderBankMappingStatus status,
  required DateTime updatedAt,
  String suggestedBankName = 'Abu Dhabi Islamic Bank',
}) {
  final created = DateTime.utc(2026, 6, 16, 8);
  return SenderBankMappingEntity(
    id: id,
    senderId: senderId,
    normalizedSenderId:
        DriftSenderBankMappingRepository.normalizeSenderId(senderId),
    bankKey: 'adib_ae',
    suggestedBankName: suggestedBankName,
    suggestedCountry: 'AE',
    confidence: 0.97,
    reason: 'Synced mapping.',
    status: status,
    source: SenderBankMappingSource.remote,
    firstSeenAt: created,
    lastSeenAt: updatedAt,
    confirmedAt: status == SenderBankMappingStatus.confirmed ? updatedAt : null,
    rejectedAt: status == SenderBankMappingStatus.rejected ? updatedAt : null,
    rejectionExpiresAt: status == SenderBankMappingStatus.rejected
        ? updatedAt.add(const Duration(days: 30))
        : null,
    createdAt: created,
    updatedAt: updatedAt,
    syncedAt: null,
    syncStatus: SenderBankMappingSyncStatus.synced,
  );
}
