import 'category.dart';

/// بذور التصنيف السعودية (SAUDI_MARKET_SPEC §6).
///
/// [merchantSeeds]: تطابق اسم متجر معروف → مفتاح تصنيف (يُستخدم كبذور أولية
/// لـ merchant_category_map).
/// [keywordRules]: كلمات مفتاحية تظهر داخل اسم المتجر → تصنيف.
class CategorySeeds {
  CategorySeeds._();

  /// أسماء متاجر شائعة (تطابق بالاحتواء، حروف كبيرة).
  static final Map<String, String> keywordRules = {
    // تسوق
    'JARIR': Categories.shopping.key,
    'EXTRA': Categories.shopping.key,
    'AMAZON': Categories.shopping.key,
    'NOON': Categories.shopping.key,
    // بقالة
    'PANDA': Categories.groceries.key,
    'بنده': Categories.groceries.key,
    'DANUBE': Categories.groceries.key,
    'TAMIMI': Categories.groceries.key,
    'LULU': Categories.groceries.key,
    'CARREFOUR': Categories.groceries.key,
    'OTHAIM': Categories.groceries.key,
    'العثيم': Categories.groceries.key,
    // مطاعم
    'MCDONALD': Categories.restaurants.key,
    'HERFY': Categories.restaurants.key,
    'KUDU': Categories.restaurants.key,
    'ALBAIK': Categories.restaurants.key,
    'البيك': Categories.restaurants.key,
    'BURGER': Categories.restaurants.key,
    'SHAWARMA': Categories.restaurants.key,
    // كافيهات
    'STARBUCKS': Categories.cafes.key,
    'BARNS': Categories.cafes.key,
    'بارنز': Categories.cafes.key,
    'DUNKIN': Categories.cafes.key,
    'ARABICA': Categories.cafes.key,
    'DOSE': Categories.cafes.key,
    // مواصلات
    'UBER': Categories.transport.key,
    'CAREEM': Categories.transport.key,
    'كريم': Categories.transport.key,
    'JEENY': Categories.transport.key,
    // وقود
    'ARAMCO': Categories.fuel.key,
    'PETROMIN': Categories.fuel.key,
    'SASCO': Categories.fuel.key,
    'ساسكو': Categories.fuel.key,
    // فواتير
    'STC': Categories.bills.key,
    'MOBILY': Categories.bills.key,
    'ZAIN': Categories.bills.key,
    // اشتراكات
    'NETFLIX': Categories.subscriptions.key,
    'SHAHID': Categories.subscriptions.key,
    'شاهد': Categories.subscriptions.key,
    'SPOTIFY': Categories.subscriptions.key,
    'ICLOUD': Categories.subscriptions.key,
    'OSN': Categories.subscriptions.key,
    // صحة
    'NAHDI': Categories.health.key,
    'النهدي': Categories.health.key,
    'ALDAWAA': Categories.health.key,
    'الدواء': Categories.health.key,
    'صيدلية': Categories.health.key,
  };
}
