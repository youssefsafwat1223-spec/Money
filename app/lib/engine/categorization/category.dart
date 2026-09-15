/// التصنيفات الـ20 الأساسية (PRODUCT_SPEC §6). `key` ثابت يُخزَّن في DB،
/// و`arName` للعرض.
class Category {
  const Category(this.key, this.arName, this.enName);

  final String key;
  final String arName;

  /// The English display name. The local `categories` table stores only
  /// `name_ar` (`name_en` exists solely in `remote_categories`), so before this
  /// the app rendered Arabic category names in BOTH locales. Keys are stable, so
  /// the English name belongs here beside the Arabic one rather than in a
  /// migration on a financial database.
  final String enName;

  @override
  String toString() => '$key ($arName)';
}

class Categories {
  Categories._();

  static const restaurants = Category('restaurants', 'مطاعم', 'Restaurants');
  static const groceries = Category('groceries', 'بقالة', 'Groceries');
  static const transport = Category('transport', 'مواصلات', 'Transport');
  static const fuel = Category('fuel', 'وقود', 'Fuel');
  static const bills = Category('bills', 'فواتير', 'Bills');
  static const shopping = Category('shopping', 'تسوق', 'Shopping');
  static const health = Category('health', 'صحة', 'Health');
  static const education = Category('education', 'تعليم', 'Education');
  static const entertainment = Category('entertainment', 'ترفيه', 'Entertainment');
  static const subscriptions = Category('subscriptions', 'اشتراكات', 'Subscriptions');
  static const transfers = Category('transfers', 'تحويلات', 'Transfers');
  static const cash = Category('cash', 'سحب نقدي', 'Cash withdrawal');
  static const travel = Category('travel', 'سفر', 'Travel');
  static const gifts = Category('gifts', 'هدايا', 'Gifts');
  static const kids = Category('kids', 'أطفال', 'Kids');
  static const home = Category('home', 'منزل', 'Home');
  static const cafes = Category('cafes', 'كافيهات', 'Cafés');
  static const maintenance = Category('maintenance', 'صيانة', 'Maintenance');
  static const smoking = Category('smoking', 'تدخين', 'Smoking');
  static const fitness = Category('fitness', 'لياقة ورياضة', 'Fitness');
  static const beauty = Category('beauty', 'عناية شخصية', 'Personal care');
  static const charity = Category('charity', 'تبرعات', 'Charity');
  static const pets = Category('pets', 'حيوانات أليفة', 'Pets');
  static const insurance = Category('insurance', 'تأمين', 'Insurance');
  static const income = Category('income', 'دخل', 'Income');
  static const other = Category('other', 'أخرى', 'Other');

  static const List<Category> all = [
    restaurants,
    groceries,
    transport,
    fuel,
    bills,
    shopping,
    health,
    education,
    entertainment,
    subscriptions,
    transfers,
    cash,
    travel,
    gifts,
    kids,
    home,
    cafes,
    maintenance,
    smoking,
    fitness,
    beauty,
    charity,
    pets,
    insurance,
    income,
    other,
  ];

  static Category byKey(String key) =>
      all.firstWhere((c) => c.key == key, orElse: () => other);
}
