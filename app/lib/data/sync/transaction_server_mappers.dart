import '../../domain/entities/transaction_entity.dart';

// MALI-034: authority-neutral serialization of local transaction enums to the
// Supabase wire vocabulary. Extracted verbatim from the retired
// SupabaseTransactionRepository so the ledger outbox and transactions backfill
// (explicit sync TRANSPORT) no longer depend on a legacy Supabase repository
// authority. Behaviour is unchanged.

String transactionSourceToServer(TransactionSourceEntity source) {
  switch (source) {
    case TransactionSourceEntity.bank:
      // Old Drift rows do not distinguish iOS from Android. Marking them as
      // import is honest provenance; new backend captures keep ios_shortcut.
      return 'import';
    case TransactionSourceEntity.card:
      return 'import';
    case TransactionSourceEntity.wallet:
      return 'manual';
    case TransactionSourceEntity.aiParsed:
      return 'share_extension';
    case TransactionSourceEntity.unknown:
      return 'manual';
    case TransactionSourceEntity.imported:
      return 'import';
  }
}

String transactionDirectionToServer(TransactionDirectionEntity? direction) {
  switch (direction) {
    case TransactionDirectionEntity.debit:
      return 'debit';
    case TransactionDirectionEntity.credit:
      return 'credit';
    default:
      return 'unknown';
  }
}

String transactionTypeToServer(
  TransactionTypeEntity type,
  TransactionDirectionEntity? direction,
) {
  switch (type) {
    case TransactionTypeEntity.transfer:
      return 'transfer';
    case TransactionTypeEntity.refund:
      return 'refund';
    case TransactionTypeEntity.income:
      return 'income';
    case TransactionTypeEntity.payment:
    case TransactionTypeEntity.withdrawal:
      return 'expense';
    case TransactionTypeEntity.unknown:
      return direction == TransactionDirectionEntity.credit
          ? 'income'
          : direction == TransactionDirectionEntity.debit
              ? 'expense'
              : 'unknown';
  }
}
