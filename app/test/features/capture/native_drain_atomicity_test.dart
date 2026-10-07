// CAP-0b — native (non-relay) drain: tx.id = capture_id and the receipt commits
// in the SAME SQLite transaction as the transaction row(s) and their ledger
// outbox row(s) (I-3 / I-5; gate G0 T-I1/T-I2 on the native path).
//
// Real in-memory Drift DB, real repositories, real AddTransactionUseCase and
// SharedCaptureHandoffService. app_shell's per-message sequence is mirrored by
// [drainOne] (guard -> ingest with CaptureCommit -> handoff.complete -> ack),
// with a crash injected at each boundary.
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/db/ownership_guard.dart';
import 'package:money_companion/data/repositories/drift_account_repository.dart';
import 'package:money_companion/data/repositories/drift_dedup_store.dart';
import 'package:money_companion/data/repositories/drift_merchant_category_repository.dart';
import 'package:money_companion/data/repositories/drift_smart_inbox_repository.dart';
import 'package:money_companion/data/repositories/drift_suspected_duplicate_repository.dart';
import 'package:money_companion/data/repositories/drift_transaction_repository.dart';
import 'package:money_companion/data/repositories/drift_user_settings_repository.dart';
import 'package:money_companion/domain/entities/captured_message.dart';
import 'package:money_companion/domain/entities/supporting_entities.dart';
import 'package:money_companion/domain/usecases/add_transaction_usecase.dart';
import 'package:money_companion/domain/usecases/ingest_captured_message_usecase.dart';
import 'package:money_companion/engine/models/parsed_transaction.dart';
import 'package:money_companion/engine/models/transaction_source.dart';
import 'package:money_companion/engine/models/transaction_type.dart';
import 'package:money_companion/engine/parser/parse_result.dart';
import 'package:money_companion/features/capture/services/capture_backend_client.dart';
import 'package:money_companion/features/capture/services/capture_device_registration_service.dart';
import 'package:money_companion/features/capture/services/capture_sync_service.dart';
import 'package:money_companion/features/capture/services/ledger_outbox_queue.dart';
import 'package:money_companion/features/capture/services/native_capture_bridge.dart';
import 'package:money_companion/features/capture/services/shared_capture_handoff_service.dart';

import '../../domain/local_v2_support.dart';

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'memory-key';

  @override
  Future<String?> readStoredKey() async => 'memory-key';
}

class _Registration implements CaptureDeviceRegistrationService {
  @override
  Future<void> syncBackendState() async {}

  @override
  Future<String?> readDeviceSecret() async => 'device-secret';

  @override
  Future<bool> isLinkedForCloud() async => true;

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _Backend implements CaptureBackendClient {
  _Backend(this.captures);
  final List<ProcessedCaptureDto> captures;

  @override
  Future<List<ProcessedCaptureDto>> syncCaptures({
    required String installId,
    required String deviceSecret,
    List<String> ackPayloadIds = const [],
  }) async =>
      ackPayloadIds.isEmpty ? captures : const [];

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('unexpected backend call: ${invocation.memberName}');
}

class _Guard extends OwnershipGuard {
  static const _token =
      AdmissionToken(ownerUid: 'user-A', generation: 'gen-A');

  @override
  Future<AdmissionToken> capture() async => _token;

  @override
  Future<bool> isCurrent(AdmissionToken token) async => token == _token;
}

class _Crash implements Exception {
  const _Crash(this.at);
  final String at;
}

const _raw = 'عملية شراء\nبطاقة:مدى;****4521\nمبلغ:SAR 45.00\n'
    'لدى:NETFLIX\nفي:2026-04-08 12:45\nالرصيد:SAR 2,310.50';
const _rawFee =
    'شراء إنترنت\nمبلغ:99 USD\nالرسوم/الضريبة:SAR 7.44\nمن:APPLE.CO';

ParseResult _usdParse() => ParseResult.success(ParsedTransaction(
      amountText: '99',
      amount: 99,
      currency: 'USD',
      type: TransactionType.payment,
      source: TransactionSource.card,
      rawMerchant: 'APPLE.CO',
      parseConfidence: 0.95,
    ));

void main() {
  late AppDatabase db;
  late CaptureSyncService svc;
  late IngestCapturedMessageUseCase ingest;
  late DriftTransactionRepository txRepo;
  late SharedCaptureHandoffService handoff;
  late Set<String> nativeQueue;
  var txnDepth = 0;
  var networkInsideTxn = false;
  String? crashAt;
  var ingestCalls = 0;

  CaptureSyncService buildSvc(List<ProcessedCaptureDto> relay) =>
      CaptureSyncService(
        settingsRepository: DriftUserSettingsRepository(db),
        transactionRepository: txRepo,
        dedupStore: DriftDedupStore(db),
        smartInboxRepository: DriftSmartInboxRepository(db),
        suspectedDuplicateRepository: DriftSuspectedDuplicateRepository(db),
        registrationService: _Registration(),
        ownershipGuard: _Guard(),
        currentUserId: () => 'user-A',
        accountRepository: DriftAccountRepository(db),
        client: _Backend(relay),
        backendConfigured: true,
        loadInstallId: () async => 'install-id',
      );

  IngestCapturedMessageUseCase buildIngest({ParseResult? parse}) =>
      IngestCapturedMessageUseCase(AddTransactionUseCase(
        transactionRepository: txRepo,
        merchantCategoryRepository: DriftMerchantCategoryRepository(db),
        suspectedDuplicateRepository: DriftSuspectedDuplicateRepository(db),
        accountRepository: DriftAccountRepository(db),
        dedupStore: DriftDedupStore(db),
        parserIsolate: FakeParserIsolate(parse),
        isLocalAutoConfirmV2: () => true,
        mayEnrichMerchant: () async => true,
        // Enrichment is a network call: it must run before the DB transaction.
        resolveMerchantCategory: (_) async {
          if (txnDepth > 0) networkInsideTxn = true;
          return null;
        },
      ));

  setUp(() async {
    db = await AppDatabase.open(
      executor: NativeDatabase.memory(),
      keyStore: _MemoryKeyStore(),
    );
    final settingsRepo = DriftUserSettingsRepository(db);
    await settingsRepo.saveSettings((await settingsRepo.getSettings())
        .copyWith(cloudConsentState: ConsentState.accepted));
    txRepo = DriftTransactionRepository(
      db,
      outboxQueue: LedgerOutboxQueue(
        db: db,
        isPushEnabled: () => true,
        getAuthUserId: () async => 'user-123',
      ),
    );
    svc = buildSvc(const []);
    ingest = buildIngest();
    nativeQueue = {};
    txnDepth = 0;
    networkInsideTxn = false;
    crashAt = null;
    ingestCalls = 0;
    handoff = SharedCaptureHandoffService(
      captureSyncService: svc,
      isOwnerCurrent: () async => true,
      acknowledge: (id) async {
        if (crashAt == 'beforeAck') throw const _Crash('beforeAck');
        nativeQueue.remove(id);
        return true;
      },
    );
  });

  tearDown(() async => db.close());

  SharedCapturedMessage item(String? id, {String text = _raw}) =>
      SharedCapturedMessage(
        id: id,
        text: text,
        sender: 'SNB',
        source: CapturedMessageSource.iosShare,
        receivedAt: DateTime.utc(2026, 4, 8, 9, 45),
      );

  /// app_shell._consumeSharedInput's per-message sequence, with crash points.
  Future<void> drainOne(
    SharedCapturedMessage message, {
    IngestCapturedMessageUseCase? useCase,
  }) async {
    final payloadId = message.id?.trim();
    if (payloadId != null &&
        payloadId.isNotEmpty &&
        await svc.reconcileImportedPayload(payloadId)) {
      nativeQueue.remove(message.id);
      return;
    }
    final commit = payloadId == null || payloadId.isEmpty
        ? null
        : svc.captureCommitFor(payloadId);
    ingestCalls++;
    final result = await (useCase ?? ingest).fromCapturedMessage(
      CapturedMessage(
        text: message.text,
        senderId: message.sender,
        source: message.source,
        receivedAt: message.receivedAt,
      ),
      onDeviceOnly: true,
      capture: commit == null
          ? null
          : CaptureCommit(
              captureId: commit.captureId,
              runAtomically: (action) {
                txnDepth++;
                return commit.runAtomically(action).whenComplete(() {
                  txnDepth--;
                });
              },
              writeReceipt: (txId) async {
                if (crashAt == 'beforeCommit') {
                  // Every row (primary, fee, outbox) is already written here.
                  throw const _Crash('beforeCommit');
                }
                await commit.writeReceipt(txId);
              },
            ),
    );
    if (crashAt == 'afterCommit') throw const _Crash('afterCommit');
    await handoff.complete(
      message: message,
      disposition: result.disposition,
      transactionId: result.transactionId,
    );
  }

  /// Runs the drain; a crash injected at [point] aborts it like a kill would.
  Future<void> drainCrashing(SharedCapturedMessage m, String point,
      {IngestCapturedMessageUseCase? useCase}) async {
    crashAt = point;
    nativeQueue.add(m.id!);
    await expectLater(drainOne(m, useCase: useCase), throwsA(isA<_Crash>()));
    crashAt = null;
  }

  Future<List<String>> txIds() async => (await db
          .customSelect('SELECT id FROM transactions ORDER BY id;')
          .get())
      .map((r) => r.read<String>('id'))
      .toList();

  Future<int> count(String table, [String where = '1=1']) async =>
      (await db.customSelect('SELECT COUNT(*) c FROM $table WHERE $where;').getSingle())
          .read<int>('c');

  Future<int> receipts(String payloadId) =>
      count('dedup_hashes', "hash = 'capture_payload:$payloadId'");

  group('single-row capture', () {
    test('id == capture_id; tx, outbox and receipt all present; acked',
        () async {
      nativeQueue.add('cap1');
      await drainOne(item('cap1'));

      expect(await txIds(), ['cap1']);
      expect(await count('ledger_sync_outbox', "transaction_id = 'cap1'"), 1);
      expect(await svc.transactionIdForPayload('cap1'), 'cap1');
      expect(nativeQueue, isEmpty);
      expect(networkInsideTxn, isFalse);
    });

    test('crash before commit: nothing persisted; re-drain yields one row',
        () async {
      await drainCrashing(item('cap1'), 'beforeCommit');
      expect(await txIds(), isEmpty, reason: 'rolled back with the receipt');
      expect(await count('ledger_sync_outbox'), 0);
      expect(await receipts('cap1'), 0);
      expect(nativeQueue, {'cap1'}, reason: 'not acked');

      await drainOne(item('cap1'));
      expect(await txIds(), ['cap1']);
      expect(await receipts('cap1'), 1);
      expect(nativeQueue, isEmpty);
    });

    test('crash after commit, before handoff/ack: re-drain adds nothing',
        () async {
      await drainCrashing(item('cap1'), 'afterCommit');
      expect(await txIds(), ['cap1'], reason: 'committed with its receipt');
      expect(await receipts('cap1'), 1);
      expect(nativeQueue, {'cap1'});

      final before = ingestCalls;
      await drainOne(item('cap1'));
      expect(ingestCalls, before, reason: 'guard: no second ingest');
      expect(await txIds(), ['cap1']);
      expect(await count('ledger_sync_outbox'), 1);
      expect(await count('suspected_duplicates'), 0,
          reason: 'no suspected-duplicate row, no second banner');
      expect(nativeQueue, isEmpty);
    });

    test('crash after receipt, before native ack: re-drain acks only',
        () async {
      await drainCrashing(item('cap1'), 'beforeAck');
      expect(await receipts('cap1'), 1);
      expect(nativeQueue, {'cap1'});

      await drainOne(item('cap1'));
      expect(await txIds(), ['cap1']);
      expect(await count('suspected_duplicates'), 0);
      expect(nativeQueue, isEmpty);
    });

    test('transaction exists without receipt: receipt written, no 2nd row',
        () async {
      // State no longer produced by this build, but the guard must heal it.
      await drainOne(item('cap1'));
      await db.customStatement(
          "DELETE FROM dedup_hashes WHERE hash = 'capture_payload:cap1';");
      nativeQueue.add('cap1');

      final before = ingestCalls;
      await drainOne(item('cap1'));
      expect(ingestCalls, before);
      expect(await txIds(), ['cap1']);
      expect(await svc.transactionIdForPayload('cap1'), 'cap1');
      expect(nativeQueue, isEmpty);
    });

    test('Android UUID item id is used verbatim as the transaction id',
        () async {
      const uuid = '3f2b8c1e-5d4a-4e6b-9a7c-0123456789ab';
      nativeQueue.add(uuid);
      await drainOne(item(uuid));
      expect(await txIds(), [uuid]);
      expect(await receipts(uuid), 1);
    });
  });

  group('fee line', () {
    test('primary + fee + outbox rows + receipt commit together; ids derived',
        () async {
      final useCase = buildIngest(parse: _usdParse());
      nativeQueue.add('cap2');
      await drainOne(item('cap2', text: _rawFee), useCase: useCase);

      expect(await txIds(), ['cap2', 'cap2:fee']);
      expect(await count('ledger_sync_outbox'), 2);
      expect(await receipts('cap2'), 1);
      expect(await svc.transactionIdForPayload('cap2'), 'cap2');
      expect(nativeQueue, isEmpty);
    });

    test('crash after both rows were written: neither row survives', () async {
      final useCase = buildIngest(parse: _usdParse());
      await drainCrashing(item('cap2', text: _rawFee), 'beforeCommit',
          useCase: useCase);
      expect(await txIds(), isEmpty);
      expect(await count('ledger_sync_outbox'), 0);
      expect(await receipts('cap2'), 0);

      await drainOne(item('cap2', text: _rawFee), useCase: useCase);
      expect(await txIds(), ['cap2', 'cap2:fee']);
    });

    test('crash after commit: re-drain keeps exactly one fee line', () async {
      final useCase = buildIngest(parse: _usdParse());
      await drainCrashing(item('cap2', text: _rawFee), 'afterCommit',
          useCase: useCase);
      await drainOne(item('cap2', text: _rawFee), useCase: useCase);
      expect(await txIds(), ['cap2', 'cap2:fee']);
      expect(await count('ledger_sync_outbox'), 2);
      expect(nativeQueue, isEmpty);
    });
  });

  group('suspected duplicate', () {
    test('row + receipt are atomic; id == capture_id; no 2nd row on retry',
        () async {
      await drainOne(item(null)); // earlier capture without a payload id
      final existing = (await txIds()).single;

      await drainCrashing(item('cap3'), 'beforeCommit');
      expect(await count('suspected_duplicates'), 0,
          reason: 'rolled back with the receipt');
      expect(await receipts('cap3'), 0);

      await drainOne(item('cap3'));
      expect(await txIds(), [existing], reason: 'duplicate is not a tx');
      expect(await count('suspected_duplicates', "id = 'cap3'"), 1);
      expect(await svc.transactionIdForPayload('cap3'), existing);
      expect(nativeQueue, isEmpty);

      // Crash after that commit: the re-delivery writes nothing further.
      nativeQueue.add('cap3');
      await drainOne(item('cap3'));
      expect(await count('suspected_duplicates'), 1);
    });
  });

  group('relay and native for the same capture_id', () {
    ProcessedCaptureDto relayCapture(String id) => ProcessedCaptureDto(
          payloadId: id,
          status: 'processed',
          parsed: const {
            'amount': 45.0,
            'amount_text': '45.00',
            'currency': 'SAR',
            'type': 'payment',
            'merchant': 'NETFLIX',
          },
          notification: const {},
          sanitizedText: _raw,
          createdAt: DateTime.utc(2026, 4, 8, 9, 45),
        );

    test('relay first, then native item: one row, item acked', () async {
      await buildSvc([relayCapture('cap4')]).sync();
      expect(await txIds(), ['cap4']);

      nativeQueue.add('cap4');
      final before = ingestCalls;
      await drainOne(item('cap4'));
      expect(ingestCalls, before);
      expect(await txIds(), ['cap4']);
      expect(nativeQueue, isEmpty);
    });

    test('native first, then relay: one row', () async {
      nativeQueue.add('cap4');
      await drainOne(item('cap4'));
      expect(await txIds(), ['cap4']);

      final result = await buildSvc([relayCapture('cap4')]).sync();
      expect(result.importedPayloadIds, {'cap4'});
      expect(await txIds(), ['cap4']);
      expect(await count('ledger_sync_outbox'), 1);
    });
  });

  group('no payload id', () {
    test('keeps random ids, no receipt, item retained (unchanged)', () async {
      await drainOne(item(null));
      final ids = await txIds();
      expect(ids, hasLength(1));
      expect(ids.single, isNot(contains(':')));
      expect(await count('dedup_hashes', "hash LIKE 'capture_payload:%'"), 0);
    });

    test('AddTransactionUseCase without a CaptureCommit uses random ids',
        () async {
      final useCase = buildIngest(parse: _usdParse());
      final a = await useCase.fromCapturedMessage(CapturedMessage(
        text: _rawFee,
        source: CapturedMessageSource.unknown,
        receivedAt: DateTime.utc(2026, 4, 8),
      ));
      expect(a.transactionId, isNotNull);
      expect(a.addTransactionResult.secondary?.transaction?.id,
          isNot(endsWith(':fee')));
    });
  });
}
