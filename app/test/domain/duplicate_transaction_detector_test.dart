import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/repositories/drift_merchant_category_repository.dart';
import 'package:money_companion/data/repositories/drift_suspected_duplicate_repository.dart';
import 'package:money_companion/data/repositories/drift_transaction_repository.dart';
import 'package:money_companion/domain/entities/captured_message.dart';
import 'package:money_companion/domain/entities/transaction_entity.dart';
import 'package:money_companion/domain/services/duplicate_transaction_detector.dart';
import 'package:money_companion/domain/usecases/add_transaction_usecase.dart';
import 'package:money_companion/domain/usecases/ingest_captured_message_usecase.dart';
import 'package:money_companion/engine/parser/transaction_timestamp_extractor.dart';

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'memory-key';

  @override
  Future<String?> readStoredKey() async => 'memory-key';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const detector = DuplicateTransactionDetector();
  final baseTime = DateTime.utc(2026, 4, 8, 12, 45);

  TransactionEntity tx({
    double amount = 45,
    String currency = 'SAR',
    String merchant = 'NETFLIX',
    String? last4 = '4521',
    DateTime? timestamp,
  }) {
    final time = timestamp ?? baseTime;
    return TransactionEntity(
      id: 'existing-${time.microsecondsSinceEpoch}',
      amount: amount,
      currency: currency,
      rawMerchant: merchant,
      type: TransactionTypeEntity.payment,
      source: TransactionSourceEntity.card,
      cardLast4: last4,
      occurredAt: time,
      rawMessage: 'raw $merchant',
      parseConfidence: 0.95,
      status: TransactionStatus.confirmed,
      createdAt: time,
      updatedAt: time,
      comparisonTimestamp: time,
      comparisonTimestampSource: ComparisonTimestampSource.smsBody,
    );
  }

  DuplicateTransactionInput input({
    double amount = 45,
    String currency = 'SAR',
    String merchant = 'NETFLIX',
    String? last4 = '4521',
    DateTime? timestamp,
    ComparisonTimestampSource source = ComparisonTimestampSource.smsBody,
  }) {
    return DuplicateTransactionInput(
      amount: amount,
      currency: currency,
      merchantOrDescription: merchant,
      cardLast4: last4,
      comparisonTimestamp: timestamp ?? baseTime,
      comparisonTimestampSource: source,
    );
  }

  test('1. Same SMS text with same transaction timestamp is suspicious', () {
    final result = detector.detect(
      input: input(),
      existingTransactions: [tx()],
    );

    expect(result.status, DuplicateStatus.suspiciousDuplicate);
  });

  test('2. Same amount merchant currency but different SMS timestamp is normal',
      () {
    final result = detector.detect(
      input: input(timestamp: baseTime.add(const Duration(minutes: 1))),
      existingTransactions: [tx()],
    );

    expect(result.status, DuplicateStatus.normal);
  });

  test('3. No SMS timestamp with same received_at is suspicious', () {
    final receivedAt = DateTime.utc(2026, 6, 30, 3, 1, 27);
    final result = detector.detect(
      input: input(
        timestamp: receivedAt,
        source: ComparisonTimestampSource.receivedAt,
      ),
      existingTransactions: [tx(timestamp: receivedAt)],
    );

    expect(result.status, DuplicateStatus.suspiciousDuplicate);
  });

  test('4. No SMS timestamp with different received_at is normal', () {
    final receivedAt = DateTime.utc(2026, 6, 30, 3, 1, 27);
    final result = detector.detect(
      input: input(
        timestamp: receivedAt.add(const Duration(seconds: 1)),
        source: ComparisonTimestampSource.receivedAt,
      ),
      existingTransactions: [tx(timestamp: receivedAt)],
    );

    expect(result.status, DuplicateStatus.normal);
  });

  test('5. Same amount but different merchant is normal', () {
    final result = detector.detect(
      input: input(merchant: 'STARBUCKS'),
      existingTransactions: [tx(merchant: 'NETFLIX')],
    );

    expect(result.status, DuplicateStatus.normal);
  });

  test('6. Same merchant but different amount is normal', () {
    final result = detector.detect(
      input: input(amount: 46),
      existingTransactions: [tx(amount: 45)],
    );

    expect(result.status, DuplicateStatus.normal);
  });

  test('7. Same amount merchant time but different currency is normal', () {
    final result = detector.detect(
      input: input(currency: 'AED'),
      existingTransactions: [tx(currency: 'SAR')],
    );

    expect(result.status, DuplicateStatus.normal);
  });

  test('8. Same amount merchant time with missing last4 is suspicious', () {
    final result = detector.detect(
      input: input(last4: null),
      existingTransactions: [tx(last4: '4521')],
    );

    expect(result.status, DuplicateStatus.suspiciousDuplicate);
  });

  test('9. Arabic SMS timestamp inside body is extracted and matched', () {
    final time = TransactionTimestampExtractor.extract(
      'تمت عملية شراء بمبلغ SAR 45 لدى NETFLIX بتاريخ ٢٠٢٦-٠٤-٠٨ الساعة ١٢:٤٥',
    );

    expect(time, DateTime(2026, 4, 8, 12, 45));
    final result = detector.detect(
      input: input(timestamp: time),
      existingTransactions: [tx(timestamp: time)],
    );
    expect(result.status, DuplicateStatus.suspiciousDuplicate);
  });

  test('10. English SMS timestamp inside body is extracted and matched', () {
    final time = TransactionTimestampExtractor.extract(
      'Purchase SAR 45 at NETFLIX on 2026-04-08 12:45',
    );

    expect(time, DateTime(2026, 4, 8, 12, 45));
    final result = detector.detect(
      input: input(timestamp: time),
      existingTransactions: [tx(timestamp: time)],
    );
    expect(result.status, DuplicateStatus.suspiciousDuplicate);
  });

  test('11. iOS Shortcut payload without timestamp uses received_at', () async {
    final db = await AppDatabase.open(
      executor: NativeDatabase.memory(),
      keyStore: _MemoryKeyStore(),
    );
    addTearDown(db.close);
    final repo = DriftTransactionRepository(db);
    final ingest = IngestCapturedMessageUseCase(
      AddTransactionUseCase(
        transactionRepository: repo,
        merchantCategoryRepository: DriftMerchantCategoryRepository(db),
        suspectedDuplicateRepository: DriftSuspectedDuplicateRepository(db),
      ),
    );
    final receivedAt = DateTime.utc(2026, 6, 30, 3, 1, 27);
    const sms = 'عملية شراء\nبطاقة:مدى;****4521\nمبلغ:SAR 45.00\n'
        'لدى:NETFLIX\nالرصيد:SAR 2,310.50';

    final result = await ingest.fromCapturedMessage(
      CapturedMessage(
        text: sms,
        source: CapturedMessageSource.iosShortcut,
        receivedAt: receivedAt,
      ),
    );
    final saved = await repo.getById(result.transactionId!);

    expect(result.addTransactionResult.outcome, AddTransactionOutcome.added);
    expect(saved!.smsReceivedAt, receivedAt);
    expect(saved.comparisonTimestamp, receivedAt);
    expect(
      saved.comparisonTimestampSource,
      ComparisonTimestampSource.receivedAt,
    );
  });

  test('12. No suspicious duplicate transaction is silently ignored', () async {
    final db = await AppDatabase.open(
      executor: NativeDatabase.memory(),
      keyStore: _MemoryKeyStore(),
    );
    addTearDown(db.close);
    final repo = DriftTransactionRepository(db);
    final ingest = IngestCapturedMessageUseCase(
      AddTransactionUseCase(
        transactionRepository: repo,
        merchantCategoryRepository: DriftMerchantCategoryRepository(db),
        suspectedDuplicateRepository: DriftSuspectedDuplicateRepository(db),
      ),
    );
    final receivedAt = DateTime.utc(2026, 6, 30, 3, 1, 27);
    const sms = 'عملية شراء\nبطاقة:مدى;****4521\nمبلغ:SAR 45.00\n'
        'لدى:NETFLIX\nالرصيد:SAR 2,310.50';

    await ingest.fromCapturedMessage(
      CapturedMessage(
        text: sms,
        source: CapturedMessageSource.iosShortcut,
        receivedAt: receivedAt,
      ),
    );
    final duplicate = await ingest.fromCapturedMessage(
      CapturedMessage(
        text: sms,
        source: CapturedMessageSource.iosShortcut,
        receivedAt: receivedAt,
      ),
    );

    expect(
        duplicate.disposition, CapturedMessageDisposition.suspiciousDuplicate);
    expect(duplicate.addTransactionResult.outcome,
        AddTransactionOutcome.suspiciousDuplicate);
    expect(await db.count('transactions'), 1);
    expect(await db.count('suspected_duplicates'), 1);
  });
}
