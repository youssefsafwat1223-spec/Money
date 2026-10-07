// CAP-7 (`capture_notify_v2`): the notification journey after an iOS import.
//   - owner rule: an item the native side already alerted for (status `sent`:
//     push_attempted true, or the App Intent's own banner) is never alerted again;
//   - an item nobody alerted for gets ONE alert, and the persisted state blocks a
//     second one (T-I8);
//   - a backlog of more than 3 fresh transactions is ONE summary, not N (T-I7 /
//     T-D10 logic), and every row is still imported;
//   - a native alert replaced by a local import is corrected, but only when that
//     alert is still delivered.
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
import 'package:money_companion/domain/usecases/add_transaction_usecase.dart';
import 'package:money_companion/domain/usecases/ingest_captured_message_usecase.dart';
import 'package:money_companion/engine/ai/ai_parser_client.dart';
import 'package:money_companion/features/capture/services/capture_device_registration_service.dart';
import 'package:money_companion/features/capture/services/capture_import_ports.dart';
import 'package:money_companion/features/capture/services/capture_import_service.dart';
import 'package:money_companion/features/capture/services/capture_receipts.dart';
import 'package:money_companion/features/capture/services/capture_sync_service.dart';
import 'package:money_companion/features/capture/services/ledger_outbox_queue.dart';
import '../../domain/local_v2_support.dart';
import 'fake_native_capture_queue.dart';
import 'package:money_companion/features/capture/services/capture_notify_v2.dart';

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'memory-key';

  @override
  Future<String?> readStoredKey() async => 'memory-key';
}

class _Registration implements CaptureDeviceRegistrationService {
  @override
  Future<bool> isLinkedForCloud() async => true;

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


String _id(int n) => n.toRadixString(16).padLeft(64, '0');
final _received = DateTime.utc(2026, 4, 8, 9, 45);

String _sms(int n) => 'عملية شراء\nبطاقة:مدى;****4521\nمبلغ:SAR 4$n.00\n'
    'لدى:NETFLIX$n\nفي:2026-04-08 12:45\nالرصيد:SAR 2,310.50';

void main() {
  late AppDatabase db;
  late CaptureSyncService sync;
  late FakeNativeCaptureQueue queue;
  late IngestCapturedMessageUseCase ingest;

  late List<String> individual;
  late List<int> summaries;
  late List<String> corrections;
  late List<String> withdrawn;
  late Set<String> delivered; // native alerts still on the lock screen

  CaptureNotifyV2 notify() => CaptureNotifyV2(
        state: CaptureNotificationState(db),
        showIndividual: (local) async =>
            individual.add(local.transactionId ?? 'none'),
        showSummary: (count) async => summaries.add(count),
        withdrawNativeAlert: (id) async {
          withdrawn.add(id);
          return delivered.remove(id);
        },
        showCorrection: (tx) async => corrections.add(tx),
      );

  /// Imports [n] locally-bound items with native status [status] and returns the
  /// import report (the real CaptureImportService + local parser).
  Future<List<CaptureImportItem>> importItems(int n,
      {String status = 'pending', int from = 1}) async {
    for (var i = from; i < from + n; i++) {
      queue.items.add(FakeQueueItem(_id(i),
          text: _sms(i),
          ownerUid: 'user-A',
          localOnly: true,
          status: status,
          receivedAt: _received.add(Duration(minutes: i))));
    }
    final report = await CaptureImportService(
      queue: queue,
      server: _NoServer(),
      captureSyncService: sync,
      receipts: CaptureReceipts(db),
      ingestLocal: CaptureImportService.localIngest(ingest),
      sessionUid: () => 'user-A',
      replicaOwnerUid: () async => 'user-A',
      ownershipGuard: _Guard(),
    ).run();
    return report.imported;
  }

  setUp(() async {
    db = await AppDatabase.open(
      executor: NativeDatabase.memory(),
      keyStore: _MemoryKeyStore(),
    );
    final txRepo = DriftTransactionRepository(
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
    ingest = IngestCapturedMessageUseCase(AddTransactionUseCase(
      transactionRepository: txRepo,
      merchantCategoryRepository: DriftMerchantCategoryRepository(db),
      suspectedDuplicateRepository: DriftSuspectedDuplicateRepository(db),
      accountRepository: DriftAccountRepository(db),
      dedupStore: DriftDedupStore(db),
      parserIsolate: const FakeParserIsolate(),
      aiClient: _SpyAi(),
      loadAiConsent: () async => true,
      installId: 'install',
    ));
    queue = FakeNativeCaptureQueue()..setOwner('user-A');
    individual = [];
    summaries = [];
    corrections = [];
    withdrawn = [];
    delivered = {};
  });

  tearDown(() async => db.close());

  group('owner rule: no duplicate alert (T-D9 logic)', () {
    test(
        'native already alerted (push_attempted true / App Intent banner): the '
        'app shows nothing', () async {
      final imported = await importItems(2, status: 'sent');
      expect(imported, hasLength(2));
      await notify().alertForImport(imported);
      expect(individual, isEmpty);
      expect(summaries, isEmpty);
      expect(corrections, isEmpty, reason: 'nothing delivered to correct');
    });

    test('nobody alerted: the app alerts once, then the state blocks a second',
        () async {
      final imported = await importItems(1);
      await notify().alertForImport(imported);
      expect(individual, hasLength(1));
      expect(await CaptureNotificationState(db).stateOf(_id(1)),
          CaptureAlertState.app);

      await notify().alertForImport(imported); // a replay of the same drain
      expect(individual, hasLength(1), reason: 'T-I8: state past none blocks');
    });

    test('an already-imported item never alerts', () async {
      await notify().alertForImport([
        CaptureImportItem(id: _id(1), path: CaptureImportPath.alreadyImported),
      ]);
      expect(individual, isEmpty);
    });
  });

  group('offline backlog summary (T-I7 / T-D10 logic)', () {
    test('more than 3 fresh transactions: ONE summary, rows still imported',
        () async {
      final imported = await importItems(5);
      await notify().alertForImport(imported);
      expect(summaries, [5]);
      expect(individual, isEmpty);
      final rows = await db.customSelect('SELECT id FROM transactions;').get();
      expect(rows, hasLength(5), reason: 'every capture stays individually durable');
      for (var i = 1; i <= 5; i++) {
        expect(await CaptureNotificationState(db).stateOf(_id(i)),
            CaptureAlertState.summary);
      }
      await notify().alertForImport(imported);
      expect(summaries, [5], reason: 'a replay does not summarise again');
    });

    test('exactly 3 are individual, 4 are summarised', () async {
      await notify().alertForImport(await importItems(3));
      expect(individual, hasLength(3));
      expect(summaries, isEmpty);

      await notify().alertForImport(await importItems(4, from: 10));
      expect(summaries, [4]);
      expect(individual, hasLength(3));
    });

    test('items an earlier channel alerted for are not counted', () async {
      final imported = [
        ...await importItems(3, status: 'sent'),
        ...await importItems(2, from: 10),
      ];
      await notify().alertForImport(imported);
      expect(summaries, isEmpty, reason: 'only 2 fresh');
      expect(individual, hasLength(2));
    });
  });

  group('correction ("Transaction added")', () {
    test('the stale native alert is replaced once, only if still delivered',
        () async {
      final imported = await importItems(2, status: 'sent');
      delivered = {_id(1)}; // the user swiped the other one away
      await notify().alertForImport(imported);
      expect(withdrawn.toSet(), {_id(1), _id(2)});
      expect(corrections, hasLength(1));
      expect(await CaptureNotificationState(db).stateOf(_id(1)),
          CaptureAlertState.corrected);
      expect(await CaptureNotificationState(db).stateOf(_id(2)), isNull);

      withdrawn.clear();
      await notify().alertForImport(imported);
      expect(withdrawn.contains(_id(1)), isFalse,
          reason: 'a corrected capture is not corrected twice');
    });
  });
}
