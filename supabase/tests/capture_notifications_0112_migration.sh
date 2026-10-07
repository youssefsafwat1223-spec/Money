#!/usr/bin/env bash
# CAP-3 migration proof on a THROWAWAY local Postgres: 0112 over pre-existing data, then its
# rollback round trip.
#   1. fresh DB + scaffold, migrations 0001..0111
#   2. seed: duplicate retry rows for one notification log, a log without install_id_hash,
#      a processed row whose push was already handed off
#   3. apply 0112: duplicates collapsed to one (unresolved kept), install_id_hash backfilled,
#      push_attempted_at backfilled so the old row is never re-pushed, UNIQUE enforced
#   4. rollback 0112 (run from the repo root, it \i's 0111), assert it is gone, re-apply
#   PGHOST=/path/to/socket-dir [PGUSER=postgres] [DB=qirsh_cap3_mig] supabase/tests/capture_notifications_0112_migration.sh
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
export PGHOST="${PGHOST:?set PGHOST to the local postgres socket dir/host}"
PGUSER="${PGUSER:-postgres}"; DB="${DB:-qirsh_cap3_mig}"
P=(psql -U "$PGUSER" -v ON_ERROR_STOP=1 -q -t -A)
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
fail=0
check() { if [ "$2" = "$3" ]; then echo "PASS $1"; else echo "FAIL $1 (got '$2', want '$3')"; fail=1; fi; }
q() { "${P[@]}" -d "$DB" -c "$1"; }

apply 1 111 || exit 1
q "insert into capture_devices (install_id_hash, device_secret_hash) values ('dm', 's');
   insert into notification_logs (id, install_id, notification_type) values ('00000000-0000-0000-0000-0000000000a1', 'abc', 'new_transaction');
   insert into notification_retry_queue (id, notification_log_id, install_id_hash, payload_id, resolved_at, created_at) values
     ('00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-0000000000a1', 'dm', 'p', now(), now() - interval '2 hours'),
     ('00000000-0000-0000-0000-0000000000b2', '00000000-0000-0000-0000-0000000000a1', 'dm', 'p', null, now() - interval '1 hour'),
     ('00000000-0000-0000-0000-0000000000b3', '00000000-0000-0000-0000-0000000000a1', 'dm', 'p', null, now());
   insert into processed_captures (payload_id, install_id_hash, status, state, notification_log_id) values ('old', 'dm', 'processed', 'processed', '00000000-0000-0000-0000-0000000000a1'),
     ('fresh', 'dm', 'processed', 'processed', null);" >/dev/null || exit 1
apply 112 112 || exit 1
check "duplicates collapsed to one retry row" "$(q "select count(*) from notification_retry_queue")" 1
check "the newest unresolved row survives" "$(q "select id from notification_retry_queue")" 00000000-0000-0000-0000-0000000000b3
check "install_id_hash backfilled (sha256 first 32 hex of 'abc')" "$(q "select install_id_hash from notification_logs")" ba7816bf8f01cfea414140de5dae2223
check "pre-existing hand-off backfilled (never re-pushed)" "$(q "select push_attempted_at is not null from processed_captures where payload_id='old'")" t
check "row with no hand-off left NULL" "$(q "select push_attempted_at is null from processed_captures where payload_id='fresh'")" t
check "UNIQUE enforced" "$(q "insert into notification_retry_queue (notification_log_id, install_id_hash, payload_id) values ('00000000-0000-0000-0000-0000000000a1','dm','p') on conflict (notification_log_id) do nothing; select count(*) from notification_retry_queue" | tail -1)" 1

( cd "$ROOT" && "${P[@]}" -d "$DB" -f supabase/rollback/0112_capture_notifications_retention_rollback.sql >/dev/null 2>"$DB.err" ) || { echo "FAIL rollback"; cat "$DB.err"; fail=1; }
check "rollback drops capture_retry_fence" "$(q "select count(*) from pg_proc where proname='capture_retry_fence'")" 0
check "rollback drops push_attempted_at" "$(q "select count(*) from information_schema.columns where column_name='push_attempted_at'")" 0
check "rollback drops install_id_hash" "$(q "select count(*) from information_schema.columns where table_name='notification_logs' and column_name='install_id_hash'")" 0
check "rollback restores the daily prune job" "$(q "select count(*) from cron.job where jobname='prune-processed-captures-daily'")" 1
check "rollback removes the unique constraint" "$(q "select count(*) from pg_constraint where conname='notification_retry_queue_notification_log_id_key'")" 0
check "rollback restores 0111 capture_row_json (no push_attempted_at)" "$(q "select pg_get_functiondef('public.capture_row_json(public.processed_captures)'::regprocedure) like '%push_attempted_at%'")" f
apply 112 112 || { echo "FAIL re-apply 0112"; fail=1; }
check "re-apply restores capture_retry_fence" "$(q "select count(*) from pg_proc where proname='capture_retry_fence'")" 1
rm -f "$DB.err"
exit $fail
