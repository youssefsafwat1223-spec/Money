import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/engine/categorization/categorizer.dart';
import 'package:money_companion/engine/categorization/category.dart';
import 'package:money_companion/engine/categorization/merchant_category_map.dart';
import 'package:money_companion/engine/models/parsed_transaction.dart';
import 'package:money_companion/engine/models/transaction_source.dart';
import 'package:money_companion/engine/models/transaction_type.dart';

ParsedTransaction _txn({
  String? merchant,
  TransactionType type = TransactionType.payment,
}) {
  return ParsedTransaction(
    amountText: '45',
    amount: 45,
    currency: 'SAR',
    type: type,
    source: TransactionSource.card,
    rawMerchant: merchant,
  );
}

void main() {
  group('Categorizer — كلمات مفتاحية (بذور سعودية)', () {
    final c = Categorizer();

    test('BURGER BOUTIQUE → مطاعم', () {
      expect(c.categorize(_txn(merchant: 'BURGER BOUTIQUE')).categoryKey,
          Categories.restaurants.key);
    });

    test('بنده → بقالة', () {
      expect(c.categorize(_txn(merchant: 'بنده')).categoryKey,
          Categories.groceries.key);
    });

    test('JARIR → تسوق', () {
      expect(c.categorize(_txn(merchant: 'JARIR')).categoryKey,
          Categories.shopping.key);
    });

    test('متجر غير معروف → أخرى', () {
      final r = c.categorize(_txn(merchant: 'XYZ UNKNOWN SHOP'));
      expect(r.categoryKey, Categories.other.key);
      expect(r.source, CategorySource.fallback);
    });

    test('new category types map from merchant seeds', () {
      expect(c.categorize(_txn(merchant: 'FITNESS TIME')).categoryKey,
          Categories.fitness.key);
      expect(c.categorize(_txn(merchant: 'صالون الرجال')).categoryKey,
          Categories.beauty.key);
      expect(c.categorize(_txn(merchant: 'تبرع لجمعية خيرية')).categoryKey,
          Categories.charity.key);
      expect(c.categorize(_txn(merchant: 'BUPA INSURANCE')).categoryKey,
          Categories.insurance.key);
      expect(c.categorize(_txn(merchant: 'عيادة بيطري')).categoryKey,
          Categories.pets.key);
    });

    test('new Gulf/Egypt merchant seeds map correctly', () {
      expect(c.categorize(_txn(merchant: 'ADNOC STATION 12')).categoryKey,
          Categories.fuel.key);
      expect(c.categorize(_txn(merchant: 'KOSHARY ABOU TAREK')).categoryKey,
          Categories.restaurants.key);
      expect(c.categorize(_txn(merchant: 'NAMSHI')).categoryKey,
          Categories.shopping.key);
      expect(c.categorize(_txn(merchant: 'كازيون')).categoryKey,
          Categories.groceries.key);
      expect(c.categorize(_txn(merchant: 'ANGHAMI')).categoryKey,
          Categories.subscriptions.key);
    });
  });

  group('Categorizer — قواعد النوع', () {
    final c = Categorizer();

    test('سحب → سحب نقدي', () {
      expect(c.categorize(_txn(type: TransactionType.withdrawal)).categoryKey,
          Categories.cash.key);
    });

    test('تحويل → تحويلات', () {
      expect(c.categorize(_txn(type: TransactionType.transfer)).categoryKey,
          Categories.transfers.key);
    });

    test('دخل → دخل', () {
      expect(c.categorize(_txn(type: TransactionType.income)).categoryKey,
          Categories.income.key);
    });
  });

  group('Categorizer — التعلّم من تصحيح المستخدم', () {
    test('بعد confirmMerchant يصبح المصدر userMap', () {
      final c = Categorizer();
      const merchant = 'MY LOCAL CAFE';
      // قبل: افتراضي.
      expect(c.categorize(_txn(merchant: merchant)).categoryKey,
          Categories.other.key);
      // المستخدم يصحّح إلى كافيهات.
      c.confirmMerchant(merchant, Categories.cafes.key);
      final after = c.categorize(_txn(merchant: merchant));
      expect(after.categoryKey, Categories.cafes.key);
      expect(after.source, CategorySource.userMap);
    });

    test('merchant_map يعطي الأولوية حتى لو طابق keyword', () {
      final map =
          MerchantCategoryMap({'BURGER BOUTIQUE': Categories.cafes.key});
      final c = Categorizer(map: map);
      // رغم أن BURGER كلمة مفتاحية لمطاعم، تصحيح المستخدم أولى.
      expect(c.categorize(_txn(merchant: 'BURGER BOUTIQUE')).categoryKey,
          Categories.cafes.key);
    });
  });

  group('MerchantCategoryMap.normalize', () {
    test('يطبّع الأحرف والأرقام', () {
      expect(MerchantCategoryMap.normalize('Burger 123  Boutique'),
          'BURGER BOUTIQUE');
    });
  });
}
