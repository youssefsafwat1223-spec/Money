import '../../core/utils/id_generator.dart';
import '../../engine/categorization/categorizer.dart';
import '../../engine/categorization/merchant_category_map.dart';
import '../../engine/models/transaction_source.dart';
import '../../engine/models/transaction_type.dart';
import '../../engine/parser/parser_engine.dart';
import '../../engine/parser/parse_result.dart';
import '../entities/engagement_entities.dart';
import '../entities/transaction_entity.dart';
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
    TransactionEntity transaction,
    ParseResult parseResult,
    {bool isNewMerchant = false}
  ) : this._(
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
    ParserEngine? parserEngine,
    RecordEngagementUseCase? recordEngagementUseCase,
  })  : _transactionRepository = transactionRepository,
        _merchantCategoryRepository = merchantCategoryRepository,
        _parserEngine = parserEngine ?? const ParserEngine(),
        _recordEngagementUseCase = recordEngagementUseCase;

  static const double autoConfirmThreshold = 0.8;

  final TransactionRepository _transactionRepository;
  final MerchantCategoryRepository _merchantCategoryRepository;
  final ParserEngine _parserEngine;
  final RecordEngagementUseCase? _recordEngagementUseCase;

  Future<AddTransactionResult> call({
    required String rawMessage,
    String? senderId,
  }) async {
    final parseResult = _parserEngine.parse(rawMessage, senderId: senderId);
    if (!parseResult.isTransaction || parseResult.transaction == null) {
      return AddTransactionResult.notTransaction(parseResult);
    }

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

    final transaction = TransactionEntity(
      id: IdGenerator.next(),
      amount: parsed.amount,
      currency: parsed.currency,
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
      status: parsed.parseConfidence >= autoConfirmThreshold
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
    return AddTransactionResult.added(
      saved,
      parseResult,
      isNewMerchant: isNewMerchant,
    );
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
