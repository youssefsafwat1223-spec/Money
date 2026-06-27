import '../models/transaction_type.dart';

/// Money-movement direction derived **independently** from explicit wording in
/// the message. It is used as a grounding cross-check against the classified
/// [TransactionType]: when the words say money came in but the type says it went
/// out (or vice-versa), the transaction must never auto-confirm.
enum TxnDirection {
  /// Money in (deposit, salary, incoming transfer, refund).
  credit,

  /// Money out (purchase, withdrawal, payment).
  debit,

  /// The text is not decisive on its own (both or neither family of words).
  unknown,
}

class DirectionSignal {
  const DirectionSignal._();

  // Words that clearly mean "money in". Intentionally avoids the bare tokens
  // "credit"/"debit" because they appear in "credit card" / "debit card".
  static const List<String> _creditWords = [
    'إيداع',
    'ايداع',
    'أُضيف',
    'أضيف',
    'اضيف',
    'إضافة',
    'اضافة',
    'تم إضافة',
    'تم اضافة',
    'تم استلام',
    'استلمت',
    'استلام',
    'مبلغ وارد',
    'حوالة واردة',
    'راتب',
    'deposit',
    'salary',
    'credited',
    'received',
    'incoming',
  ];

  // Words that clearly mean "money out".
  static const List<String> _debitWords = [
    'خصم',
    'خُصم',
    'تم الخصم',
    'شراء',
    'مشتريات',
    'دفع',
    'مدفوعات',
    'سحب',
    'مبلغ صادر',
    'صادر',
    'purchase',
    'payment',
    'paid',
    'debited',
    'withdrawn',
    'withdrawal',
    'deducted',
    'spent',
    'نقاط بيع',
  ];

  /// The direction strongly implied by the raw message text.
  /// Returns [TxnDirection.unknown] when both or neither family appears.
  static TxnDirection detect(String text) {
    final lower = text.toLowerCase();
    final hasCredit = _creditWords.any(lower.contains);
    final hasDebit = _debitWords.any(lower.contains);
    if (hasCredit && !hasDebit) return TxnDirection.credit;
    if (hasDebit && !hasCredit) return TxnDirection.debit;
    return TxnDirection.unknown;
  }

  /// The direction implied by a classified [TransactionType], or
  /// [TxnDirection.unknown] when the type is inherently ambiguous (transfer).
  static TxnDirection ofType(TransactionType type) {
    switch (type) {
      case TransactionType.income:
      case TransactionType.refund:
        return TxnDirection.credit;
      case TransactionType.payment:
      case TransactionType.withdrawal:
      case TransactionType.creditCardPayment:
      case TransactionType.governmentPayment:
        return TxnDirection.debit;
      case TransactionType.transfer:
      case TransactionType.unknown:
        return TxnDirection.unknown;
    }
  }

  /// True only when the text direction and the type direction are **both known
  /// and opposite**. A contradicting transaction must be routed to pending.
  static bool contradicts(String text, TransactionType type) {
    final textDir = detect(text);
    final typeDir = ofType(type);
    if (textDir == TxnDirection.unknown || typeDir == TxnDirection.unknown) {
      return false;
    }
    return textDir != typeDir;
  }
}
