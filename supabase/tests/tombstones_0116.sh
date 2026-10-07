#!/usr/bin/env bash
# Stages a THROWAWAY local Postgres (chain 0001..0115), snapshots the public function
# catalog and the grants/policies, applies 0116, runs tombstones_0116.sql, applies the
# rollback and asserts the catalog is EXACTLY the pre-0116 snapshot, then re-applies 0116.
#   PGHOST=/path/to/socket-dir [DB=qirsh_tombstone_proof] supabase/tests/tombstones_0116.sh
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
export PGOPTIONS="-c client_min_messages=warning"
export PGHOST="${PGHOST:?set PGHOST to the local postgres socket dir/host}"
DB="${DB:-qirsh_tombstone_proof}"
P=(psql -U "${PGUSER:-postgres}" -v ON_ERROR_STOP=1 -q)
"${P[@]}" -d postgres -c "DROP DATABASE IF EXISTS $DB;" -c "CREATE DATABASE $DB;" >/dev/null || exit 1
"${P[@]}" -d "$DB" < "$ROOT/supabase/tools/dryrun_scaffold.sql" >/dev/null || { echo "scaffold FAILED"; exit 1; }
apply() { for f in "$ROOT"/supabase/migrations/*.sql; do
  n=$(basename "$f" | sed -E 's/^0*([0-9]+)_.*/\1/'); [ "$n" -lt "$1" ] && continue; [ "$n" -gt "$2" ] && continue
  sed -E 's/^[[:space:]]*(CREATE|create)[[:space:]]+(EXTENSION|extension)[[:space:]]+(IF NOT EXISTS[[:space:]]+|if not exists[[:space:]]+)?(pg_cron|pg_net)[^;]*;/SELECT 1; -- stubbed/I' "$f" \
    | "${P[@]}" -d "$DB" >/dev/null || { echo "FAILED: $(basename "$f")"; exit 1; }
done; }
snap() { "${P[@]}" -d "$DB" -Atc "select 'F', p.oid::regprocedure::text, p.prosecdef, p.proconfig::text, p.proacl::text from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' order by 2;" \
  -c "select 'G', table_name, grantee, privilege_type from information_schema.role_table_grants where table_schema='public' order by 2,3,4;" \
  -c "select 'P', tablename, policyname, cmd, qual, with_check from pg_policies where schemaname='public' order by 2,3;"; }
apply 1 115 || exit 1
snap > "$DB.before"
apply 116 116 || exit 1
"${P[@]}" -d "$DB" -f "$ROOT/supabase/tests/tombstones_0116.sql" | grep -E "FAIL|passed|ERROR|^ +[0-9]+ +\|"; [ "${PIPESTATUS[0]}" -eq 0 ] || { rm -f "$DB".before; exit 1; }
"${P[@]}" -d "$DB" -f "$ROOT/supabase/rollback/0116_category_and_contribution_tombstones_rollback.sql" >/dev/null || { echo "ROLLBACK FAILED"; exit 1; }
snap > "$DB.after"
if diff -q "$DB.before" "$DB.after" >/dev/null; then echo "rollback round trip OK: functions, grants and policies identical to pre-0116"; else echo "ROLLBACK ROUND TRIP FAILED"; diff "$DB.before" "$DB.after" | head -20; rm -f "$DB".before "$DB".after; exit 1; fi
rm -f "$DB.before" "$DB.after"
apply 116 116 || exit 1; echo "0116 re-applied after rollback OK"
"${P[@]}" -d "$DB" -f "$ROOT/supabase/tests/tombstones_0116.sql" | grep -E "FAIL|passed|ERROR|^ +[0-9]+ +\|"; [ "${PIPESTATUS[0]}" -eq 0 ] || exit 1
