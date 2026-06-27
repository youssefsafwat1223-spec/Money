import '../../domain/entities/transaction_entity.dart';
import '../../engine/parser/direction_signal.dart';

/// Whether a transaction is money LEAVING the account (shown red, with a "−").
///
/// Income and refunds are money-in. A transfer is neutral money movement whose
/// direction is read from the message wording: an incoming transfer or cash/ATM
/// deposit ("إيداع / وارد / credited") is money-in (green, "+") but is NOT
/// counted as income — the totals exclude transfers entirely. An outgoing
/// transfer, payment, or withdrawal is money-out.
bool transactionIsDebit(TransactionEntity tx) {
  if (tx.direction == TransactionDirectionEntity.credit) return false;
  if (tx.direction == TransactionDirectionEntity.debit) return true;
  switch (tx.type) {
    case TransactionTypeEntity.income:
    case TransactionTypeEntity.refund:
      return false;
    case TransactionTypeEntity.transfer:
      return DirectionSignal.detect(tx.rawMessage) != TxnDirection.credit;
    case TransactionTypeEntity.payment:
    case TransactionTypeEntity.withdrawal:
    case TransactionTypeEntity.unknown:
      return true;
  }
}
