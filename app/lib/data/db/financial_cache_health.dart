import 'package:drift/drift.dart';

import 'app_database.dart';
import 'sql_value_codec.dart';

/// حالة صحة الكاش المحلي (Drift) لكيان مالي أثناء فترة الطرح التدريجي.
/// [entityType] identifies the financial cache slice being mirrored.
class FinancialCacheHealth {
  const FinancialCacheHealth({
    required this.entityType,
    required this.dirty,
    this.lastError,
    this.markedAt,
    this.repairedAt,
  });

  final String entityType;
  final bool dirty;
  final String? lastError;
  final DateTime? markedAt;
  final DateTime? repairedAt;
}

const accountsCacheEntityType = 'accounts';
const transactionsCacheEntityType = 'transactions';
const budgetsCacheEntityType = 'budgets';
const goalsCacheEntityType = 'goals';
const subscriptionsCacheEntityType = 'subscriptions';
const plansCacheEntityType = 'plans';
const smartInboxCacheEntityType = 'smart_inbox';

/// A server write has already committed before [mirror] runs. Cache failure is
/// therefore recorded for repair and must not turn the authoritative operation
/// into a user-visible failure or encourage a second server write.
Future<void> mirrorFinancialCacheSafely(
  AppDatabase db,
  String entityType,
  Future<void> Function() mirror,
) async {
  try {
    await mirror();
  } catch (error) {
    try {
      await markFinancialCacheDirty(db, entityType, error.runtimeType);
    } catch (_) {
      // The cache database itself may be unavailable. Supabase success still
      // remains authoritative; repair is retried on a later healthy launch.
    }
  }
}

/// يُستدعى عندما تنجح عملية Supabase لكن كتابة مرآة Drift المحلية تفشل —
/// النتيجة تُعاد للواجهة كنجاح (Supabase هو المرجع)، لكن الكاش المحلي يُعلَّم
/// كغير موثوق حتى تُصلَح لاحقًا عبر [repairFinancialCache].
Future<void> markFinancialCacheDirty(
  AppDatabase db,
  String entityType,
  Object error,
) async {
  final now = dateTimeToSql(DateTime.now().toUtc());
  await db.customStatement(
    '''
      INSERT INTO financial_cache_health(entity_type, dirty, last_error, marked_at)
      VALUES (?, 1, ?, ?)
      ON CONFLICT(entity_type) DO UPDATE SET
        dirty = 1,
        last_error = excluded.last_error,
        marked_at = excluded.marked_at;
    ''',
    [entityType, error.toString(), now],
  );
}

Future<void> clearFinancialCacheDirty(AppDatabase db, String entityType) async {
  final now = dateTimeToSql(DateTime.now().toUtc());
  await db.customStatement(
    '''
      INSERT INTO financial_cache_health(entity_type, dirty, repaired_at)
      VALUES (?, 0, ?)
      ON CONFLICT(entity_type) DO UPDATE SET
        dirty = 0,
        repaired_at = excluded.repaired_at;
    ''',
    [entityType, now],
  );
}

Future<bool> isFinancialCacheDirty(AppDatabase db, String entityType) async {
  final row = await db.customSelect(
    'SELECT dirty FROM financial_cache_health WHERE entity_type = ? LIMIT 1;',
    variables: [Variable.withString(entityType)],
  ).getSingleOrNull();
  if (row == null) return false;
  return sqlToBool(row.read<int>('dirty'));
}

/// Routes one financial operation without ever trusting a dirty Drift mirror.
/// Supabase-primary operations bypass the guard because Supabase is
/// authoritative. A disabled flag may use Drift only after its cache slice is
/// known to be safe; otherwise the caller receives a typed server error and
/// can repair before retrying the rollback.
