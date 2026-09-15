import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/utils/category_emoji.dart';
import 'package:money_companion/core/utils/lucide_icon_map.dart';
import 'package:money_companion/data/db/database_seed.dart';
import 'package:money_companion/engine/categorization/category.dart';
import 'package:money_companion/engine/categorization/category_seeds.dart';

/// V1 adds a smoking/tobacco expense category (charter:
/// REQUIRED_PRODUCT_CHANGE_1).
///
/// It has to arrive by two independent routes, and they must agree.
/// `Categories.all` feeds `DatabaseSeed.categories`, which is replayed through
/// `INSERT OR IGNORE` on every database open — that is what reaches an EXISTING
/// install. `assets/catalog/categories.json` is the bundled catalogue, seeded
/// only into an empty `remote_categories`, and the shape the server mirrors. A
/// category present in one and absent from the other is invisible to half the
/// installed base, so the agreement is asserted rather than assumed.
void main() {
  test('smoking is a first-class category in the Dart source of truth', () {
    expect(Categories.all.map((c) => c.key), contains('smoking'));
    expect(Categories.byKey('smoking').arName, 'تدخين');
    // byKey falls back to `other` for anything unknown — prove this is a real
    // hit and not the fallback.
    expect(Categories.byKey('smoking').key, isNot(Categories.other.key));
  });

  test('it reaches existing installs through DatabaseSeed', () {
    final seeded = DatabaseSeed.categories.where((c) => c.key == 'smoking');
    expect(seeded, hasLength(1));
    expect(seeded.single.nameAr, 'تدخين');
    expect(seeded.single.isIncome, isFalse);
  });

  test('the bundled catalogue carries it, bilingually and uniquely', () {
    final catalogue = (jsonDecode(
      File('assets/catalog/categories.json').readAsStringSync(),
    ) as List)
        .cast<Map<String, dynamic>>();

    final row = catalogue.singleWhere((c) => c['key'] == 'smoking');
    expect(row['name_ar'], 'تدخين');
    expect(row['name_en'], 'Smoking');
    expect(row['type'], 'expense');
    expect(row['is_active'], isTrue);

    // Ids and sort orders are load-bearing: a duplicate id collides on the
    // primary key, a duplicate sort order makes list order non-deterministic.
    final ids = catalogue.map((c) => c['id']).toList();
    final sorts = catalogue.map((c) => c['sort_order']).toList();
    expect(ids.toSet(), hasLength(ids.length), reason: 'duplicate category id');
    expect(sorts.toSet(), hasLength(sorts.length),
        reason: 'duplicate sort_order');
  });

  test('its icon and emoji resolve rather than falling back', () {
    // An icon name no map knows renders a fallback glyph with no warning, which
    // is how a new category silently looks broken.
    expect(lucideByName('cigarette'), isNot(lucideByName('__no_such_icon__')));
    expect(categoryEmoji('cigarette'), '🚬');
  });

  test('tobacco merchants categorise as smoking, in both scripts', () {
    String? keyFor(String merchant) {
      final upper = merchant.toUpperCase();
      for (final entry in CategorySeeds.keywordRules.entries) {
        if (upper.contains(entry.key.toUpperCase())) return entry.value;
      }
      return null;
    }

    for (final merchant in [
      'ALOKAIL TOBACCO',
      'Vape Store Riyadh',
      'IQOS BOUTIQUE',
      'محل سجائر',
      'متجر الدخان',
      'معسل النخبة',
    ]) {
      expect(keyFor(merchant), Categories.smoking.key, reason: merchant);
    }

    // Negative controls. A bare 'SMOKE' keyword would swallow every barbecue
    // restaurant in the country, so these must NOT land in smoking.
    for (final merchant in [
      'SMOOTHIE FACTORY',
      'THE SMOKEHOUSE GRILL',
      'Smoky Joe BBQ',
    ]) {
      expect(keyFor(merchant), isNot(Categories.smoking.key), reason: merchant);
    }
  });
}
