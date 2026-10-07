#!/usr/bin/env bash
# Stages a THROWAWAY local Postgres (chain 0001..0111), snapshots the 0111 capture RPCs
# (bodies + ACLs), applies 0112, runs capture_expiry_fence.sql, applies the 0112 rollback
# and asserts the capture RPCs are EXACTLY the 0111 snapshot and the F1 fence objects are
# gone, then re-applies 0112 and re-runs the proof.
#   PGHOST=/path/to/socket-dir [DB=qirsh_expiry_fence] supabase/tests/capture_expiry_fence.sh
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
export PGOPTIONS="-c client_min_messages=warning"
export PGHOST="${PGHOST:?set PGHOST to the local postgres socket dir/host}"
DB="${DB:-qirsh_expiry_fence}"
P=(psql -U "${PGUSER:-postgres}" -v ON_ERROR_STOP=1 -q)
"${P[@]}" -d postgres -c "DROP DATABASE IF EXISTS $DB;" -c "CREATE DATABASE $DB;" >/dev/null || exit 1
"${P[@]}" -d "$DB" < "$ROOT/supabase/tools/dryrun_scaffold.sql" >/dev/null || { echo "scaffold FAILED"; exit 1; }
apply() { for f in "$ROOT"/supabase/migrations/*.sql; do
  n=$(basename "$f" | sed -E 's/^0*([0-9]+)_.*/\1/'); [ "$n" -lt "$1" ] && continue; [ "$n" -gt "$2" ] && continue
  sed -E 's/^[[:space:]]*(CREATE|create)[[:space:]]+(EXTENSION|extension)[[:space:]]+(IF NOT EXISTS[[:space:]]+|if not exists[[:space:]]+)?(pg_cron|pg_net)[^;]*;/SELECT 1; -- stubbed/I' "$f" \
    | "${P[@]}" -d "$DB" >/dev/null || { echo "FAILED: $(basename "$f")"; exit 1; }
done; }
snap() { "${P[@]}" -d "$DB" -Atc "select p.oid::regprocedure::text, md5(pg_get_functiondef(p.oid)), p.provolatile, p.proacl::text from pg_proc p where p.oid in (
  'public.capture_claim(text,text,text,text,uuid,integer,integer,bigint)'::regprocedure, 'public.capture_ai_dispatch(text,text,integer)'::regprocedure,
  'public.capture_finalize(text,text,text,integer,text,text,jsonb,jsonb,text,text,boolean,jsonb)'::regprocedure,
  'public.capture_ack(text,uuid,text[])'::regprocedure) order by 1;"; }
run_proof() { "${P[@]}" -d "$DB" -f "$ROOT/supabase/tests/capture_expiry_fence.sql" | grep -E "^ \[|FAIL|passed|ERROR|^ +[0-9]+ +\|"; [ "${PIPESTATUS[0]}" -eq 0 ]; }
apply 1 111 || exit 1
snap > "$DB.before"
apply 112 112 || exit 1
run_proof || { rm -f "$DB".before; exit 1; }
( cd "$ROOT" && "${P[@]}" -d "$DB" -f supabase/rollback/0112_capture_notifications_retention_rollback.sql >/dev/null ) || { echo "ROLLBACK FAILED"; exit 1; }
snap > "$DB.after"
gone=$("${P[@]}" -d "$DB" -Atc "select count(*) from pg_proc where proname in ('capture_content_live','capture_content_live_at','capture_expire_row','capture_sync_list','processed_captures_created_at_guard')")
trg=$("${P[@]}" -d "$DB" -Atc "select count(*) from pg_trigger where tgname = 'trg_processed_captures_created_at_immutable'")
if diff -q "$DB.before" "$DB.after" >/dev/null && [ "$gone" = 0 ] && [ "$trg" = 0 ]; then
  echo "rollback round trip OK: capture RPCs identical to the 0111 snapshot, fence objects and the created_at guard dropped"
else echo "ROLLBACK ROUND TRIP FAILED (fence objects left: $gone)"; diff "$DB.before" "$DB.after" | head -20; rm -f "$DB".before "$DB".after; exit 1; fi
rm -f "$DB.before" "$DB.after"
apply 112 112 || exit 1; echo "0112 re-applied after rollback OK"
run_proof || exit 1
