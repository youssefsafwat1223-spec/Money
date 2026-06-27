/// التصنيفات الـ20 الأساسية (PRODUCT_SPEC §6). `key` ثابت يُخزَّن في DB،
/// و`arName` للعرض.
class Category {
  const Category(this.key, this.arName);

  final String key;
  final String arName;

  @override
  String toString() => '$key ($arName)';
}

class Categories {
  Categories._();

  static const restaurants = Category('restaurants', 'مطاعم');
  static const groceries = Category('groceries', 'بقالة');
  static const transport = Category('transport', 'مواصلات');
  static const fuel = Category('fuel', 'وقود');
  static const bills = Category('bills', 'فواتير');
  static const shopping = Category('shopping', 'تسوق');
  static const health = Category('health', 'صحة');
  static const education = Category('education', 'تعليم');
  static const entertainment = Category('entertainment', 'ترفيه');
  static const subscriptions = Category('subscriptions', 'اشتراكات');
  static const transfers = Category('transfers', 'تحويلات');
  static const cash = Category('cash', 'سحب نقدي');
  static const travel = Category('travel', 'سفر');
  static const gifts = Category('gifts', 'هدايا');
  static const kids = Category('kids', 'أطفال');
  static const home = Category('home', 'منزل');
  static const cafes = Category('cafes', 'كافيهات');
  static const maintenance = Category('maintenance', 'صيانة');
  static const fitness = Category('fitness', 'لياقة ورياضة');
  static const beauty = Category('beauty', 'عناية شخصية');
  static const charity = Category('charity', 'تبرعات');
  static const pets = Category('pets', 'حيوانات أليفة');
  static const insurance = Category('insurance', 'تأمين');
  static const income = Category('income', 'دخل');
  static const other = Category('other', 'أخرى');

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
