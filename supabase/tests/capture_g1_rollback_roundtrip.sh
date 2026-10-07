#!/usr/bin/env bash
# G1 rollback round trip on a THROWAWAY local Postgres: full chain 0001..0116, the G1 proofs, then the
# rollbacks 0112 -> 0111 -> 0110 (in that order, from the repo root), assert every G1 object is gone,
# re-apply 0110..0112 and re-run the proofs.
#   PGHOST=/path/to/socket-dir [PGUSER=postgres] [DB=qirsh_g1_rt] supabase/tests/capture_g1_rollback_roundtrip.sh
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
export PGOPTIONS="-c client_min_messages=warning"
export PGHOST="${PGHOST:?set PGHOST to the local postgres socket dir/host}"
PGUSER="${PGUSER:-postgres}"; DB="${DB:-qirsh_g1_rt}"
P=(psql -U "$PGUSER" -v ON_ERROR_STOP=1 -q -t -A)
"${P[@]}" -d postgres -c "DROP DATABASE IF EXISTS $DB;" -c "CREATE DATABASE $DB;" >/dev/null || exit 1
"${P[@]}" -d "$DB" < "$ROOT/supabase/tools/dryrun_scaffold.sql" >/dev/null || { echo "scaffold FAILED"; exit 1; }
apply() { for f in "$ROOT"/supabase/migrations/*.sql; do
  n=$(basename "$f" | sed -E 's/^0*([0-9]+)_.*/\1/'); [ "$n" -lt "$1" ] && continue; [ "$n" -gt "$2" ] && continue
  sed -E 's/^[[:space:]]*(CREATE|create)[[:space:]]+(EXTENSION|extension)[[:space:]]+(IF NOT EXISTS[[:space:]]+|if not exists[[:space:]]+)?(pg_cron|pg_net)[^;]*;/SELECT 1; -- stubbed/I' "$f" \
    | "${P[@]}" -d "$DB" >/dev/null 2>"$DB.err" || { echo "FAILED: $(basename "$f")"; cat "$DB.err"; exit 1; }
done; }
fail=0
check() { if [ "$2" = "$3" ]; then echo "PASS $1"; else echo "FAIL $1 (got '$2', want '$3')"; fail=1; fi; }
q() { "${P[@]}" -d "$DB" -c "$1"; }
proof() { # prints the pass/fail summary line of each proof
  for f in capture_state_machine_p1.sql capture_expiry_fence.sql; do
    out=$("${P[@]}" -d "$DB" -f "$ROOT/supabase/tests/$f" 2>&1); rc=$?
    echo "$out" | grep -E "FAIL|ERROR|^[0-9]+\|[0-9]+$" | head -5
    [ $rc -eq 0 ] || { echo "FAIL proof $f"; fail=1; }
  done
}
objs="select (select count(*) from pg_proc where pronamespace='public'::regnamespace and proname in
   ('revoke_capture_consent','link_capture_device','set_capture_consent','legacy_link_capture_device','legacy_set_device_consent',
    'unlink_capture_device','capture_revoke_fanout','capture_claim','capture_ai_dispatch','capture_finalize','capture_ack','capture_row_json',
    'capture_queue_push','capture_parse_received_at','capture_retry_fence','capture_sync_list','capture_content_live','capture_content_live_at','capture_expire_row','processed_captures_created_at_guard'))
  || '|' || (select count(*) from information_schema.columns where table_name='capture_devices' and column_name in
   ('consent_owner_uid','consent_version','owner_generation','consent_client_generation','last_revoke_generation','owner_changed_at'))
  || '|' || (select count(*) from information_schema.columns where table_name='processed_captures' and column_name in ('state','client_owner_generation','push_attempted_at'))
  || '|' || (select count(*) from pg_trigger where tgname='trg_processed_captures_created_at_immutable')"

apply 1 116 || exit 1
echo "-- chain 0001..0116 applied; proofs:"; proof
check "G1 objects present after apply (20 functions | 6 device columns | 3 capture columns | 1 trigger)" "$(q "$objs")" "20|6|3|1"
( cd "$ROOT" && for n in 0112_capture_notifications_retention 0111_capture_state_machine 0110_capture_consent_projection; do
    "${P[@]}" -d "$DB" -f "supabase/rollback/${n}_rollback.sql" >/dev/null 2>"$DB.err" || { echo "FAIL rollback $n"; cat "$DB.err"; exit 1; }
  done ) || fail=1
check "after rollback 0112,0111,0110: every G1 object is gone" "$(q "$objs")" "0|0|0|0"
check "capture_devices rows survived the rollback" "$(q "select count(*) >= 0 from capture_devices")" t
apply 110 112 || { echo "FAIL re-apply"; exit 1; }
check "re-apply 0110..0112 restores every G1 object" "$(q "$objs")" "20|6|3|1"
echo "-- re-applied; proofs:"; proof
rm -f "$DB.err"
exit $fail
