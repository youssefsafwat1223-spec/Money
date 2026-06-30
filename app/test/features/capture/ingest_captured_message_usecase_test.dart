import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
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
}
