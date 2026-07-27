import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/di/app_providers.dart';
import '../../core/utils/formatters.dart';
import '../../core/utils/category_emoji.dart';
import '../../core/utils/category_palette.dart';
import '../../core/utils/lucide_icon_map.dart';
import '../../domain/entities/category_entity.dart';

/// نموذج عرض تصنيف (جاهز للواجهة: أيقونة + لون).
class CategoryView {
  CategoryView(this.entity);

  final CategoryEntity entity;

  String get id => entity.id;
  String get key => entity.key;
  String get nameAr => entity.nameAr;
  IconData get icon => lucideByName(entity.icon);

  /// المفتاح النصّي للأيقونة (نفس مفاتيح Lucide المخزَّنة في الـ DB).
  String get iconName => entity.icon;

  /// إيموجي التصنيف المقابل للمفتاح — يُرسَم عبر [CategoryGlyph].
  String get emoji => categoryEmoji(entity.icon);

  /// لون خلفية التايل الثابت (عميق ومكتوم) — بدل لون الـ DB المتغيّر.
  Color get tileColor => categoryTileColor(entity.icon);
  Color get color => Formatters.colorFromHex(entity.color);
}

/// كتالوج التصنيفات (id↔عرض، key↔عرض) — يُحمّل مرة من DB.
class CategoryCatalog {
  CategoryCatalog(List<CategoryEntity> categories)
      : all = _dedupeByKey(categories) {
    for (final view in all) {
      _byId[view.id] = view;
      _byKey[view.key] = view;
    }
  }

  // Guard against duplicate category rows in the DB (a duplicate key would crash
  // any DropdownButton built from `all`). Keep the first occurrence per key.
  static List<CategoryView> _dedupeByKey(List<CategoryEntity> categories) {
    final seen = <String>{};
    final result = <CategoryView>[];
    for (final entity in categories) {
      final view = CategoryView(entity);
      if (seen.add(view.key)) result.add(view);
    }
    return result;
  }

  final List<CategoryView> all;
  final Map<String, CategoryView> _byId = {};
  final Map<String, CategoryView> _byKey = {};

  CategoryView? byId(String? id) {
    if (id == null) return null;
    return _byId[id] ?? _byKey[id];
  }

  CategoryView? byKey(String? key) => key == null ? null : _byKey[key];
}

final categoryCatalogProvider = FutureProvider<CategoryCatalog>((ref) async {
  final categories = await ref.watch(categoryRepositoryProvider).getAll();
  return CategoryCatalog(categories);
});
