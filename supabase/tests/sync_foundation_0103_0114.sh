#!/usr/bin/env bash
# Stages a THROWAWAY local Postgres and runs the WP-2 SQL proof:
#   1. fresh DB + supabase/tools/dryrun_scaffold.sql
#   2. migrations 0001..0102
#   3. supabase/tests/sync_seed_pre_0103.sql   (rows that the 0103-0109 backfill must number)
#   4. migrations 0103.. (every file above 0102 in supabase/migrations, in order)
#   5. supabase/tests/sync_foundation_0103_0114.sql (rolled back)
# Never touches a hosted project: it only talks to the local server named by
# PGHOST (a unix socket dir or host) as PGUSER (default postgres).
#
#   PGHOST=/path/to/socket-dir [PGUSER=postgres] [DB=qirsh_sync_proof] \
#     supabase/tests/sync_foundation_0103_0114.sh
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
export PGHOST="${PGHOST:?set PGHOST to the local postgres socket dir/host}"
PGUSER="${PGUSER:-postgres}"; DB="${DB:-qirsh_sync_proof}"
P=(psql -U "$PGUSER" -v ON_ERROR_STOP=1 -q)
"${P[@]}" -d postgres -c "DROP DATABASE IF EXISTS $DB;" -c "CREATE DATABASE $DB;" >/dev/null || exit 1
"${P[@]}" -d "$DB" < "$ROOT/supabase/tools/dryrun_scaffold.sql" >/dev/null || { echo "scaffold FAILED"; exit 1; }
apply() { # first last
  for f in "$ROOT"/supabase/migrations/*.sql; do
    n=$(basename "$f" | sed -E 's/^0*([0-9]+)_.*/\1/')
    [ "$n" -lt "$1" ] && continue; [ "$n" -gt "$2" ] && continue
    sed -E 's/^[[:space:]]*(CREATE|create)[[:space:]]+(EXTENSION|extension)[[:space:]]+(IF NOT EXISTS[[:space:]]+|if not exists[[:space:]]+)?(pg_cron|pg_net)[^;]*;/SELECT 1; -- stubbed/I' "$f" \
      | "${P[@]}" -d "$DB" >/dev/null 2>"$DB.err" || { echo "FAILED: $(basename "$f")"; cat "$DB.err"; rm -f "$DB.err"; exit 1; }
  done
}
apply 1 102 || exit 1
"${P[@]}" -d "$DB" -f "$ROOT/supabase/tests/sync_seed_pre_0103.sql" >/dev/null || { echo "seed FAILED"; exit 1; }
apply 103 9999 || exit 1
rm -f "$DB.err"
"${P[@]}" -d "$DB" -f "$ROOT/supabase/tests/sync_foundation_0103_0114.sql" >"$DB.proof.out"; rc=$?; grep -E "FAIL|passed|ERROR|^ +[0-9]+ +\|" "$DB.proof.out"; rm -f "$DB.proof.out"

# 6. Rollback round trip: roll back this unit's 0114, 0109..0103 newest first
#    (0110-0113 belong to other units and are not touched), assert the schema is back to the
#    0102 shape, then re-apply the migrations (proves they are re-runnable).
[ "$rc" -eq 0 ] || exit "$rc"
for n in 0114 0109 0108 0107 0106 0105 0104 0103; do
  f=$(ls "$ROOT"/supabase/rollback/${n}_*_rollback.sql 2>/dev/null | head -1)
  [ -n "$f" ] || { echo "missing rollback $n"; exit 1; }
  "${P[@]}" -d "$DB" -f "$f" >/dev/null 2>"$DB.err" || { echo "ROLLBACK FAILED: $f"; cat "$DB.err"; exit 1; }
done
left=$("${P[@]}" -d "$DB" -Atc "select (select count(*) from information_schema.columns where table_schema='public' and column_name in ('sync_seq','last_op_id'))
  + (select count(*) from pg_proc where proname in ('stamp_sync_seq','sync_cas_update','sync_insert_if_absent','sync_cas_tombstone','sync_lock_epoch','backfill_sync_seq'))
  + (select count(*) from pg_class where relname='user_sync_state')
  + (select count(*) from information_schema.columns where table_name='user_settings' and column_name='consent_version')")
caps=$("${P[@]}" -d "$DB" -Atc "select public.qirsh_server_capabilities()::text")
echo "after rollback: leftover objects=$left capabilities=$caps"
[ "$left" = "0" ] && [ "$caps" = '{"awaiting_fx_transactions": true}' ] || { echo "ROLLBACK ROUND TRIP FAILED"; exit 1; }
apply 103 9999 || exit 1
rm -f "$DB.err"
echo "rollback round trip OK (rolled back 0114..0103, re-applied 0103+)"
