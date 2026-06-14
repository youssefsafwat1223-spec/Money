import '../../core/utils/id_generator.dart';
import '../../engine/categorization/categorizer.dart';
import '../../engine/categorization/merchant_category_map.dart';
import '../../engine/models/transaction_source.dart';
import '../../engine/models/transaction_type.dart';
import '../../engine/parser/bank_profile.dart';
import '../../engine/parser/parser_isolate.dart';
import '../../engine/parser/parse_result.dart';
import '../entities/engagement_entities.dart';
import '../entities/transaction_entity.dart';
import '../repositories/account_repository.dart';
import '../repositories/merchant_category_repository.dart';
import '../repositories/transaction_repository.dart';
import 'engagement_usecase.dart';

class AddTransactionResult {
  const AddTransactionResult._({
    required this.outcome,
    this.transaction,
    this.parseResult,
    this.isNewMerchant = false,
  });

  const AddTransactionResult.added(
      TransactionEntity transaction, ParseResult parseResult,
      {bool isNewMerchant = false})
      : this._(
          outcome: AddTransactionOutcome.added,
          transaction: transaction,
          parseResult: parseResult,
          isNewMerchant: isNewMerchant,
        );

  const AddTransactionResult.duplicate(TransactionEntity transaction)
      : this._(
          outcome: AddTransactionOutcome.duplicate,
          transaction: transaction,
        );

  const AddTransactionResult.notTransaction(ParseResult parseResult)
      : this._(
          outcome: AddTransactionOutcome.notTransaction,
          parseResult: parseResult,
        );

  final AddTransactionOutcome outcome;
  final TransactionEntity? transaction;
  final ParseResult? parseResult;
  final bool isNewMerchant;

  bool get requiresConfirmation {
    if (outcome != AddTransactionOutcome.added || transaction == null) {
      return false;
    }
    return transaction!.status == TransactionStatus.pending || isNewMerchant;
  }
}

enum AddTransactionOutcome { added, duplicate, notTransaction }

class AddTransactionUseCase {
  AddTransactionUseCase({
    required TransactionRepository transactionRepository,
    required MerchantCategoryRepository merchantCategoryRepository,
    ParserIsolate? parserIsolate,
    RecordEngagementUseCase? recordEngagementUseCase,
    Future<void> Function(String key, {String? dimension})? logMetric,
    Future<List<BankProfile>> Function({String? senderId})? loadBankProfiles,
    AccountRepository? accountRepository,
  })  : _transactionRepository = transactionRepository,
        _merchantCategoryRepository = merchantCategoryRepository,
        _parserIsolate = parserIsolate ?? const ParserIsolate(),
        _recordEngagementUseCase = recordEngagementUseCase,
        _logMetric = logMetric,
        _loadBankProfiles = loadBankProfiles,
        _accountRepository = accountRepository;

  static const double autoConfirmThreshold = 0.92;
  static const double categoryAutoConfirmThreshold = 0.80;

  final TransactionRepository _transactionRepository;
  final MerchantCategoryRepository _merchantCategoryRepository;
  final ParserIsolate _parserIsolate;
  final RecordEngagementUseCase? _recordEngagementUseCase;
  final Future<void> Function(String key, {String? dimension})? _logMetric;
  final Future<List<BankProfile>> Function({String? senderId})?
      _loadBankProfiles;
  final AccountRepository? _accountRepository;

  Future<AddTransactionResult> call({
    required String rawMessage,
    String? senderId,
  }) async {
    final bankProfiles = await _safeLoadBankProfiles(senderId: senderId);
    final defaultAccount = await _accountRepository?.getDefault();
    final parseResult = await _parserIsolate.parse(
          rawMessage,
          senderId: senderId,
          bankProfiles: bankProfiles,
          defaultCurrency: defaultAccount?.currency ?? 'SAR',
        ) ??
        ParseResult.notTransaction();
    if (!parseResult.isTransaction || parseResult.transaction == null) {
      return AddTransactionResult.notTransaction(parseResult);
    }
    await _logMetric?.call('parse_success', dimension: parseResult.bankKey);

    final parsed = parseResult.transaction!;
    final occurredAt = parsed.occurredAt ?? DateTime.now().toUtc();
    final merchant = parsed.rawMerchant;
    final now = DateTime.now().toUtc();
    final isNewMerchant = merchant == null
        ? false
        : !await _merchantCategoryRepository.hasCategoryForMerchant(merchant);

    if (merchant != null) {
      final duplicate = await _transactionRepository.findDuplicate(
        amount: parsed.amount,
        rawMerchant: merchant,
        occurredAt: occurredAt,
      );
      if (duplicate != null) {
        return AddTransactionResult.duplicate(duplicate);
      }
    }

    final learnedMap =
        await _merchantCategoryRepository.getLearnedCategoryMap();
    final categorizer = Categorizer(map: MerchantCategoryMap(learnedMap));
    final categoryResult = categorizer.categorize(parsed);
    final canAutoConfirm = parsed.parseConfidence >= autoConfirmThreshold &&
        categoryResult.confidence >= categoryAutoConfirmThreshold &&
        !isNewMerchant;

    final transaction = TransactionEntity(
      id: IdGenerator.next(),
      amount: parsed.amount,
      currency: parsed.currency,
      accountId: defaultAccount?.id,
      merchantId: null,
      rawMerchant: parsed.rawMerchant,
      categoryId: null,
      type: _mapType(parsed.type),
      source: _mapSource(parsed.source),
      cardLast4: parsed.cardLast4,
      balanceAfter: parsed.balanceAfter,
      occurredAt: occurredAt.toUtc(),
      rawMessage: rawMessage,
      parseConfidence: parsed.parseConfidence,
      status: canAutoConfirm
          ? TransactionStatus.confirmed
          : TransactionStatus.pending,
      createdAt: now,
      updatedAt: now,
    );

    final saved = await _transactionRepository.saveTransaction(
      transaction: transaction,
      categoryKey: categoryResult.categoryKey,
    );
    if (_recordEngagementUseCase != null) {
      await _recordEngagementUseCase(
        action: saved.status == TransactionStatus.confirmed
            ? EngagementAction.transactionConfirmed
            : EngagementAction.transactionAdded,
        occurredAt: saved.occurredAt,
      );
    }
    await _logMetric?.call('first_transaction_captured');
    return AddTransactionResult.added(
      saved,
      parseResult,
      isNewMerchant: isNewMerchant,
    );
  }

  Future<List<BankProfile>> _safeLoadBankProfiles({String? senderId}) async {
    final loader = _loadBankProfiles;
    if (loader == null) return const [];
    try {
      return await loader(senderId: senderId);
    } catch (_) {
      return const [];
    }
  }

  static TransactionSourceEntity _mapSource(TransactionSource source) {
    switch (source) {
      case TransactionSource.bank:
        return TransactionSourceEntity.bank;
      case TransactionSource.card:
        return TransactionSourceEntity.card;
      case TransactionSource.wallet:
        return TransactionSourceEntity.wallet;
      case TransactionSource.unknown:
        return TransactionSourceEntity.unknown;
    }
  }

  static TransactionTypeEntity _mapType(TransactionType type) {
    switch (type) {
      case TransactionType.payment:
        return TransactionTypeEntity.payment;
      case TransactionType.withdrawal:
        return TransactionTypeEntity.withdrawal;
      case TransactionType.transfer:
        return TransactionTypeEntity.transfer;
      case TransactionType.refund:
        return TransactionTypeEntity.refund;
      case TransactionType.income:
        return TransactionTypeEntity.income;
      case TransactionType.unknown:
        return TransactionTypeEntity.unknown;
    }
  }
}

class SaveManualTransactionUseCase {
  SaveManualTransactionUseCase({
    required TransactionRepository transactionRepository,
    RecordEngagementUseCase? recordEngagementUseCase,
    Future<void> Function(String key, {String? dimension})? logMetric,
  })  : _transactionRepository = transactionRepository,
        _recordEngagementUseCase = recordEngagementUseCase,
        _logMetric = logMetric;

  final TransactionRepository _transactionRepository;
  final RecordEngagementUseCase? _recordEngagementUseCase;
  final Future<void> Function(String key, {String? dimension})? _logMetric;

  Future<TransactionEntity> call({
    required double amount,
    required String currency,
    required TransactionTypeEntity type,
    required DateTime occurredAt,
    required String categoryKey,
    String? merchant,
    String? note,
    String? accountId,
  }) async {
    final now = DateTime.now().toUtc();
    final normalizedMerchant = merchant?.trim();
    final normalizedNote = note?.trim();
    final transaction = TransactionEntity(
      id: IdGenerator.next(),
      amount: amount,
      currency: currency.toUpperCase(),
      accountId: accountId,
      merchantId: null,
      rawMerchant: normalizedMerchant == null || normalizedMerchant.isEmpty
          ? null
          : normalizedMerchant,
      categoryId: null,
      type: type,
      source: TransactionSourceEntity.unknown,
      cardLast4: null,
      balanceAfter: null,
      note: normalizedNote == null || normalizedNote.isEmpty
          ? null
          : normalizedNote,
      occurredAt: occurredAt.toUtc(),
      rawMessage: normalizedNote == null || normalizedNote.isEmpty
          ? 'Manual transaction'
          : normalizedNote,
      parseConfidence: 1,
      status: TransactionStatus.confirmed,
      createdAt: now,
      updatedAt: now,
    );

    final saved = await _transactionRepository.saveTransaction(
      transaction: transaction,
      categoryKey: categoryKey,
    );
    if (_recordEngagementUseCase != null) {
      await _recordEngagementUseCase(
        action: EngagementAction.transactionConfirmed,
        occurredAt: saved.occurredAt,
      );
    }
    await _logMetric?.call('manual_transaction_added');
    return saved;
  }
}
