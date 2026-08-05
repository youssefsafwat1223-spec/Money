import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart';
import 'package:http/testing.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/repositories/drift_account_repository.dart';
import 'package:money_companion/data/repositories/drift_dedup_store.dart';
import 'package:money_companion/data/repositories/drift_suspected_duplicate_repository.dart';
import 'package:money_companion/data/repositories/drift_transaction_repository.dart';
import 'package:money_companion/data/repositories/drift_user_settings_repository.dart';
import 'package:money_companion/data/repositories/supabase_transaction_repository.dart';
import 'package:money_companion/domain/entities/transaction_entity.dart';
import 'package:money_companion/domain/entities/account_entity.dart';
import 'package:money_companion/domain/entities/supporting_entities.dart';
import 'package:money_companion/features/capture/services/capture_backend_client.dart';
import 'package:money_companion/features/capture/services/capture_device_registration_service.dart';
import 'package:money_companion/features/capture/services/capture_sync_service.dart';
import 'package:money_companion/features/capture/services/native_capture_bridge.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'memory-key';

  @override
  Future<String?> readStoredKey() async => 'memory-key';
}

class _FakeRegistrationService implements CaptureDeviceRegistrationService {
  @override
  Future<void> syncNativeState() async {}

  @override
  Future<String?> readDeviceSecret() async => 'device-secret';

  @override
  Future<void> linkToCurrentUser() async {}

  @override
  Future<void> unlinkCurrentDevice() async {}

  @override
  Future<void> syncApnsToken(ApnsTokenInfo token) async {}
}

class _FakeCaptureBackendClient implements CaptureBackendClient {
  _FakeCaptureBackendClient(this._captures);

  final List<ProcessedCaptureDto> _captures;
  final ackedPayloadIds = <String>[];
  final processedPayloadIds = <String>[];

  @override
  Future<void> processIosSms({
    required String installId,
    required String deviceSecret,
    required String payloadId,
    required String smsText,
    required DateTime receivedAt,
    required bool allowAi,
    String? sender,
    String? locale,
  }) async {
    processedPayloadIds.add(payloadId);
  }

  @override
  Future<List<ProcessedCaptureDto>> syncCaptures({
    required String installId,
    required String deviceSecret,
    List<String> ackPayloadIds = const [],
  }) async {
    ackedPayloadIds.addAll(ackPayloadIds);
    return ackPayloadIds.isEmpty ? _captures : const [];
  }

  @override
  Future<void> linkDevice({
    required String installId,
    required String deviceSecret,
    required String jwt,
  }) async {}

  @override
  Future<void> setDeviceConsent({
    required String installId,
    required String deviceSecret,
    required bool aiConsentGranted,
    required bool cloudProcessingEnabled,
  }) async {}

  @override
  Future<void> unlinkDevice({
    required String installId,
    required String deviceSecret,
  }) async {}

  @override
  Future<void> registerPushToken({
    required String installId,
    required String deviceSecret,
    required String apnsToken,
    required String apnsEnvironment,
  }) async {}

  @override
  Future<String> registerDevice({
    required String installId,
    String platform = 'ios',
  }) async =>
      'device-secret';
}

void main() {
  late AppDatabase db;
  late DriftUserSettingsRepository settingsRepository;

  setUp(() async {
    db = await AppDatabase.open(
      executor: NativeDatabase.memory(),
      keyStore: _MemoryKeyStore(),
    );
    settingsRepository = DriftUserSettingsRepository(db);
    final settings = await settingsRepository.getSettings();
    await settingsRepository.saveSettings(
      settings.copyWith(cloudConsentState: ConsentState.accepted),
    );
  });

  tearDown(() async {
    await db.close();
  });

  CaptureSyncService service(_FakeCaptureBackendClient client) {
    return CaptureSyncService(
      settingsRepository: settingsRepository,
      transactionRepository: DriftTransactionRepository(db),
      dedupStore: DriftDedupStore(db),
      suspectedDuplicateRepository: DriftSuspectedDuplicateRepository(db),
      registrationService: _FakeRegistrationService(),
      accountRepository: DriftAccountRepository(db),
      client: client,
      backendConfigured: true,
      loadInstallId: () async => 'install-id',
    );
  }

  test('needs_review capture records its transaction id', () async {
    final client = _FakeCaptureBackendClient([
      _capture(payloadId: 'payload-needs-review', status: 'needs_review'),
    ]);
    final syncService = service(client);

    final result = await syncService.sync();
    final transactionId =
        await syncService.transactionIdForPayload('payload-needs-review');

    expect(result.needsReviewTransactionIds, [transactionId]);
    expect(client.ackedPayloadIds, ['payload-needs-review']);
  });

  test('processed capture is not recorded for review', () async {
    final client = _FakeCaptureBackendClient([
      _capture(payloadId: 'payload-processed', status: 'processed'),
    ]);

    final result = await service(client).sync();

    expect(result.needsReviewTransactionIds, isEmpty);
    expect(client.ackedPayloadIds, ['payload-processed']);
  });

  test('AI hybrid relay capture keeps the smart transaction source', () async {
    final client = _FakeCaptureBackendClient([
      _capture(
        payloadId: 'payload-ai-hybrid',
        status: 'processed',
        parserSource: 'ai_hybrid',
      ),
    ]);

    await service(client).sync();

    final transactions = await DriftTransactionRepository(db).getAll();
    expect(transactions.single.source, TransactionSourceEntity.aiParsed);
  });

  test('processed capture is assigned to a matching currency account',
      () async {
    final accountRepo = DriftAccountRepository(db);
    final now = DateTime.utc(2026, 7, 5, 9);
    await accountRepo.create(AccountEntity(
      id: '',
      name: 'Main SAR',
      currency: 'SAR',
      type: AccountType.bank,
      initialBalance: null,
      currentBalance: null,
      isDefault: true,
      sortOrder: 0,
      createdAt: now,
      updatedAt: now,
    ));
    final client = _FakeCaptureBackendClient([
      _capture(
        payloadId: 'payload-egp',
        status: 'processed',
        currency: 'EGP',
      ),
    ]);

    await service(client).sync();

    final transactions = await DriftTransactionRepository(db).getAll();
    expect(transactions, hasLength(1));
    expect(transactions.single.currency, 'EGP');
    expect(transactions.single.accountId, isNotNull);

    final account = await accountRepo.getById(transactions.single.accountId!);
    expect(account?.currency, 'EGP');
  });

  test('outward transfer is grounded to payment so it counts as spending',
      () async {
    final client = _FakeCaptureBackendClient([
      _capture(
        payloadId: 'payload-transfer-out',
        status: 'processed',
        type: 'transfer',
        direction: 'debit',
        rawMessage: 'تم تحويل EGP 42 من حسابك إلى أحمد',
      ),
    ]);

    await service(client).sync();

    final transactions = await DriftTransactionRepository(db).getAll();
    expect(transactions, hasLength(1));
    expect(transactions.single.type, TransactionTypeEntity.payment);
  });

  test('inward transfer is grounded to income', () async {
    final client = _FakeCaptureBackendClient([
      _capture(
        payloadId: 'payload-transfer-in',
        status: 'processed',
        type: 'transfer',
        direction: 'credit',
        rawMessage: 'حوالة واردة EGP 42 من أحمد',
      ),
    ]);

    await service(client).sync();

    final transactions = await DriftTransactionRepository(db).getAll();
    expect(transactions, hasLength(1));
    expect(transactions.single.type, TransactionTypeEntity.income);
  });

  test('internal transfer between own accounts stays a neutral transfer',
      () async {
    final client = _FakeCaptureBackendClient([
      _capture(
        payloadId: 'payload-transfer-internal',
        status: 'processed',
        type: 'transfer',
        direction: 'debit',
        rawMessage: 'تحويل داخلي EGP 42 بين حساباتك',
      ),
    ]);

    await service(client).sync();

    final transactions = await DriftTransactionRepository(db).getAll();
    expect(transactions, hasLength(1));
    expect(transactions.single.type, TransactionTypeEntity.transfer);
  });

  test('Supabase-primary relay reuses canonical source payload and only acks',
      () async {
    const payloadId = 'payload-direct-existing';
    var transactionPosts = 0;
    final http = MockClient((request) async {
      if (request.method == 'POST') transactionPosts++;
      return Response(
        jsonEncode([_serverTransaction(payloadId)]),
        200,
        headers: const {
          'content-type': 'application/json',
          'content-range': '0-0/*',
        },
        request: request,
      );
    });
    final directRepository = SupabaseTransactionRepository(
      db: db,
      getClient: () => SupabaseClient(
        'https://example.supabase.co',
        'anon-key',
        httpClient: http,
        accessToken: () async => 'qa-token',
      ),
      getAuthUserId: () async => 'qa-user',
    );
    final client = _FakeCaptureBackendClient([
      _capture(payloadId: payloadId, status: 'processed'),
    ]);
    final syncService = CaptureSyncService(
      settingsRepository: settingsRepository,
      transactionRepository: DriftTransactionRepository(db),
      dedupStore: DriftDedupStore(db),
      suspectedDuplicateRepository: DriftSuspectedDuplicateRepository(db),
      registrationService: _FakeRegistrationService(),
      accountRepository: null,
      client: client,
      backendConfigured: true,
      loadInstallId: () async => 'install-id',
      directTransactionRepository: directRepository,
      isSupabasePrimaryEnabled: () => true,
    );

    final result = await syncService.sync();

    expect(transactionPosts, 0);
    expect(result.importedPayloadIds, {payloadId});
    expect(client.ackedPayloadIds, [payloadId]);
    expect(
      await syncService.transactionIdForPayload(payloadId),
      '10000000-0000-4000-8000-000000000001',
    );
    expect(await db.count('transactions'), 1);
  });

  test('Supabase-primary relay inserts a missing capture before ack', () async {
    const payloadId = 'payload-relay-missing';
    var transactionPosts = 0;
    final http = MockClient((request) async {
      if (request.method == 'GET') {
        return Response(
          'null',
          200,
          headers: const {'content-type': 'application/json'},
          request: request,
        );
      }
      transactionPosts++;
      final row = _serverTransaction(payloadId);
      return Response(
        jsonEncode(row),
        201,
        headers: const {'content-type': 'application/json'},
        request: request,
      );
    });
    final directRepository = SupabaseTransactionRepository(
      db: db,
      getClient: () => SupabaseClient(
        'https://example.supabase.co',
        'anon-key',
        httpClient: http,
        accessToken: () async => 'qa-token',
      ),
      getAuthUserId: () async => 'qa-user',
    );
    final client = _FakeCaptureBackendClient([
      _capture(payloadId: payloadId, status: 'processed'),
    ]);
    final syncService = CaptureSyncService(
      settingsRepository: settingsRepository,
      transactionRepository: DriftTransactionRepository(db),
      dedupStore: DriftDedupStore(db),
      suspectedDuplicateRepository: DriftSuspectedDuplicateRepository(db),
      registrationService: _FakeRegistrationService(),
      client: client,
      backendConfigured: true,
      loadInstallId: () async => 'install-id',
      directTransactionRepository: directRepository,
      isSupabasePrimaryEnabled: () => true,
    );

    final result = await syncService.sync();

    expect(transactionPosts, 1);
    expect(result.importedPayloadIds, {payloadId});
    expect(client.ackedPayloadIds, [payloadId]);
    expect(
      await syncService.transactionIdForPayload(payloadId),
      '10000000-0000-4000-8000-000000000001',
    );
  });

  test('failed ack followed by dedup prune must not re-import the capture',
      () async {
    // ack يفشل دائمًا — يبقى صف الـ relay على الخادم، وسجل الاستيراد المحلي
    // (capture_payload:) هو الحماية الوحيدة من الاستيراد الثاني.
    final client = _AckFailingBackendClient([
      _capture(payloadId: 'payload-ack-fails', status: 'processed'),
    ]);
    final syncService = service(client);

    // فشل الـ ack يصل للمستدعي (يلتقطه app_shell) — الاستيراد نفسه اكتمل.
    await expectLater(
      syncService.sync(),
      throwsA(isA<CaptureBackendException>()),
    );
    expect(await db.count('transactions'), 1);

    // كان prune يحذف كل علامات capture_payload: لأنها مخزّنة عند epoch-0.
    await db.pruneOldDedupHashes();
    expect(await syncService.isPayloadImported('payload-ack-fails'), isTrue);

    // الخادم ما يزال يعيد نفس الـ capture (لم يُؤكَّد حذفها) — يجب تخطّيها.
    await expectLater(
      syncService.sync(),
      throwsA(isA<CaptureBackendException>()),
    );
    expect(await db.count('transactions'), 1);
  });

  test('prune still removes ordinary dedup hashes older than the cutoff',
      () async {
    final dedupStore = DriftDedupStore(db);
    final old = DateTime.utc(2020, 1, 1);
    await dedupStore.mark('ordinary-old-hash',
        transactionId: 'tx-old', occurredAt: old);
    await db.pruneOldDedupHashes();
    expect(await dedupStore.transactionIdFor('ordinary-old-hash', old), isNull);
  });

  test('concurrent sync calls share one run and import the capture once',
      () async {
    final client = _SlowFetchBackendClient([
      _capture(payloadId: 'payload-concurrent', status: 'processed'),
    ]);
    final syncService = service(client);

    // الاستئناف + ضغطة الإشعار يستدعيان sync() في نفس اللحظة تقريبًا.
    final results = await Future.wait([syncService.sync(), syncService.sync()]);

    expect(client.fetchCalls, 1);
    expect(results[0].importedPayloadIds, {'payload-concurrent'});
    expect(results[1].importedPayloadIds, {'payload-concurrent'});
    expect(await db.count('transactions'), 1);

    // بعد اكتمال الجولة، استدعاء جديد يبدأ جولة جديدة (القفل يتحرّر).
    await syncService.sync();
    expect(client.fetchCalls, 2);
    expect(await db.count('transactions'), 1);
  });

  test('duplicate capture with unresolved original imports as pending review',
      () async {
    final client = _FakeCaptureBackendClient([
      _capture(
        payloadId: 'payload-orphan-duplicate',
        status: 'duplicate',
        duplicateOfPayloadId: 'payload-unknown-original',
      ),
    ]);

    final result = await service(client).sync();

    final transactions = await DriftTransactionRepository(db).getAll();
    expect(transactions, hasLength(1));
    expect(transactions.single.status, TransactionStatus.pending);
    expect(
      transactions.single.duplicateStatus,
      DuplicateStatus.suspiciousDuplicate,
    );
    expect(result.needsReviewTransactionIds, [transactions.single.id]);
  });
}

class _AckFailingBackendClient extends _FakeCaptureBackendClient {
  _AckFailingBackendClient(super.captures);

  @override
  Future<List<ProcessedCaptureDto>> syncCaptures({
    required String installId,
    required String deviceSecret,
    List<String> ackPayloadIds = const [],
  }) async {
    if (ackPayloadIds.isNotEmpty) {
      throw const CaptureBackendException('ack_failed_503');
    }
    return _captures;
  }
}

class _SlowFetchBackendClient extends _FakeCaptureBackendClient {
  _SlowFetchBackendClient(super.captures);

  int fetchCalls = 0;

  @override
  Future<List<ProcessedCaptureDto>> syncCaptures({
    required String installId,
    required String deviceSecret,
    List<String> ackPayloadIds = const [],
  }) async {
    if (ackPayloadIds.isNotEmpty) return const [];
    fetchCalls++;
    await Future<void>.delayed(const Duration(milliseconds: 50));
    return _captures;
  }
}

Map<String, dynamic> _serverTransaction(String payloadId) => {
      'id': '10000000-0000-4000-8000-000000000001',
      'user_id': 'qa-user',
      'client_request_id': null,
      'source_payload_id': payloadId,
      'amount': 42,
      'currency': 'SAR',
      'merchant': 'Coffee',
      'description': null,
      'category_id': null,
      'occurred_at': '2026-07-05T10:00:00.000Z',
      'source': 'ios_shortcut',
      'confidence': 0.9,
      'direction': 'debit',
      'transaction_type': 'expense',
      'server_account_id': null,
      'balance_after': null,
      'status': 'confirmed',
      'foreign_amount': null,
      'foreign_currency': null,
      'comparison_timestamp': '2026-07-05T10:00:00.000Z',
      'comparison_timestamp_source': 'sms_body',
      'metadata': const {
        'transaction_source': 'bank',
        'comparison_timestamp_source': 'sms_body',
      },
      'created_at': '2026-07-05T10:00:00.000Z',
      'updated_at': '2026-07-05T10:00:00.000Z',
      'deleted_at': null,
    };

ProcessedCaptureDto _capture({
  required String payloadId,
  required String status,
  String currency = 'SAR',
  String type = 'payment',
  String? direction,
  String? rawMessage,
  String? duplicateOfPayloadId,
  String? parserSource,
}) {
  return ProcessedCaptureDto(
    payloadId: payloadId,
    status: status,
    parsed: {
      'amount': 42,
      'currency': currency,
      'type': type,
      if (direction != null) 'direction': direction,
      if (parserSource != null) 'parserSource': parserSource,
      if (duplicateOfPayloadId != null) ...{
        'duplicateStatus': 'suspicious_duplicate',
        'possibleDuplicateOfPayloadId': duplicateOfPayloadId,
      },
      'rawMessage': rawMessage ?? 'Paid $currency 42 at Coffee',
      'merchant': 'Coffee',
      'occurredAt': DateTime.utc(2026, 7, 5, 10).toIso8601String(),
    },
    notification: const {},
    sanitizedText: 'Paid $currency 42 at Coffee',
    createdAt: DateTime.utc(2026, 7, 5, 10),
  );
}
