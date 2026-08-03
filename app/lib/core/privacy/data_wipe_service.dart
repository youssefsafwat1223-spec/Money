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

  /// Every table `wipeAll` empties outright. Exposed so a test can assert the
  /// schema has no unclassified table silently escaping the wipe (MALI-011).
  /// `categories` is not here — it is special-cased below (custom rows only).
  static const List<String> wipedTables = [
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
    'parked_child_rows',
    'pending_merchant_feedback',
    'financial_cache_health',
    // User-scoped operational rows that used to survive sign-out and leak into
    // the next user's session on this device (the SQLCipher key and DB file are
    // reused across users, so an unwiped table is readable as-is): the previous
    // user's statement/CSV import outcomes and their notification history.
    'financial_import_runs',
    'notification_log_events',
    'achievements',
    'streaks',
    'xp_levels',
    'user_settings',
  ];

  Future<void> wipeAll() async {
    // MALI-011: the wipe must be ATOMIC. A crash mid-loop previously left a
    // partially-deleted database that the owner gate would then treat as
    // "owned" once the owner uid was (re)claimed — leaking one user's residue
    // into the next session. Wrapping the deletes + reseed in one transaction
    // makes the wipe all-or-nothing.
    await _db.transaction(() async {
      for (final table in wipedTables) {
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
    });
  }
}

final dataWipeServiceProvider = Provider<DataWipeService>((ref) {
  return DataWipeService(ref.watch(appDatabaseProvider));
});
