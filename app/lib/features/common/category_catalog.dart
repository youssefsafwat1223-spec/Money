import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/di/app_providers.dart';
import '../../core/utils/formatters.dart';
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
  Color get color => Formatters.colorFromHex(entity.color);
}

/// كتالوج التصنيفات (id↔عرض، key↔عرض) — يُحمّل مرة من DB.
class CategoryCatalog {
  CategoryCatalog(List<CategoryEntity> categories)
      : all = categories.map(CategoryView.new).toList() {
    for (final view in all) {
      _byId[view.id] = view;
      _byKey[view.key] = view;
    }
  }

  final List<CategoryView> all;
  final Map<String, CategoryView> _byId = {};
  final Map<String, CategoryView> _byKey = {};

  CategoryView? byId(String? id) => id == null ? null : _byId[id];
  CategoryView? byKey(String? key) => key == null ? null : _byKey[key];
}

final categoryCatalogProvider = FutureProvider<CategoryCatalog>((ref) async {
  final categories = await ref.watch(categoryRepositoryProvider).getAll();
  return CategoryCatalog(categories);
});
