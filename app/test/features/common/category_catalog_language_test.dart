import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/domain/entities/budget_entity.dart';
import 'package:money_companion/domain/entities/category_entity.dart';
import 'package:money_companion/engine/categorization/category.dart';
import 'package:money_companion/features/common/category_catalog.dart';

/// `CategoryView.name` is the only place category names become English, and it
/// resolves by KEY against the seeded catalog. Anything with a key the catalog
/// does not carry falls through to the Arabic name — which is correct for a
/// category the user typed themselves, and wrong for a system one.
///
/// `all_expenses` was exactly that: a system pseudo-category with a fixed id
/// (`__all_expenses__`), seeded ahead of the real ones and deliberately kept
/// out of `Categories.all` so it never appears in a picker. The user cannot
/// rename it, so it is copy — and it read «كل المصروفات» in the English build.
void main() {
  CategoryEntity entity(String key, String nameAr, {String id = 'x'}) =>
      CategoryEntity(
        id: id,
        key: key,
        nameAr: nameAr,
        icon: 'wallet',
        color: '#000000',
        isIncome: false,
        sort: 0,
      );

  test('a seeded category resolves to its English name', () {
    final view = CategoryView(entity('groceries', 'بقالة'), languageCode: 'en');
    expect(view.name, 'Groceries');
    expect(view.nameAr, 'بقالة');
  });

  test('the all-expenses pseudo-category is English under en', () {
    final view = CategoryView(
      entity(BudgetEntity.allExpensesCategoryKey, 'كل المصروفات',
          id: BudgetEntity.allExpensesCategoryId),
      languageCode: 'en',
    );
    expect(view.name, 'All expenses');
    expect(RegExp(r'[؀-ۿ]').hasMatch(view.name), isFalse);
  });

  test('the all-expenses pseudo-category keeps its Arabic under ar', () {
    final view = CategoryView(
      entity(BudgetEntity.allExpensesCategoryKey, 'كل المصروفات'),
      languageCode: 'ar',
    );
    expect(view.name, 'كل المصروفات');
  });

  test('a user-created category keeps the ONE name they typed', () {
    // The opposite failure: rendering a user's own name through a catalog
    // would overwrite what they chose. A key the catalog does not know must
    // fall through, in both languages.
    for (final lang in ['ar', 'en']) {
      final view =
          CategoryView(entity('my_custom_key', 'مصاريف الشاليه'), languageCode: lang);
      expect(view.name, 'مصاريف الشاليه',
          reason: 'a name the user typed was replaced under $lang');
    }
  });

  test('every key in Categories.all has a non-empty English name', () {
    // The resolution above is only as good as the catalog behind it.
    for (final c in Categories.all) {
      expect(c.enName.trim(), isNotEmpty, reason: '${c.key} has no English name');
      expect(RegExp(r'[؀-ۿ]').hasMatch(c.enName), isFalse,
          reason: '${c.key} English name is Arabic: ${c.enName}');
      expect(c.enName, isNot(c.arName), reason: '${c.key} names are identical');
    }
  });
}
