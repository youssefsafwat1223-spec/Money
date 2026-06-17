/// نوع العملية المستخرجة من الرسالة.
enum TransactionType {
  payment, // شراء / دفع
  withdrawal, // سحب نقدي
  transfer, // تحويل
  refund, // استرداد
  income, // دخل / راتب / إيداع
  creditCardPayment, // سداد بطاقة ائتمانية
  governmentPayment, // مدفوعات حكومية / سداد
  unknown;

  bool get isExpense =>
      this == TransactionType.payment ||
      this == TransactionType.withdrawal ||
      this == TransactionType.creditCardPayment ||
      this == TransactionType.governmentPayment;
}
