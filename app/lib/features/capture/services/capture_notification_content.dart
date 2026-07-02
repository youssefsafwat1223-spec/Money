import '../../../domain/entities/transaction_entity.dart';

/// محتوى إشعار الالتقاط — builder واحد مشترك بين مساري الإشعارات
/// (CapturedMessageProcessor في الخلفية و AppShell في الواجهة) حتى يظهر
/// نفس النص بكل التفاصيل في الحالتين.
class CaptureNotificationContent {
  const CaptureNotificationContent({required this.title, required this.body});

  final String title;
  final String body;
}

/// إشعار عملية مؤكدة (captureLight): "إيداع ✓ 150 ر.س".
CaptureNotificationContent buildConfirmedCaptureContent(
  TransactionEntity? tx,
) {
  if (tx == null) {
    return const CaptureNotificationContent(
      title: 'تم التقاط العملية',
      body: 'أضفنا العملية إلى سجلك.',
    );
  }
  return CaptureNotificationContent(
    title: '${_typeLabel(tx.type)} ✓ ${_amountLine(tx)}',
    body: _detailsLine(tx),
  );
}

/// إشعار يطلب تأكيداً (captureReview): "أكّد الخصم — 150 ر.س".
CaptureNotificationContent buildReviewCaptureContent(
  TransactionEntity? tx,
) {
  if (tx == null) {
    return const CaptureNotificationContent(
      title: 'أكّد العملية',
      body: 'اضغط لمراجعة العملية وتأكيدها.',
    );
  }
  return CaptureNotificationContent(
    title: 'أكّد ${_typeLabelDefinite(tx.type)} — ${_amountLine(tx)}',
    body: _detailsLine(tx),
  );
}

/// إشعار عملية مشابهة (suspicious duplicate).
CaptureNotificationContent buildDuplicateCaptureContent(
  TransactionEntity? tx,
) {
  if (tx == null) {
    return const CaptureNotificationContent(
      title: 'عملية مشابهة',
      body: 'افتح قرش وراجع الـ Smart Inbox.',
    );
  }
  final merchant = tx.rawMerchant != null ? ' لدى ${tx.rawMerchant}' : '';
  return CaptureNotificationContent(
    title: 'عملية مشابهة',
    body: '${_amountLine(tx)}$merchant — موجودة مسبقاً؟ اضغط للمراجعة.',
  );
}

/// المبلغ + العملة، مع المبلغ الأجنبي بين قوسين إن وُجد.
String _amountLine(TransactionEntity tx) {
  final base = '${fmtCaptureAmount(tx.amount)} ${tx.currency}';
  if (tx.foreignAmount != null && tx.foreignCurrency != null) {
    return '$base (${fmtCaptureAmount(tx.foreignAmount!)} ${tx.foreignCurrency})';
  }
  return base;
}

/// سطر التفاصيل: التاجر · التصنيف · بطاقة •1234 · رصيدك 3,450 ر.س
String _detailsLine(TransactionEntity tx) {
  final parts = <String>[];
  if (tx.rawMerchant != null && tx.rawMerchant!.trim().isNotEmpty) {
    final label = switch (tx.type) {
      TransactionTypeEntity.income ||
      TransactionTypeEntity.refund =>
        'من ${tx.rawMerchant}',
      _ => 'لدى ${tx.rawMerchant}',
    };
    parts.add(label);
  }
  final cat = captureCategoryLabel(tx.categoryId);
  if (cat != null) parts.add(cat);
  if (tx.cardLast4 != null && tx.cardLast4!.isNotEmpty) {
    parts.add('بطاقة •${tx.cardLast4}');
  }
  if (tx.balanceAfter != null) {
    parts.add('رصيدك ${fmtCaptureAmount(tx.balanceAfter!)} ${tx.currency}');
  }
  if (parts.isEmpty) {
    return tx.type == TransactionTypeEntity.income
        ? 'في حسابك.'
        : 'من حسابك.';
  }
  return parts.join(' · ');
}

String _typeLabel(TransactionTypeEntity type) {
  return switch (type) {
    TransactionTypeEntity.income => 'إيداع',
    TransactionTypeEntity.refund => 'استرداد',
    TransactionTypeEntity.transfer => 'تحويل',
    TransactionTypeEntity.withdrawal => 'سحب نقدي',
    TransactionTypeEntity.payment => 'خصم',
    TransactionTypeEntity.unknown => 'عملية',
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
