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
}
