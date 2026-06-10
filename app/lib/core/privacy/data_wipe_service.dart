import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/db/app_database.dart';
import '../di/app_providers.dart';

/// حذف كل البيانات المالية المحلية (Privacy → «حذف كل بياناتي»).
///
/// يمسح العمليات والتجار والميزانيات والأهداف ومخرجات التلعيب.
/// لا يمسح كتالوج التصنيفات (بذور). الحساب/الجلسة تُمسح عبر AppSession.
class DataWipeService {
  DataWipeService(this._db);

  final AppDatabase _db;

  static const List<String> _tables = [
    'transactions',
    'goal_contributions',
    'goals',
    'budgets',
    'merchant_category_map',
    'merchants',
    'subscriptions',
    'achievements',
    'streaks',
    'xp_levels',
  ];

  Future<void> wipeAll() async {
    for (final table in _tables) {
      await _db.customStatement('DELETE FROM $table;');
    }
  }
}

final dataWipeServiceProvider = Provider<DataWipeService>((ref) {
  return DataWipeService(ref.watch(appDatabaseProvider));
});
