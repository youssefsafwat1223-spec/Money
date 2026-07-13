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
  Future<void> syncApnsToken(ApnsTokenInfo token) async {}
}

class _FakeCaptureBackendClient implements CaptureBackendClient {
  _FakeCaptureBackendClient(this._captures);

  final List<ProcessedCaptureDto> _captures;
  final ackedPayloadIds = <String>[];

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
      settings.copyWith(cloudProcessingEnabled: true),
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

  test('direct capture reuses canonical source payload and only acks relay',
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
      accountRepository: DriftAccountRepository(db),
      client: client,
      backendConfigured: true,
      loadInstallId: () async => 'install-id',
      directTransactionRepository: directRepository,
      isDirectCaptureEnabled: () => true,
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
}) {
  return ProcessedCaptureDto(
    payloadId: payloadId,
    status: status,
    parsed: {
      'amount': 42,
      'currency': currency,
      'type': type,
      if (direction != null) 'direction': direction,
      'rawMessage': rawMessage ?? 'Paid $currency 42 at Coffee',
      'merchant': 'Coffee',
      'occurredAt': DateTime.utc(2026, 7, 5, 10).toIso8601String(),
    },
    notification: const {},
    sanitizedText: 'Paid $currency 42 at Coffee',
    createdAt: DateTime.utc(2026, 7, 5, 10),
  );
}
