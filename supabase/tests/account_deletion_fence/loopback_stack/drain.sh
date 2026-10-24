#!/bin/bash
# Drives every open deletion job through the full service lifecycle (claim -> apple_revoke -> storage_sweep -> sql_purge ->
# auth_delete via the real Auth admin API -> terminal_storage -> complete_job) so rollback.sql can run on a quiescent
# database. Uses only the public service RPCs. Reads connection values from <rundir>/test.env; prints counts only.
# Usage: drain.sh <rundir>
set -euo pipefail
rundir="${1:?usage: drain.sh <rundir>}"
set -a; . "$rundir/test.env"; set +a
case "$FENCE_DB_URL" in postgres://postgres:*@127.0.0.1:*) ;; *) echo "drain: refusing non-loopback DB URL" >&2; exit 2;; esac
q() { psql -X -q -A -t -v ON_ERROR_STOP=1 "$FENCE_DB_URL" -c "$1"; }
stages=(apple_revoke storage_sweep sql_purge auth_delete terminal_storage)
done_n=0; idle=0
for _ in $(seq 1 400); do
  claim="$(q "select public.account_deletion_claim_lease('drain', 60000, null);")"
  if [ -z "$claim" ]; then
    idle=$((idle+1)); [ $idle -gt 80 ] && break; sleep 1; continue
  fi
  idle=0
  job="$(jq -r .lease.job_id <<<"$claim")"; tok="$(jq -r .lease.token <<<"$claim")"; gen="$(jq -r .lease.generation <<<"$claim")"
  uid="$(jq -r .job.uid <<<"$claim")"; n="$(jq -r '.job.completed_steps|length' <<<"$claim")"
  for ((i=n; i<5; i++)); do
    st="${stages[$i]}"
    r="$(q "select public.account_deletion_begin_step('$job','$tok',$gen,'$st');")"; [ "$(jq -r .ok <<<"$r")" = "true" ] || { echo "drain: begin_step $st refused"; exit 1; }
    case "$st" in
      sql_purge) r="$(q "select public.account_deletion_purge('$job','$tok',$gen);")"; echo "$r" | grep -q done || { echo "drain: purge refused"; exit 1; } ;;
      auth_delete)
        code="$(curl -s -o /dev/null -w '%{http_code}' -X DELETE "$FENCE_API_URL/auth/v1/admin/users/$uid" -H "apikey: $FENCE_SERVICE_KEY" -H "authorization: Bearer $FENCE_SERVICE_KEY")"
        [ "$code" = "200" ] || [ "$code" = "404" ] || { echo "drain: auth delete returned $code"; exit 1; } ;;
    esac
    r="$(q "select public.account_deletion_complete_step('$job','$tok',$gen,'$st');")"
    [ "$(jq -r .ok <<<"$r")" = "true" ] || [ "$st" = "sql_purge" ] || { echo "drain: complete_step $st refused: $(jq -r .reason <<<"$r")"; exit 1; }
  done
  r="$(q "select public.account_deletion_complete_job('$job','$tok',$gen,0);")"; [ "$(jq -r .ok <<<"$r")" = "true" ] || { echo "drain: complete_job refused: $(jq -r .reason <<<"$r")"; exit 1; }
  done_n=$((done_n+1))
done
echo "drain: $done_n jobs completed"
