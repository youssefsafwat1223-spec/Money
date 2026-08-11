import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/db/planning_cutover.dart';
import 'package:money_companion/data/repositories/drift_merchant_category_repository.dart';
import 'package:money_companion/data/repositories/drift_suspected_duplicate_repository.dart';
import 'package:money_companion/data/repositories/drift_transaction_repository.dart';
import 'package:money_companion/domain/entities/captured_message.dart';
import 'package:money_companion/domain/usecases/add_transaction_usecase.dart';
import 'package:money_companion/domain/usecases/ingest_captured_message_usecase.dart';

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'memory-key';

  @override
  Future<String?> readStoredKey() async => 'memory-key';
}

void main() {
  late AppDatabase db;
  late IngestCapturedMessageUseCase ingestCapturedMessage;

  setUp(() async {
    db = await AppDatabase.open(
      executor: NativeDatabase.memory(),
      keyStore: _MemoryKeyStore(),
    );
    ingestCapturedMessage = IngestCapturedMessageUseCase(
      AddTransactionUseCase(
        transactionRepository: DriftTransactionRepository(db),
        merchantCategoryRepository: DriftMerchantCategoryRepository(db),
        suspectedDuplicateRepository: DriftSuspectedDuplicateRepository(db),
      ),
    );
  });

  tearDown(() async {
    await db.close();
  });

  test('confirmed merchant capture becomes a light notification path',
      () async {
    const rawMessage = 'عملية شراء\nبطاقة:مدى;****4521\nمبلغ:SAR 45.00\n'
        'لدى:NETFLIX\nفي:2026-04-08 12:45\nالرصيد:SAR 2,310.50';

    final result =
        await ingestCapturedMessage(rawMessage: rawMessage, senderId: 'SNB');

    expect(result.disposition, CapturedMessageDisposition.notifyOnly);
    expect(result.addTransactionResult.outcome, AddTransactionOutcome.added);
    expect(result.addTransactionResult.requiresConfirmation, isFalse);
  });

  // MALI-026 (B8-2.10 §12) — Path B (AddTransactionUseCase) honours the ingress
  // contract: canonical mode is wired and an EXACT parsed amount still confirms
  // (the resolver does not over-block exact captures). Numeric-only → pending is
  // proven at the service level in capture_sync_service_test §12.
  test('§12 canonical mode: exact parsed capture still confirms via Path B',
      () async {
    const rawMessage = 'عملية شراء\nبطاقة:مدى;****4521\nمبلغ:SAR 45.00\n'
        'لدى:NETFLIX\nفي:2026-04-08 12:45\nالرصيد:SAR 2,310.50';
    final canonicalIngest = IngestCapturedMessageUseCase(
      AddTransactionUseCase(
        transactionRepository: DriftTransactionRepository(db),
        merchantCategoryRepository: DriftMerchantCategoryRepository(db),
        suspectedDuplicateRepository: DriftSuspectedDuplicateRepository(db),
        coordinator: const FixedPlanningCutoverCoordinator(
            PlanningCutoverState.canonical),
      ),
    );

    final result =
        await canonicalIngest(rawMessage: rawMessage, senderId: 'SNB');
    expect(result.addTransactionResult.requiresConfirmation, isFalse);
  });

  test('CapturedMessage model follows the same ingest pipeline', () async {
    const rawMessage = 'عملية شراء\nبطاقة:مدى;****4521\nمبلغ:SAR 45.00\n'
        'لدى:NETFLIX\nفي:2026-04-08 12:45\nالرصيد:SAR 2,310.50';

    final result = await ingestCapturedMessage.fromCapturedMessage(
      CapturedMessage(
        text: rawMessage,
        senderId: 'SNB',
        source: CapturedMessageSource.androidShare,
        receivedAt: DateTime.utc(2026, 4, 8, 12, 45),
      ),
    );

    expect(result.disposition, CapturedMessageDisposition.notifyOnly);
    expect(result.addTransactionResult.requiresConfirmation, isFalse);
  });

  test('new merchant capture requests confirmation', () async {
    const rawMessage = 'عملية شراء\nمبلغ:SAR 82.00\n'
        'لدى:LOCAL ROASTER\nفي:2026-04-08 18:30';

    final result = await ingestCapturedMessage(rawMessage: rawMessage);

    expect(
      result.disposition,
      CapturedMessageDisposition.requestConfirmation,
    );
    expect(result.addTransactionResult.isNewMerchant, isTrue);
    expect(result.transactionId, isNotNull);
  });

  test('duplicate capture goes to Smart Inbox instead of silent ignore',
      () async {
    const rawMessage = 'عملية شراء\nبطاقة:مدى;****4521\nمبلغ:SAR 45.00\n'
        'لدى:BURGER BOUTIQUE\nفي:2026-04-08 12:45\nالرصيد:SAR 2,310.50';

    final first = await ingestCapturedMessage(rawMessage: rawMessage);
    final duplicate = await ingestCapturedMessage(rawMessage: rawMessage);

    expect(first.disposition, CapturedMessageDisposition.requestConfirmation);
    expect(
        duplicate.disposition, CapturedMessageDisposition.suspiciousDuplicate);
    expect(duplicate.addTransactionResult.outcome,
        AddTransactionOutcome.suspiciousDuplicate);
    expect(await db.count('suspected_duplicates'), 1);
  });

  test('non-transaction capture is ignored silently', () async {
    const rawMessage = 'رمز التحقق الخاص بك هو 123456 ولا تشاركه مع أحد';

    final result = await ingestCapturedMessage(rawMessage: rawMessage);

    expect(result.disposition, CapturedMessageDisposition.ignored);
    expect(
      result.addTransactionResult.outcome,
      AddTransactionOutcome.notTransaction,
    );
  });

  // ── MALI-068n §11 — received-time authority through the ingest pipeline ────
  group('captured occurredAt authority', () {
    Future<DateTime> savedOccurredAt() async {
      final txns = await DriftTransactionRepository(db).getAll();
      expect(txns, hasLength(1));
      return txns.first.occurredAt.toUtc();
    }

    test('an SMS-parsed date wins over receivedAt (never overwritten)',
        () async {
      const dated = 'عملية شراء\nمبلغ:SAR 45.00\nلدى:NETFLIX\n'
          'في:2026-04-08 12:45';
      final result = await ingestCapturedMessage.fromCapturedMessage(
        CapturedMessage(
          text: dated,
          source: CapturedMessageSource.androidShare,
          // A deliberately wrong receipt time must NOT become occurredAt.
          receivedAt: DateTime.utc(2000, 1, 1),
        ),
      );
      expect(result.addTransactionResult.outcome, AddTransactionOutcome.added);
      expect((await savedOccurredAt()).year, 2026);
    });

    test('a dateless SMS uses the real receivedAt (not now)', () async {
      const dateless = 'عملية شراء\nمبلغ:SAR 30.00\nلدى:STARBUCKS';
      final received = DateTime.utc(2026, 7, 1, 9);
      await ingestCapturedMessage.fromCapturedMessage(
        CapturedMessage(
          text: dateless,
          source: CapturedMessageSource.androidShare,
          receivedAt: received,
        ),
      );
      final occurredAt = await savedOccurredAt();
      expect(occurredAt.difference(received).inMinutes.abs() < 5, isTrue,
          reason: 'occurredAt should track the real receipt time');
    });

    test('a dateless SMS with unknown (null) receivedAt does not crash and '
        'falls back once (documented policy), never mid-pipeline', () async {
      const dateless = 'عملية شراء\nمبلغ:SAR 12.00\nلدى:COSTA';
      final before = DateTime.now().toUtc();
      final result = await ingestCapturedMessage.fromCapturedMessage(
        const CapturedMessage(
          text: dateless,
          source: CapturedMessageSource.androidShare,
          receivedAt: null, // corrupt/absent native timestamp
        ),
      );
      expect(result.addTransactionResult.outcome, AddTransactionOutcome.added);
      final occurredAt = await savedOccurredAt();
      // The single documented fallback is ~now; a valid time is never replaced.
      expect(occurredAt.isAfter(before.subtract(const Duration(minutes: 1))),
          isTrue);
    });
    // Idempotent payload-id replay (crash-after-commit-before-ack → no
    // duplicate) is covered end-to-end with the real dedup store in
    // capture_sync_service_test.dart ('failed ack followed by dedup prune must
    // not re-import the capture').
  });
}
