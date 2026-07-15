import 'package:drift/drift.dart';

import '../../core/utils/id_generator.dart';
import '../../domain/entities/category_entity.dart';
import '../../domain/repositories/category_repository.dart';
import '../db/app_database.dart';
import '../db/sql_value_codec.dart';

class DriftCategoryRepository implements CategoryRepository {
  DriftCategoryRepository(this._db);

  final AppDatabase _db;

  @override
  Future<List<CategoryEntity>> getAll() async {
    final rows = await _db
        .customSelect(
          'SELECT * FROM categories ORDER BY sort_order ASC;',
        )
        .get();
    return rows
        .map(
          (r) => CategoryEntity(
            id: r.read<String>('id'),
            key: r.read<String>('key'),
            nameAr: r.read<String>('name_ar'),
            icon: r.read<String>('icon'),
            color: r.read<String>('color'),
            isIncome: sqlToBool(r.read<int>('is_income')),
            sort: r.read<int>('sort_order'),
          ),
        )
        .toList();
  }

  @override
  Future<CategoryEntity> createCategory({
    required String nameAr,
    required String icon,
    required String color,
    required bool isIncome,
  }) async {
    final id = IdGenerator.next();
    final key = await _uniqueKey(_slugify(nameAr));
    final sort = await _nextSort();
    await _db.customInsert(
      '''
        INSERT INTO categories(id, key, name_ar, icon, color, is_income, sort_order)
        VALUES (?, ?, ?, ?, ?, ?, ?);
      ''',
      variables: [
        Variable.withString(id),
        Variable.withString(key),
        Variable.withString(nameAr.trim()),
        Variable.withString(icon),
        Variable.withString(color),
        Variable.withInt(boolToSql(isIncome)),
        Variable.withInt(sort),
      ],
    );
    return _getById(id);
  }

  @override
  Future<CategoryEntity> updateCategory(CategoryEntity category) async {
    if (category.sort < 0) {
      throw StateError('Internal category cannot be edited.');
    }
    await _db.customUpdate(
      '''
        UPDATE categories
        SET name_ar = ?, icon = ?, color = ?, is_income = ?, sort_order = ?
        WHERE id = ?;
      ''',
      variables: [
        Variable.withString(category.nameAr.trim()),
        Variable.withString(category.icon),
        Variable.withString(category.color),
        Variable.withInt(boolToSql(category.isIncome)),
        Variable.withInt(category.sort),
        Variable.withString(category.id),
      ],
    );
    return _getById(category.id);
  }

  @override
  Future<void> deleteCategory(String id) async {
    final category = await _getById(id);
    if (category.sort < 0) {
      throw StateError('Internal category cannot be deleted.');
    }
    final fallbackKey = category.isIncome ? 'income' : 'other';
    final fallback = await _categoryIdByKey(fallbackKey);
    if (fallback == null || fallback == id) {
      throw StateError('Fallback category is missing.');
    }
    await _db.customUpdate(
      'UPDATE transactions SET category_id = ? WHERE category_id = ?;',
      variables: [
        Variable.withString(fallback),
        Variable.withString(id),
      ],
    );
    await _db.customUpdate(
      'DELETE FROM merchant_category_map WHERE category_id = ?;',
      variables: [Variable.withString(id)],
    );
    await _db.customUpdate(
      'DELETE FROM budgets WHERE category_id = ?;',
      variables: [Variable.withString(id)],
    );
    await _db.customUpdate(
      'DELETE FROM categories WHERE id = ?;',
      variables: [Variable.withString(id)],
    );
  }

  Future<CategoryEntity> _getById(String id) async {
    final row = await _db.customSelect(
      'SELECT * FROM categories WHERE id = ? LIMIT 1;',
      variables: [Variable.withString(id)],
    ).getSingleOrNull();
    if (row == null) {
      throw StateError('Category not found: $id');
    }
    return CategoryEntity(
      id: row.read<String>('id'),
      key: row.read<String>('key'),
      nameAr: row.read<String>('name_ar'),
      icon: row.read<String>('icon'),
      color: row.read<String>('color'),
      isIncome: sqlToBool(row.read<int>('is_income')),
      sort: row.read<int>('sort_order'),
    );
  }

  Future<int> _nextSort() async {
    final row = await _db
        .customSelect(
          'SELECT COALESCE(MAX(sort_order), 0) + 1 AS next_sort FROM categories;',
        )
        .getSingle();
    return row.read<int>('next_sort');
  }

  Future<String?> _categoryIdByKey(String key) async {
    final row = await _db.customSelect(
      'SELECT id FROM categories WHERE key = ? LIMIT 1;',
      variables: [Variable.withString(key)],
    ).getSingleOrNull();
    return row?.read<String>('id');
  }

  Future<String> _uniqueKey(String base) async {
    var candidate = base.isEmpty ? 'category' : base;
    var suffix = 2;
    while (await _categoryIdByKey(candidate) != null) {
      candidate = '${base}_$suffix';
      suffix += 1;
    }
    return candidate;
  }

  String _slugify(String input) {
    final normalized = input
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9\u0600-\u06FF]+'), '_')
        .replaceAll(RegExp(r'_+'), '_')
        .replaceAll(RegExp(r'^_|_$'), '');
    return normalized.isEmpty ? 'category' : 'custom_$normalized';
  }
}
