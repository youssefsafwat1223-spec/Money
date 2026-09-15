import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/domain/entities/category_entity.dart';
import 'package:money_companion/engine/categorization/category.dart';
import 'package:money_companion/features/common/category_catalog.dart';

/// F-1 — bilingual category names.
///
/// The local `categories` table has `name_ar` and no `name_en` at all; English
/// names exist only in `remote_categories`. Every surface therefore rendered
/// Arabic category names regardless of locale. Category keys are stable, so the
/// English name is resolved from [Categories] rather than by migrating a
/// financial database for a presentation concern.
CategoryEntity _entity(String key, String nameAr) => CategoryEntity(
      id: 'id_$key',
      key: key,
      nameAr: nameAr,
      icon: 'wallet-cards',
      color: '#AB47BC',
      isIncome: false,
      sort: 0,
    );

void main() {
  test('a system category renders English under an English locale', () {
    final view =
        CategoryView(_entity('restaurants', 'مطاعم'), languageCode: 'en');
    expect(view.name, 'Restaurants');
    // The raw stored value is still reachable for the places that mean it.
    expect(view.nameAr, 'مطاعم');
  });

  test('Arabic is unchanged, and is the default', () {
    expect(CategoryView(_entity('restaurants', 'مطاعم')).name, 'مطاعم');
    expect(
      CategoryView(_entity('restaurants', 'مطاعم'), languageCode: 'ar').name,
      'مطاعم',
    );
  });

  test('every category in the Dart catalogue has both names', () {
    // A missing English name silently falls back to Arabic, which looks like
    // the bug this fixes rather than a failure.
    for (final category in Categories.all) {
      expect(category.arName.trim(), isNotEmpty, reason: category.key);
      expect(category.enName.trim(), isNotEmpty, reason: category.key);
    }
    expect(Categories.all.map((c) => c.enName).toSet(),
        hasLength(Categories.all.length),
        reason: 'two categories sharing an English name are indistinguishable');
  });

  test('a user-created category keeps the name the user typed', () {
    // Custom categories have exactly one name and no stable key to look up.
    final custom = CategoryView(
      _entity('my_custom_thing', 'مصروف خاص'),
      languageCode: 'en',
    );
    expect(custom.name, 'مصروف خاص');
  });

  test('the catalogue propagates the language to every view', () {
    final catalog = CategoryCatalog(
      [_entity('restaurants', 'مطاعم'), _entity('fuel', 'وقود')],
      languageCode: 'en',
    );
    expect(catalog.byKey('restaurants')!.name, 'Restaurants');
    expect(catalog.byKey('fuel')!.name, 'Fuel');
    expect(catalog.all.every((v) => v.languageCode == 'en'), isTrue);
  });

  test('the smoking category is bilingual too', () {
    expect(CategoryView(_entity('smoking', 'تدخين'), languageCode: 'en').name,
        'Smoking');
    expect(CategoryView(_entity('smoking', 'تدخين')).name, 'تدخين');
  });
}
