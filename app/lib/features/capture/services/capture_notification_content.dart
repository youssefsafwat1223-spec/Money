import '../../../domain/entities/transaction_entity.dart';
import '../../../domain/finance/money.dart';
import '../../../domain/finance/money_format.dart';

/// محتوى إشعار الالتقاط — builder واحد مشترك بين مساري الإشعارات
/// (CapturedMessageProcessor في الخلفية و AppShell في الواجهة) حتى يظهر
/// نفس النص بكل التفاصيل في الحالتين.
///
/// الشكل: عنوان بنوع العملية، وجسم متعدد الأسطر بكل التفاصيل المتاحة
/// (المبلغ/التاجر/البطاقة/الوقت/التصنيف). الرصيد لا يظهر أبداً في
/// الإشعار — يظهر على شاشة القفل لأي شخص يرى الجهاز.
class CaptureNotificationContent {
  const CaptureNotificationContent({required this.title, required this.body});

  final String title;
  final String body;
}

/// إشعار عملية مؤكدة: "تم رصد عملية شراء 🛒" + قائمة التفاصيل.
CaptureNotificationContent buildConfirmedCaptureContent(
  TransactionEntity? tx, {
  DateTime? now,
}) {
  if (tx == null) {
    return const CaptureNotificationContent(
      title: 'تم التقاط العملية',
      body: 'أضفنا العملية إلى سجلك.',
    );
  }
  return CaptureNotificationContent(
    title: 'تم رصد ${_typeTitle(tx.type)} ${_typeEmoji(tx.type)}',
    body: _detailsBlock(tx, now: now),
  );
}

/// إشعار يطلب تأكيداً: "أكّد الخصم — 150.00 ر.س" + قائمة التفاصيل.
CaptureNotificationContent buildReviewCaptureContent(
  TransactionEntity? tx, {
  DateTime? now,
}) {
  if (tx == null) {
    return const CaptureNotificationContent(
      title: 'أكّد العملية',
      body: 'اضغط لمراجعة العملية وتأكيدها.',
    );
  }
  return CaptureNotificationContent(
    title: 'أكّد ${_typeLabelDefinite(tx.type)} — ${_amountLine(tx)}',
    body: '${_detailsBlock(tx, now: now)}\nاضغط للمراجعة والتأكيد.',
  );
}

/// إشعار عملية مشابهة (suspicious duplicate).
CaptureNotificationContent buildDuplicateCaptureContent(
  TransactionEntity? tx, {
  DateTime? now,
}) {
  if (tx == null) {
    return const CaptureNotificationContent(
      title: 'عملية مشابهة',
      body: 'افتح قرش وراجع الـ Smart Inbox.',
    );
  }
  return CaptureNotificationContent(
    title: 'عملية مشابهة ⚠️',
    body: '${_detailsBlock(tx, now: now)}\nموجودة مسبقاً؟ اضغط للمراجعة.',
  );
}

/// المبلغ + العملة، مع المبلغ الأجنبي بين قوسين إن وُجد.
String _amountLine(TransactionEntity tx) {
  final base = '${fmtCaptureMoney(tx.amountMoney)} ${tx.currency}';
  final foreign = tx.foreignMoney;
  if (foreign != null && tx.foreignCurrency != null) {
    return '$base (${fmtCaptureMoney(foreign)} ${tx.foreignCurrency})';
  }
  return base;
}

/// قائمة التفاصيل — سطر لكل معلومة متاحة.
String _detailsBlock(TransactionEntity tx, {DateTime? now}) {
  final lines = <String>['المبلغ: ${_amountLine(tx)}'];
  if (tx.rawMerchant != null && tx.rawMerchant!.trim().isNotEmpty) {
    final label = switch (tx.type) {
      TransactionTypeEntity.income ||
      TransactionTypeEntity.refund =>
        'المصدر: ${tx.rawMerchant}',
      _ => 'التاجر: ${tx.rawMerchant}',
    };
    lines.add(label);
  }
  if (tx.cardLast4 != null && tx.cardLast4!.isNotEmpty) {
    lines.add('البطاقة: ****${tx.cardLast4}');
  }
  lines.add('الوقت: ${captureTimeLabel(tx.occurredAt, now: now)}');
  final cat = captureCategoryLabel(tx.categoryId);
  if (cat != null) lines.add('التصنيف: $cat');
  return lines.join('\n');
}

String _typeTitle(TransactionTypeEntity type) {
  return switch (type) {
    TransactionTypeEntity.income => 'إيداع',
    TransactionTypeEntity.refund => 'استرداد',
    TransactionTypeEntity.transfer => 'تحويل',
    TransactionTypeEntity.withdrawal => 'سحب نقدي',
    TransactionTypeEntity.payment => 'عملية شراء',
    TransactionTypeEntity.unknown => 'عملية',
  };
}

String _typeEmoji(TransactionTypeEntity type) {
  return switch (type) {
    TransactionTypeEntity.income => '💰',
    TransactionTypeEntity.refund => '↩️',
    TransactionTypeEntity.transfer => '🔁',
    TransactionTypeEntity.withdrawal => '🏧',
    TransactionTypeEntity.payment => '🛒',
    TransactionTypeEntity.unknown => '💳',
  };
}

String _typeLabelDefinite(TransactionTypeEntity type) {
  return switch (type) {
    TransactionTypeEntity.income => 'الإيداع',
    TransactionTypeEntity.refund => 'الاسترداد',
    TransactionTypeEntity.transfer => 'التحويل',
    TransactionTypeEntity.withdrawal => 'السحب',
    TransactionTypeEntity.payment => 'الخصم',
    TransactionTypeEntity.unknown => 'العملية',
  };
}

String fmtCaptureAmount(double amount) {
  return amount == amount.truncateToDouble()
      ? amount.toInt().toString()
      : amount.toStringAsFixed(2);
}

/// R-8 — the same brevity rule, computed from exact minor units.
///
/// [fmtCaptureAmount] is hardcoded to two decimals, so a 3-decimal currency
/// (KWD 12.345) was ROUNDED in the notification — a different number, not a
/// different formatting of the same number. This reads the canonical scale
/// registry instead.
///
/// The approved brevity behaviour is preserved deliberately: a whole amount
/// still prints as `150`, not `150.00`. A lock-screen banner is glanced at, and
/// the exact figure is one tap away in the app. What changes is that the digits
/// it does show are now always right.
String fmtCaptureMoney(Money money) {
  final parts = splitMoneyForDisplay(money);
  final sign = parts.negative ? '-' : '';
  if (parts.fraction.isEmpty || int.tryParse(parts.fraction) == 0) {
    return '$sign${parts.integerPart}';
  }
  return '$sign${parts.integerPart}.${parts.fraction}';
}

/// "اليوم 9:41 م" / "أمس 9:41 م" / "2/7 9:41 م" — بتوقيت الجهاز.
String captureTimeLabel(DateTime occurredAt, {DateTime? now}) {
  final local = occurredAt.toLocal();
  final ref = (now ?? DateTime.now()).toLocal();
  final hour12 = local.hour % 12 == 0 ? 12 : local.hour % 12;
  final minute = local.minute.toString().padLeft(2, '0');
  final suffix = local.hour < 12 ? 'ص' : 'م';
  final time = '$hour12:$minute $suffix';
  final sameDay = local.year == ref.year &&
      local.month == ref.month &&
      local.day == ref.day;
  if (sameDay) return 'اليوم $time';
  final yesterday = ref.subtract(const Duration(days: 1));
  final isYesterday = local.year == yesterday.year &&
      local.month == yesterday.month &&
      local.day == yesterday.day;
  if (isYesterday) return 'أمس $time';
  return '${local.day}/${local.month} $time';
}

/// تسمية عربية للتصنيف بمفتاحه الثابت.
String? captureCategoryLabel(String? key) {
  return switch (key) {
    'restaurants' => 'مطاعم 🍔',
    'cafes' => 'مقاهي ☕',
    'groceries' => 'بقالة 🛒',
    'transport' => 'مواصلات 🚗',
    'fuel' => 'وقود ⛽',
    'bills' => 'فواتير 📱',
    'shopping' => 'تسوق 🛍',
    'health' => 'صحة 🏥',
    'education' => 'تعليم 📚',
    'entertainment' => 'ترفيه 🎬',
    'subscriptions' => 'اشتراكات 📲',
    'transfers' => 'تحويل 💸',
    'cash' => 'كاش 💵',
    'travel' => 'سفر ✈️',
    'gifts' => 'هدايا 🎁',
    'kids' => 'أطفال 👶',
    'home' => 'منزل 🏠',
    'maintenance' => 'صيانة 🔧',
    'fitness' => 'رياضة 💪',
    'beauty' => 'جمال 💅',
    'charity' => 'خيرية 🤲',
    'pets' => 'حيوانات 🐾',
    'insurance' => 'تأمين 🛡️',
    'income' => 'دخل 💰',
    _ => null,
  };
}
