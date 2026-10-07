#!/usr/bin/env bash
# T-S1 with REAL parallel sessions (committed data, cleaned up afterwards).
# Usage: PGHOST=<socket dir> PGUSER=postgres PGDATABASE=<db> bash supabase/tests/capture_concurrency_p1.sh
# Needs the 0110/0111 chain applied on a LOCAL throwaway DB. 12 sessions claim the same
# payload at once: exactly one 'claimed' (one AI dispatch), the rest 'in_progress'.
set -euo pipefail
P="psql -v ON_ERROR_STOP=1 -qAt"
U=00000000-0000-0000-0000-0000000c0001
$P -c "insert into auth.users(id) values ('$U') on conflict do nothing" \
   -c "insert into public.capture_devices(install_id_hash,device_secret_hash,user_id,consent_owner_uid,cloud_processing_enabled,ai_consent_granted,consent_version)
       values ('conc1','s','$U','$U',true,true,1) on conflict do nothing"
tmp=$(mktemp -d)
cleanup() {
  rm -rf "$tmp"
  $P -c "delete from public.processed_captures where install_id_hash='conc1'" \
     -c "delete from public.capture_devices where install_id_hash='conc1'" \
     -c "delete from auth.users where id='$U'" >/dev/null
}
trap cleanup EXIT
for i in $(seq 1 12); do
  ( $P -c "select public.capture_claim('conc1','raw','pc','fp','$U',2,60)->>'outcome'" > "$tmp/$i" ) &
done
wait
claimed=$(cat "$tmp"/* | grep -c '^claimed$' || true)
inprog=$(cat "$tmp"/* | grep -c '^in_progress$' || true)
rows=$($P -c "select count(*) from public.processed_captures where install_id_hash='conc1'")
echo "claimed=$claimed in_progress=$inprog rows=$rows"
[ "$claimed" = 1 ] && [ "$inprog" = 11 ] && [ "$rows" = 1 ] || { echo "FAIL T-S1 concurrent"; exit 1; }
# only the single lease holder dispatches AI; a repeated dispatch for the same lease is idempotent
for i in $(seq 1 6); do
  ( $P -c "select public.capture_ai_dispatch('conc1','pc',1)->>'allowed'" > "$tmp/d$i" ) &
done
wait
echo "PASS T-S1 concurrent"
