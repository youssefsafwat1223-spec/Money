import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/db/app_database.dart';
import '../di/app_providers.dart';

/// حذف كل البيانات المالية المحلية والشخصية (Privacy → «حذف كل بياناتي»،
/// وتسجيل الخروج العادي — انظر AppSession.signOut).
///
/// يمسح كل بيانات المستخدم المرتبطة بالهوية الحالية: العمليات، الحسابات،
/// الميزانيات، الأهداف، الاشتراكات، الخطط، صندوق الوارد الذكي، بيانات الملف
/// الشخصي (user_settings)، وكل طوابير المزامنة/الالتقاط المحلية حتى لا تُرفع
/// لاحقاً باسم مستخدم آخر على نفس الجهاز. لا يمسح كتالوج التصنيفات/البنوك/
/// المحلّلات (بيانات مرجعية عامة، ليست شخصية). الحساب/الجلسة تُمسح عبر
/// AppSession. الجداول ذات الصف الوحيد (user_settings, streaks, xp_levels)
/// تُعاد بذرتها فوراً بعد المسح عبر reseedDefaultsAfterWipe.
class DataWipeService {
  DataWipeService(this._db);

  final AppDatabase _db;

  static const List<String> _tables = [
    'transactions',
    'accounts',
    'cards',
    'goal_contributions',
    'goals',
    'budgets',
    'merchant_category_map',
    'merchants',
    'subscriptions',
    'bill_payments',
    'plans',
    'plan_transaction_links',
    'smart_inbox_items',
    'suspected_duplicates',
    'sender_bank_mappings',
    'dedup_hashes',
    'ledger_sync_outbox',
    'planning_sync_outbox',
    'sync_cursors',
    'pending_merchant_feedback',
    'financial_cache_health',
    'achievements',
    'streaks',
    'xp_levels',
    'user_settings',
  ];

  Future<void> wipeAll() async {
    for (final table in _tables) {
      await _db.customStatement('DELETE FROM $table;');
    }
    // Built-in categories are catalog data and remain available. Custom rows
    // belong to the signed-out user and must not leak into the next session.
    await _db.customStatement('''
      DELETE FROM categories
      WHERE key LIKE 'custom_%'
         OR server_id IS NOT NULL
         OR sync_status IS NOT NULL;
    ''');
    await _db.reseedDefaultsAfterWipe();
  }
}

final dataWipeServiceProvider = Provider<DataWipeService>((ref) {
  return DataWipeService(ref.watch(appDatabaseProvider));
});
