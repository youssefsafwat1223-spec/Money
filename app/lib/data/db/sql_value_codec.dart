int boolToSql(bool value) => value ? 1 : 0;

bool sqlToBool(Object? value) => value == 1 || value == true;

String dateTimeToSql(DateTime value) => value.toUtc().toIso8601String();

DateTime dateTimeFromSql(String value) => DateTime.parse(value).toUtc();

String escapeSqlString(String value) => value.replaceAll("'", "''");

String sqlString(String value) => "'${escapeSqlString(value)}'";

String sqlNullableString(String? value) =>
    value == null ? 'NULL' : sqlString(value);

String sqlNullableNum(num? value) => value == null ? 'NULL' : value.toString();

/// A-4b: SET-clause fragment for raw SQL writers that change a synced table
/// outside a repository. A server-backed row (`server_id IS NOT NULL`) becomes
/// `pending`, so PendingSyncReconciler records sync intent for it — a bypassed
/// row can never stay marked `synced` and be overwritten by the stale server
/// value on the next pull. Never hand-write outbox rows from such a writer.
const String kMarkPendingIfServerBacked =
    "sync_status = CASE WHEN server_id IS NOT NULL THEN 'pending' ELSE sync_status END";
