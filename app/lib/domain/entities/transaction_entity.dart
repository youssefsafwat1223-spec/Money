import '../finance/money.dart';

enum TransactionTypeEntity {
  payment,
  withdrawal,
  transfer,
  refund,
  income,
  unknown,
}

enum TransactionSourceEntity {
  bank,
  card,
  wallet,
  unknown,
  aiParsed,
  imported,
}

enum TransactionStatus { confirmed, pending, ignored }

enum TransactionDirectionEntity { credit, debit, unknown }

enum ComparisonTimestampSource { smsBody, receivedAt }

enum DuplicateStatus { normal, suspiciousDuplicate }

enum SyncStatus { localOnly, synced, pending, conflict }

class TransactionEntity {
  TransactionEntity({
    required this.id,
    required this.amountMoney,
    required this.currency,
    required this.type,
    required this.source,
    required this.occurredAt,
    required this.rawMessage,
    required this.parseConfidence,
    required this.status,
    required this.createdAt,
    required this.updatedAt,
    this.merchantId,
    this.rawMerchant,
    this.categoryId,
    this.cardLast4,
    this.balanceAfterMoney,
    this.note,
    this.accountId,
    this.foreignMoney,
    this.foreignCurrency,
    this.direction,
    this.transactionTimeFromSms,
    this.smsReceivedAt,
    this.comparisonTimestamp,
    this.comparisonTimestampSource = ComparisonTimestampSource.receivedAt,
    this.duplicateStatus = DuplicateStatus.normal,
    this.possibleDuplicateOfTransactionId,
    this.duplicateReason,
    this.serverId,
    this.syncedAt,
    this.serverUpdatedAt,
    this.syncStatus = SyncStatus.localOnly,
  })  : assert((foreignMoney == null) == (foreignCurrency == null)),
        assert(foreignMoney == null ||
            foreignMoney.currency == foreignCurrency!.trim().toUpperCase());

  final String id;
  final Money amountMoney;
  final String currency;
  final String? accountId;
  final String? merchantId;
  final String? rawMerchant;
  final String? categoryId;
  final TransactionTypeEntity type;
  final TransactionSourceEntity source;
  final String? cardLast4;
  final Money? balanceAfterMoney;
  final String? note;
  final DateTime occurredAt;
  final String rawMessage;
  final double parseConfidence;
  final TransactionStatus status;
  final DateTime createdAt;
  final DateTime updatedAt;
  final Money? foreignMoney;
  final String? foreignCurrency;
  final TransactionDirectionEntity? direction;
  final DateTime? transactionTimeFromSms;
  final DateTime? smsReceivedAt;
  final DateTime? comparisonTimestamp;
  final ComparisonTimestampSource comparisonTimestampSource;
  final DuplicateStatus duplicateStatus;
  final String? possibleDuplicateOfTransactionId;
  final String? duplicateReason;
  final String? serverId;
  final DateTime? syncedAt;
  final DateTime? serverUpdatedAt;
  final SyncStatus syncStatus;

  /// DISPLAY-ONLY compatibility getters. Never use these as a persistence,
  /// calculation, comparison, validation, dedup-input, or transport source.
  double get amount => amountMoney.toDouble();
  double? get balanceAfter => balanceAfterMoney?.toDouble();
  double? get foreignAmount => foreignMoney?.toDouble();

  TransactionEntity copyWith({
    String? id,
    Money? amountMoney,
    String? currency,
    String? accountId,
    String? merchantId,
    String? rawMerchant,
    String? categoryId,
    TransactionTypeEntity? type,
    TransactionSourceEntity? source,
    String? cardLast4,
    Money? balanceAfterMoney,
    String? note,
    DateTime? occurredAt,
    String? rawMessage,
    double? parseConfidence,
    TransactionStatus? status,
    DateTime? createdAt,
    DateTime? updatedAt,
    Money? foreignMoney,
    String? foreignCurrency,
    TransactionDirectionEntity? direction,
    DateTime? transactionTimeFromSms,
    DateTime? smsReceivedAt,
    DateTime? comparisonTimestamp,
    ComparisonTimestampSource? comparisonTimestampSource,
    DuplicateStatus? duplicateStatus,
    String? possibleDuplicateOfTransactionId,
    String? duplicateReason,
    String? serverId,
    DateTime? syncedAt,
    DateTime? serverUpdatedAt,
    SyncStatus? syncStatus,
  }) {
    return TransactionEntity(
      id: id ?? this.id,
      amountMoney: amountMoney ?? this.amountMoney,
      currency: currency ?? this.currency,
      accountId: accountId ?? this.accountId,
      merchantId: merchantId ?? this.merchantId,
      rawMerchant: rawMerchant ?? this.rawMerchant,
      categoryId: categoryId ?? this.categoryId,
      type: type ?? this.type,
      source: source ?? this.source,
      cardLast4: cardLast4 ?? this.cardLast4,
      balanceAfterMoney: balanceAfterMoney ?? this.balanceAfterMoney,
      note: note ?? this.note,
      occurredAt: occurredAt ?? this.occurredAt,
      rawMessage: rawMessage ?? this.rawMessage,
      parseConfidence: parseConfidence ?? this.parseConfidence,
      status: status ?? this.status,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      foreignMoney: foreignMoney ?? this.foreignMoney,
      foreignCurrency: foreignCurrency ?? this.foreignCurrency,
      direction: direction ?? this.direction,
      transactionTimeFromSms:
          transactionTimeFromSms ?? this.transactionTimeFromSms,
      smsReceivedAt: smsReceivedAt ?? this.smsReceivedAt,
      comparisonTimestamp: comparisonTimestamp ?? this.comparisonTimestamp,
      comparisonTimestampSource:
          comparisonTimestampSource ?? this.comparisonTimestampSource,
      duplicateStatus: duplicateStatus ?? this.duplicateStatus,
      possibleDuplicateOfTransactionId: possibleDuplicateOfTransactionId ??
          this.possibleDuplicateOfTransactionId,
      duplicateReason: duplicateReason ?? this.duplicateReason,
      serverId: serverId ?? this.serverId,
      syncedAt: syncedAt ?? this.syncedAt,
      serverUpdatedAt: serverUpdatedAt ?? this.serverUpdatedAt,
      syncStatus: syncStatus ?? this.syncStatus,
    );
  }
}

class MerchantEntity {
  const MerchantEntity({
    required this.id,
    required this.rawName,
    required this.normalizedName,
    required this.firstSeenAt,
    required this.lastSeenAt,
  });

  final String id;
  final String rawName;
  final String normalizedName;
  final DateTime firstSeenAt;
  final DateTime lastSeenAt;
}

class MerchantCategoryMappingEntity {
  const MerchantCategoryMappingEntity({
    required this.id,
    required this.merchantId,
    required this.categoryId,
    required this.isUserConfirmed,
    required this.confidence,
    required this.updatedAt,
  });

  final String id;
  final String merchantId;
  final String categoryId;
  final bool isUserConfirmed;
  final double confidence;
  final DateTime updatedAt;
}
