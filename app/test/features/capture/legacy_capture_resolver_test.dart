// CAP-6 Dart half / §4.7 + gate G2 A5, A6, A7, and the BL-2 hand-off to the
// import service: legacy v2 items are resolved by the ADOPTED replica's own
// evidence; whatever it cannot prove stays unbound, hint-less and unimportable;
// claimed items are imported locally only.
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
import 'package:money_companion/domain/usecases/add_transaction_usecase.dart';
import 'package:money_companion/domain/usecases/ingest_captured_message_usecase.dart';
import 'package:money_companion/engine/ai/ai_parser_client.dart';
import 'package:money_companion/features/capture/services/capture_device_registration_service.dart';
import 'package:money_companion/features/capture/services/capture_import_ports.dart';
import 'package:money_companion/features/capture/services/capture_import_service.dart';
import 'package:money_companion/features/capture/services/capture_receipts.dart';
import 'package:money_companion/features/capture/services/capture_sync_service.dart';
import 'package:money_companion/features/capture/services/legacy_capture_resolver.dart';
import 'package:money_companion/features/capture/services/ledger_outbox_queue.dart';
import 'package:money_companion/features/capture/services/unbound_capture_prompt_service.dart';

import '../../domain/local_v2_support.dart';
import 'fake_native_capture_queue.dart';

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'memory-key';

  @override
  Future<String?> readStoredKey() async => 'memory-key';
}

class _Registration implements CaptureDeviceRegistrationService {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _Guard extends OwnershipGuard {
  static const _token = AdmissionToken(ownerUid: 'user-A', generation: 'gen');
  @override
  Future<AdmissionToken> capture() async => _token;
  @override
  Future<bool> isCurrent(AdmissionToken token) async => token == _token;
}

class _SpyAi implements AiParserClient {
  int calls = 0;
  @override
  Future<AiParseResponse?> parse({
    required String sanitizedSms,
    required String senderId,
    required String installId,
  }) async {
    calls++;
    return null;
  }
}

class _NoServer implements CaptureServerPort {
  var uploads = 0;
  var fetches = 0;
  @override
  Future<CaptureServerFetch> fetchResults() async {
    fetches++;
    return const CaptureServerFetch(CaptureFetchStatus.ok);
  }

  @override
  Future<CaptureUploadStatus> retryUpload(m) async {
    uploads++;
    return CaptureUploadStatus.unavailable;
  }

  @override
  Future<void> acknowledge(List<String> payloadIds) async {}
}

const _raw = 'عملية شراء\nبطاقة:مدى;****4521\nمبلغ:SAR 45.00\n'
    'لدى:NETFLIX\nفي:2026-04-08 12:45\nالرصيد:SAR 2,310.50';
final _received = DateTime.utc(2026, 4, 8, 9, 45);
String _id(int n) => n.toRadixString(16).padLeft(64, '0');

void main() {
  late AppDatabase db;
  late CaptureSyncService sync;
  late FakeNativeCaptureQueue queue;
  late DriftTransactionRepository txRepo;
  late _SpyAi ai;
  late _NoServer server;
  late IngestCapturedMessageUseCase ingest;
  String? session;
  String? replica;

  FakeQueueItem legacy(String id, {String text = _raw}) =>
      FakeQueueItem(id, text: text, origin: 'legacy_v2', receivedAt: _received);

  LegacyCaptureResolver resolver({
    Future<List<LegacyCaptureItem>> Function()? items,
  }) =>
      LegacyCaptureResolver(
        queue: queue,
        db: db,
        sessionUid: () => session,
        replicaOwnerUid: () async => replica,
        legacyItems: items,
      );

  Future<List<LegacyCaptureItem>> listLegacy() async => [
        for (final i in queue.items)
          if (i.origin == 'legacy_v2' && i.unbound)
            LegacyCaptureItem(id: i.id, text: i.text, receivedAt: i.receivedAt),
      ];

  CaptureImportService importService() => CaptureImportService(
        queue: queue,
        server: server,
        captureSyncService: sync,
        receipts: CaptureReceipts(db),
        ingestLocal: CaptureImportService.localIngest(ingest),
        sessionUid: () => session,
        replicaOwnerUid: () async => replica,
        ownershipGuard: _Guard(),
      );

  Future<List<String>> txIds() async =>
      (await db.customSelect('SELECT id FROM transactions ORDER BY id;').get())
          .map((r) => r.read<String>('id'))
          .toList();

  setUp(() async {
    db = await AppDatabase.open(
      executor: NativeDatabase.memory(),
      keyStore: _MemoryKeyStore(),
    );
    txRepo = DriftTransactionRepository(
      db,
      outboxQueue: LedgerOutboxQueue(
        db: db,
        isPushEnabled: () => true,
        getAuthUserId: () async => 'user-A',
      ),
    );
    sync = CaptureSyncService(
      settingsRepository: DriftUserSettingsRepository(db),
      transactionRepository: txRepo,
      dedupStore: DriftDedupStore(db),
      smartInboxRepository: DriftSmartInboxRepository(db),
      suspectedDuplicateRepository: DriftSuspectedDuplicateRepository(db),
      registrationService: _Registration(),
      ownershipGuard: _Guard(),
      currentUserId: () => 'user-A',
      accountRepository: DriftAccountRepository(db),
      backendConfigured: true,
      loadInstallId: () async => 'install',
    );
    ai = _SpyAi();
    server = _NoServer();
    ingest = IngestCapturedMessageUseCase(AddTransactionUseCase(
      transactionRepository: txRepo,
      merchantCategoryRepository: DriftMerchantCategoryRepository(db),
      suspectedDuplicateRepository: DriftSuspectedDuplicateRepository(db),
      accountRepository: DriftAccountRepository(db),
      dedupStore: DriftDedupStore(db),
      parserIsolate: const FakeParserIsolate(),
      aiClient: ai,
      loadAiConsent: () async => true,
      installId: 'install',
    ));
    queue = FakeNativeCaptureQueue()..setOwner('user-A');
    session = 'user-A';
    replica = 'user-A';
  });

  tearDown(() async => db.close());

  group('resolve after adoption (§4.7)', () {
    test('receipt proves it consumed: the legacy item is removed', () async {
      await sync.markPayloadImported(
          payloadId: _id(1), transactionId: 'whatever');
      queue.items.addAll([legacy(_id(1)), legacy(_id(2))]);

      final removed = await resolver().resolve();

      expect(removed, 1);
      expect(queue.items.map((i) => i.id), [_id(2)]);
    });

    test('tx.id == capture_id proves it consumed: removed', () async {
      await ingest.fromCapturedMessage(
        const CapturedMessage(
            text: _raw,
            source: CapturedMessageSource.iosShortcut,
            receivedAt: null),
        onDeviceOnly: true,
        forceLocalAutoConfirm: true,
        capture: sync.captureCommitFor(_id(1)),
      );
      // Receipt lost; the transaction id is the capture id.
      await db.customStatement('DELETE FROM dedup_hashes;');
      queue.items.add(legacy(_id(1)));

      expect(await resolver().resolve(), 1);
      expect(queue.items, isEmpty);
    });

    test(
        'A5: nothing proves it consumed: stays unbound, no hint, never '
        'imported, never prompted', () async {
      queue.items.add(legacy(_id(1)));

      expect(await resolver().resolve(), 0);

      final item = queue.items.single;
      expect(item.unbound, isTrue);
      expect(item.hint, isNull);
      expect((await importService().run()).imported, isEmpty);
      expect(await txIds(), isEmpty);
      expect(
        await UnboundCapturePromptService(
          queue: queue,
          sessionUid: () => session,
          replicaOwnerUid: () async => replica,
          isEnabled: () => true,
        ).check(),
        isNull,
        reason: 'a hint-less item is never offered',
      );
      expect(ai.calls, 0);
      expect(server.uploads, 0);
    });

    test(
        'A6: random-id import with a lost receipt -> review annotation, never '
        'a second transaction', () async {
      // The old build imported this capture under a random id and lost the
      // receipt; the legacy queue still holds it under its capture id.
      await ingest.fromCapturedMessage(
        CapturedMessage(
            text: _raw,
            source: CapturedMessageSource.iosShortcut,
            receivedAt: _received),
        onDeviceOnly: true,
        forceLocalAutoConfirm: true,
      );
      final randomIdTx = await txIds();
      expect(randomIdTx, hasLength(1));
      queue.items.add(legacy(_id(7)));

      final removed = await resolver(items: listLegacy).resolve();

      expect(removed, 0, reason: 'not provably consumed: kept, not removed');
      expect(queue.lastSuspected, [_id(7)]);
      expect(queue.items.single.reviewState, 'suspected_already_imported');
      expect(queue.items.single.unbound, isTrue);
      expect((await importService().run()).imported, isEmpty);
      expect(await txIds(), randomIdTx, reason: 'no second transaction');
    });

    test('a different message at another time is NOT annotated', () async {
      await ingest.fromCapturedMessage(
        CapturedMessage(
            text: _raw,
            source: CapturedMessageSource.iosShortcut,
            receivedAt: _received),
        onDeviceOnly: true,
        forceLocalAutoConfirm: true,
      );
      queue.items.add(FakeQueueItem(_id(8),
          text: _raw,
          origin: 'legacy_v2',
          receivedAt: _received.add(const Duration(days: 3))));

      await resolver(items: listLegacy).resolve();

      expect(queue.items.single.reviewState, isNull);
    });

    test(
        'A7: ambiguous legacy claim + owner marker -> unbound, no hint, '
        'never imported', () async {
      // Owner marker says A, the build-50 server claim is ambiguous: native made
      // it unbound with no hint. Dart must not promote it.
      queue.items.add(legacy(_id(1)));
      queue.setOwner('user-A');

      await resolver().resolve();
      final report = await importService().run();

      expect(report.imported, isEmpty);
      expect(queue.items.single.unbound, isTrue);
      expect(queue.items.single.ownerUid, isNull);
      expect(await txIds(), isEmpty);
    });

    test('a quarantined/mismatched replica is never consulted', () async {
      await sync.markPayloadImported(
          payloadId: _id(1), transactionId: 'whatever');
      queue.items.add(legacy(_id(1)));
      replica = 'user-B';

      expect(await resolver().resolve(), 0);
      expect(queue.resolveCalls, 0);
      expect(queue.items, hasLength(1));
    });

    test(
        'only legacy unbound items are touched: a stamped item with a '
        'receipt is not removed by the resolver', () async {
      await sync.markPayloadImported(
          payloadId: _id(1), transactionId: 'whatever');
      queue.items.add(FakeQueueItem(_id(1), ownerUid: 'user-A'));

      await resolver().resolve();

      expect(queue.items, hasLength(1));
    });
  });

  group('BL-2 claimed items reach the import service local-only', () {
    test(
        'added items are parsed on device: no upload, no AI, one confirmed '
        'transaction + outbox', () async {
      queue.items.add(FakeQueueItem(_id(1),
          text: _raw,
          receivedAt: _received,
          hint: FakeNativeCaptureQueue.hintFor('user-A')));
      final prompt = UnboundCapturePromptService(
        queue: queue,
        sessionUid: () => session,
        replicaOwnerUid: () async => replica,
        isEnabled: () => true,
      );

      expect(await importService().run().then((r) => r.imported), isEmpty,
          reason: 'unbound is never imported automatically');
      expect(await prompt.add((await prompt.check())!),
          UnboundCaptureChoice.applied);
      final report = await importService().run();

      expect(report.imported.single.path, CaptureImportPath.local);
      expect(await txIds(), [_id(1)]);
      expect(
          (await db
                  .customSelect('SELECT COUNT(*) c FROM ledger_sync_outbox;')
                  .getSingle())
              .read<int>('c'),
          1);
      expect(server.uploads, 0);
      expect(ai.calls, 0);
      expect(queue.items, isEmpty);
    });
  });
}
