int boolToSql(bool value) => value ? 1 : 0;

bool sqlToBool(Object? value) => value == 1 || value == true;

String dateTimeToSql(DateTime value) => value.toUtc().toIso8601String();

DateTime dateTimeFromSql(String value) => DateTime.parse(value).toUtc();

String escapeSqlString(String value) => value.replaceAll("'", "''");

String sqlString(String value) => "'${escapeSqlString(value)}'";

String sqlNullableString(String? value) =>
    value == null ? 'NULL' : sqlString(value);

String sqlNullableNum(num? value) => value == null ? 'NULL' : value.toString();
