import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/db/ownership_guard.dart';
import 'package:money_companion/data/repositories/drift_dedup_store.dart';
import 'package:money_companion/data/repositories/drift_merchant_category_repository.dart';
import 'package:money_companion/data/repositories/drift_smart_inbox_repository.dart';
import 'package:money_companion/data/repositories/drift_suspected_duplicate_repository.dart';
import 'package:money_companion/data/repositories/drift_transaction_repository.dart';
import 'package:money_companion/data/repositories/drift_user_settings_repository.dart';
import 'package:money_companion/domain/entities/captured_message.dart';
import 'package:money_companion/domain/usecases/add_transaction_usecase.dart';
import 'package:money_companion/domain/usecases/ingest_captured_message_usecase.dart';
import 'package:money_companion/features/capture/services/capture_device_registration_service.dart';
import 'package:money_companion/features/capture/services/capture_sync_service.dart';
import 'package:money_companion/features/capture/services/native_capture_bridge.dart';
import 'package:money_companion/features/capture/services/shared_capture_handoff_service.dart';

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'memory-key';

  @override
  Future<String?> readStoredKey() async => 'memory-key';
}

class _FakeRegistrationService implements CaptureDeviceRegistrationService {
  @override
  Future<void> linkToCurrentUser() async {}

  @override
  Future<String?> readDeviceSecret() async => null;

  @override
  Future<void> syncApnsToken(ApnsTokenInfo token) async {}

  @override
  Future<void> syncBackendState() async {}

  @override
  Future<void> syncNativeState() async {}

  @override
  Future<void> unlinkCurrentDevice() async {}
}

void main() {
  late AppDatabase db;
  late CaptureSyncService captureSync;
  late IngestCapturedMessageUseCase ingest;

  setUp(() async {
    db = await AppDatabase.open(
      executor: NativeDatabase.memory(),
      keyStore: _MemoryKeyStore(),
    );
    captureSync = CaptureSyncService(
      settingsRepository: DriftUserSettingsRepository(db),
      transactionRepository: DriftTransactionRepository(db),
      dedupStore: DriftDedupStore(db),
      smartInboxRepository: DriftSmartInboxRepository(db),
      suspectedDuplicateRepository: DriftSuspectedDuplicateRepository(db),
      registrationService: _FakeRegistrationService(),
      ownershipGuard: OwnershipGuard(),
      currentUserId: () => null,
      backendConfigured: false,
    );
    ingest = IngestCapturedMessageUseCase(
      AddTransactionUseCase(
        transactionRepository: DriftTransactionRepository(db),
        merchantCategoryRepository: DriftMerchantCategoryRepository(db),
        suspectedDuplicateRepository: DriftSuspectedDuplicateRepository(db),
      ),
    );
  });

  tearDown(() async => db.close());

  SharedCapturedMessage message(String id, String text) =>
      SharedCapturedMessage(
        id: id,
        text: text,
        sender: 'SNB',
        source: CapturedMessageSource.iosShortcut,
        receivedAt: DateTime.utc(2026, 8, 20, 12),
        status: 'sent',
      );

  Future<CapturedMessageResult> ingestMessage(SharedCapturedMessage native) =>
      ingest.fromCapturedMessage(
        CapturedMessage(
          text: native.text,
          senderId: native.sender,
          source: native.source,
          receivedAt: native.receivedAt,
        ),
        onDeviceOnly: true,
      );

  test('unprocessable capture is durable before ack and retains the raw SMS',
      () async {
    const raw = 'تم تنفيذ حركة بنكية غير مدعومة على بطاقتك';
    final native = message('payload-unparseable', raw);
    final result = await ingestMessage(native);
    expect(result.disposition, CapturedMessageDisposition.unprocessable);
    expect(result.transactionId, isNull);

    var ackObservedDurableState = false;
    final handoff = SharedCaptureHandoffService(
      captureSyncService: captureSync,
      isOwnerCurrent: () async => true,
      acknowledge: (payloadId) async {
        final items = await DriftSmartInboxRepository(db).getOpen();
        final marker = await captureSync.transactionIdForPayload(payloadId);
        ackObservedDurableState = items.length == 1 && marker != null;
        return true;
      },
    );

    final outcome = await handoff.complete(
      message: native,
      disposition: result.disposition,
      transactionId: result.transactionId,
    );

    expect(outcome, SharedCaptureHandoffOutcome.acknowledged);
    expect(ackObservedDurableState, isTrue,
        reason: 'the raw capture must be durable before native removal');
    final items = await DriftSmartInboxRepository(db).getOpen();
    expect(items, hasLength(1));
    expect(items.single.payloadId, 'payload-unparseable');
    expect(items.single.type, 'needs_review');
    expect(items.single.body, raw, reason: 'the exact raw SMS must survive');
    expect(
      await captureSync.transactionIdForPayload('payload-unparseable'),
      'smart_inbox:local_capture:payload-unparseable',
    );
  });

  test('re-drain of one unprocessable payload creates one review item',
      () async {
    const raw = 'تم تنفيذ حركة بنكية غير مدعومة على بطاقتك';
    final native = message('payload-replayed', raw);
    final result = await ingestMessage(native);
    var ackSucceeds = false;
    var ackCalls = 0;
    final handoff = SharedCaptureHandoffService(
      captureSyncService: captureSync,
      isOwnerCurrent: () async => true,
      acknowledge: (_) async {
        ackCalls++;
        return ackSucceeds;
      },
    );

    expect(
      await handoff.complete(
        message: native,
        disposition: result.disposition,
        transactionId: result.transactionId,
      ),
      SharedCaptureHandoffOutcome.retained,
      reason: 'models a crash/native-ack failure after the DB commit',
    );
    expect(await captureSync.isPayloadImported('payload-replayed'), isTrue);
    await db.pruneOldDedupHashes();
    expect(await captureSync.isPayloadImported('payload-replayed'), isTrue,
        reason: 'capture_payload markers are permanent replay authority');

    ackSucceeds = true;
    expect(
      await handoff.complete(
        message: native,
        disposition: result.disposition,
        transactionId: result.transactionId,
      ),
      SharedCaptureHandoffOutcome.acknowledged,
    );

    expect(await DriftSmartInboxRepository(db).getOpen(), hasLength(1));
    expect(ackCalls, 2);
  });

  test('a genuinely ignored OTP still acknowledges without review spam',
      () async {
    final native = message(
      'payload-otp',
      'رمز التحقق الخاص بك هو 123456 ولا تشاركه مع أحد',
    );
    final result = await ingestMessage(native);
    expect(result.disposition, CapturedMessageDisposition.ignored);
    expect(result.transactionId, isNull);
    final acked = <String>[];

    await SharedCaptureHandoffService(
      captureSyncService: captureSync,
      isOwnerCurrent: () async => true,
      acknowledge: (id) async {
        acked.add(id);
        return true;
      },
    ).complete(
      message: native,
      disposition: result.disposition,
      transactionId: result.transactionId,
    );

    expect(acked, ['payload-otp']);
    expect(await DriftSmartInboxRepository(db).getOpen(), isEmpty);
  });

  test('a committed confirmation/review transaction still acknowledges',
      () async {
    final native = message(
      'payload-review-transaction',
      'عملية شراء\nمبلغ:SAR 82.00\nلدى:LOCAL ROASTER\nفي:2026-04-08 18:30',
    );
    final result = await ingestMessage(native);
    expect(result.disposition, CapturedMessageDisposition.requestConfirmation);
    expect(result.transactionId, isNotNull);
    var durableAtAck = false;

    final outcome = await SharedCaptureHandoffService(
      captureSyncService: captureSync,
      isOwnerCurrent: () async => true,
      acknowledge: (payloadId) async {
        durableAtAck = await db.count('transactions') == 1 &&
            await captureSync.transactionIdForPayload(payloadId) ==
                result.transactionId;
        return true;
      },
    ).complete(
      message: native,
      disposition: result.disposition,
      transactionId: result.transactionId,
    );

    expect(outcome, SharedCaptureHandoffOutcome.acknowledged);
    expect(durableAtAck, isTrue);
  });

  test('ownership change rolls back the unsupported row and never acks',
      () async {
    const raw = 'تم تنفيذ حركة بنكية غير مدعومة على بطاقتك';
    final native = message('payload-stale-owner', raw);
    final result = await ingestMessage(native);
    var ownerChecks = 0;
    var acked = false;

    final future = SharedCaptureHandoffService(
      captureSyncService: captureSync,
      // complete pre-check + transaction pre-check pass; the transaction's
      // post-write check observes sign-out/account change and must roll back.
      isOwnerCurrent: () async => ++ownerChecks < 3,
      acknowledge: (_) async {
        acked = true;
        return true;
      },
    ).complete(
      message: native,
      disposition: result.disposition,
      transactionId: result.transactionId,
    );

    await expectLater(future, throwsA(isA<StaleOwnershipException>()));
    expect(acked, isFalse);
    expect(await DriftSmartInboxRepository(db).getOpen(), isEmpty);
    expect(await captureSync.isPayloadImported('payload-stale-owner'), isFalse);
  });
}
