/// خريطة المتجر → التصنيف (تعلّم من تصحيح المستخدم).
///
/// نسخة في-الذاكرة للمحرك واختباراته. Codex يربطها بجدول
/// `merchant_category_map` في drift (مع `is_user_confirmed`).
class MerchantCategoryMap {
  MerchantCategoryMap([Map<String, String>? seed]) {
    if (seed != null) {
      seed.forEach((merchant, categoryKey) {
        _map[normalize(merchant)] = categoryKey;
      });
    }
  }

  final Map<String, String> _map = {};

  /// تطبيع اسم المتجر للمطابقة (حروف كبيرة، بلا أرقام/مسافات زائدة).
  static String normalize(String raw) {
    return raw
        .toUpperCase()
        .replaceAll(RegExp(r'[0-9]'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  /// يرجّع مفتاح التصنيف المحفوظ لمتجر، أو null.
  String? lookup(String rawMerchant) => _map[normalize(rawMerchant)];

  /// يحفظ/يحدّث تصنيف متجر (عند تأكيد المستخدم «طبّق على كل العمليات»).
  void learn(String rawMerchant, String categoryKey) {
    _map[normalize(rawMerchant)] = categoryKey;
  }

  int get size => _map.length;
}
