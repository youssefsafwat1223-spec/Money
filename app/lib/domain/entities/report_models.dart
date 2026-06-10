/// مجموع إنفاق متجر خلال فترة (لأكثر المتاجر صرفاً).
class MerchantSpend {
  const MerchantSpend({required this.name, required this.total});

  final String name;
  final double total;
}

/// اشتراك متكرر مُكتشَف (نفس المتجر بمبلغ متقارب عبر أشهر).
class RecurringCandidate {
  const RecurringCandidate({
    required this.merchantId,
    required this.name,
    required this.averageAmount,
    required this.monthsSeen,
  });

  final String merchantId;
  final String name;
  final double averageAmount;
  final int monthsSeen;
}

/// إجمالي الصرف في يوم واحد، يستخدم لرسم Insights اليومي.
class DailySpend {
  const DailySpend({required this.day, required this.total});

  final DateTime day;
  final double total;
}
