/// نوع العملية المستخرجة من الرسالة.
enum TransactionType {
  payment, // شراء / دفع
  withdrawal, // سحب نقدي
  transfer, // تحويل
  refund, // استرداد
  income, // دخل / راتب / إيداع
  unknown;

  bool get isExpense =>
      this == TransactionType.payment || this == TransactionType.withdrawal;
}
