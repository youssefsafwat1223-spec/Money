#!/usr/bin/env bash
# D.10: a LOCK WAIT that spans the exact 168 h expiry boundary, with REAL concurrent psql sessions
# (committed data, cleaned up afterwards). Style of capture_concurrency_p1.sh / sync_seq_concurrency_t25.sh.
#   PGHOST=<socket dir> PGUSER=postgres PGDATABASE=<db> bash supabase/tests/capture_expiry_lock_wait_p10.sh
# Needs 0001..0112 applied on a LOCAL throwaway DB.
#
# Each scenario seeds rows whose created_at puts the boundary AHEAD seconds in the future, then:
#   session 1 takes the device lock (or the row lock) and holds it past the boundary (pg_sleep);
#   session 2 starts BEFORE the boundary, blocks on that lock, and only gets it AFTER the boundary.
# The capture RPC must judge the fence with clock_timestamp() at that point (after its locks) and refuse.
# Each session-2 transaction also records whether the boundary really fell inside its wait
# (before_ok / after_ok) and what a now()-based predicate would have said (now_allows = true).
# NEGATIVE CONTROL: the predicate is swapped for the old now()-based body; the very same scenarios then
# AUTHORISE (finalize writes, AI starts, push hand-off), proving the proof would catch a regression.
set -euo pipefail
P="psql -v ON_ERROR_STOP=1 -qAt"
U=00000000-0000-0000-0000-0000000e1001
AHEAD=3      # boundary this many seconds after the seed
HOLD=5       # session 1 holds its lock this long (> AHEAD)
fails=0
tmp=$(mktemp -d)
orig=$($P -c "select pg_get_functiondef('public.capture_content_live(timestamptz)'::regprocedure)")
restore() { $P -c "$orig" >/dev/null 2>&1 || true; }
cleanup() {
  restore
  rm -rf "$tmp"
  $P -c "delete from public.notification_logs where install_id_hash='lw'" \
     -c "delete from public.processed_captures where install_id_hash='lw'" \
     -c "delete from public.capture_devices where install_id_hash='lw'" \
     -c "delete from auth.users where id='$U'" >/dev/null 2>&1 || true
}
trap cleanup EXIT
$P -c "insert into auth.users(id) values ('$U') on conflict do nothing" \
   -c "insert into public.capture_devices(install_id_hash,device_secret_hash,user_id,consent_owner_uid,cloud_processing_enabled,ai_consent_granted,consent_version,apns_token,apns_environment)
       values ('lw','s','$U','$U',true,true,1,'tok','sandbox') on conflict do nothing" >/dev/null

seed() { # payload state  (boundary AHEAD seconds from now)
  $P -v p="$1" -v st="$2" -v ahead="$AHEAD" -v u="$U" >/dev/null <<'SQL'
insert into public.processed_captures
  (payload_id, install_id_hash, claimed_user_id, status, state, parsed, notification, sanitized_text, raw_fingerprint,
   lease_until, lease_token, attempts, owner_uid, consent_owner_uid, consent_version, created_at)
values (:'p', 'lw', :'u', case when :'st' = 'processing' then 'rejected' else 'processed' end, :'st',
        case when :'st' = 'processing' then '{}'::jsonb else '{"amount":10}'::jsonb end,
        case when :'st' = 'processing' then '{}'::jsonb else '{"title":"t","body":"b","type":"new_transaction"}'::jsonb end,
        null, 'fp-' || :'p',
        case when :'st' = 'processing' then clock_timestamp() + interval '600 seconds' end, 1, 1, :'u', :'u', 1,
        clock_timestamp() - interval '168 hours' + make_interval(secs => :ahead));
SQL
}
holder() { # kind payload : session 1, holds the lock across the boundary
  if [ "$1" = device ]; then
    $P <<SQL >/dev/null &
begin; select 1 from public.capture_devices where install_id_hash='lw' for update; select pg_sleep($HOLD); commit;
SQL
  else
    $P <<SQL >/dev/null &
begin; select 1 from public.processed_captures where install_id_hash='lw' and payload_id='$2' for update; select pg_sleep($HOLD); commit;
SQL
  fi
}
waiter() { # name payload rpc-expression-returning-text : session 2, starts before the boundary, blocks, then reports
  $P -v p="$2" > "$tmp/$1" <<SQL &
begin;
select clock_timestamp() as t0 \gset
select coalesce(($3), 'null') as res \gset
select clock_timestamp() as t1 \gset
select '$1' || '|' || :'res'
    || '|' || (c + interval '168 hours' > :'t0'::timestamptz)::text          -- boundary was still ahead when the wait began
    || '|' || (c + interval '168 hours' <= :'t1'::timestamptz)::text         -- ...and behind us when the lock was granted
    || '|' || (now() < c + interval '168 hours')::text                       -- what a now()-based predicate would say
  from (select created_at c from public.processed_captures where install_id_hash='lw' and payload_id=:'p') x;
commit;
SQL
}
FIN="public.capture_finalize('lw','raw-lw',:'p',1,'processed','processed','{\"amount\":99}'::jsonb,'{\"title\":\"t\",\"body\":\"b\",\"type\":\"new_transaction\"}'::jsonb,null,null,false,null)"
check() { # name expected-res expected-written-state
  local line; line=$(cat "$tmp/$1")
  IFS='|' read -r n res before after nowallows <<<"$line"
  if [ "$res" = "$2" ] && [ "$before" = true ] && [ "$after" = true ] && [ "$nowallows" = true ]; then echo "PASS $1: $res (boundary inside the wait; a now()-based predicate would have allowed)"
  else echo "FAIL $1: got '$line' want res=$2 before=t after=t now_allows=t"; fails=1; fi
}
sqlval() { $P -c "$1"; }

# ── 1. device lock held across the boundary; finalize waits on it ─────────────────────────────────
seed lwf processing
holder device x; sleep 1
waiter finalize_dev lwf "$FIN->>'reason'"
wait
check finalize_dev expired
r=$(sqlval "select state||'|'||(parsed='{}'::jsonb)||'|'||coalesce(push_attempted_at::text,'none') from public.processed_captures where install_id_hash='lw' and payload_id='lwf'")
[ "$r" = "expired|true|none" ] && echo "PASS finalize_dev: nothing stored, no push attempt, row nulled" || { echo "FAIL finalize_dev state: $r"; fails=1; }
[ "$(sqlval "select count(*) from public.notification_logs where install_id_hash='lw' and related_entity_id='lwf'")" = 0 ] || { echo "FAIL finalize_dev: notification row exists"; fails=1; }

# ── 2. row locks held across the boundary; dispatch / queue_push / retry fence / claim wait on them ──
seed lwd processing; seed lwq processed; seed lwr processed; seed lwc processed
holder row lwd; holder row lwq; holder row lwr; holder row lwc; sleep 1
waiter dispatch_row lwd "public.capture_ai_dispatch('lw',:'p',1)->>'reason'"
waiter pushq_row lwq "(public.capture_queue_push('lw','raw-lw',:'p','$U','new_transaction'))::text"
waiter retry_row lwr "public.capture_retry_fence('lw',:'p')->>'reason'"
waiter claim_row lwc "public.capture_claim('lw','raw-lw',:'p','fp-lwc','$U',2,60)->'row'->>'state'"
wait
check dispatch_row expired
check pushq_row null
check retry_row expired
check claim_row expired
r=$(sqlval "select (ai_started_at is null)||'|'||(not ai_invoked)||'|'||state from public.processed_captures where install_id_hash='lw' and payload_id='lwd'")
[ "$r" = "true|true|expired" ] && echo "PASS dispatch_row: AI never started (no ai_started_at)" || { echo "FAIL dispatch_row state: $r"; fails=1; }
[ "$(sqlval "select count(*) from public.notification_logs where install_id_hash='lw' and related_entity_id in ('lwq','lwr','lwc')")" = 0 ] \
  && echo "PASS push paths: no notification log for the queue_push / retry / claim waiters" || { echo "FAIL: notification log written after expiry"; fails=1; }

# ── NEGATIVE CONTROL: the old now()-based predicate authorises the same scenarios ─────────────────
$P -c "create or replace function public.capture_content_live(p_created_at timestamptz) returns boolean language sql volatile
       set search_path = public, pg_temp as \$f\$ select p_created_at is not null and now() < p_created_at + interval '168 hours' \$f\$" >/dev/null
seed ctlf processing; seed ctld processing; seed ctlq processed
holder device x; sleep 1
waiter ctl_finalize ctlf "$FIN->>'written'"
waiter ctl_dispatch ctld "public.capture_ai_dispatch('lw',:'p',1)->>'allowed'"
waiter ctl_pushq ctlq "(public.capture_queue_push('lw','raw-lw',:'p','$U','new_transaction') is not null)::text"
wait
restore
for n in ctl_finalize ctl_dispatch ctl_pushq; do
  IFS='|' read -r nn res before after nowallows <<<"$(cat "$tmp/$n")"
  if [ "$res" = true ] && [ "$before" = true ] && [ "$after" = true ]; then echo "PASS control $n: with a now()-based predicate the boundary-crossing request WAS authorised ($res), as the proof expects"
  else echo "FAIL control $n: '$(cat "$tmp/$n")'"; fails=1; fi
done
# the predicate is restored: the same scenario refuses again
seed rstf processing
holder device x; sleep 1
waiter restored rstf "$FIN->>'reason'"
wait
check restored expired
[ "$fails" = 0 ] && echo "PASS D.10 lock-wait expiry (real concurrent sessions)" || { echo "FAIL D.10"; exit 1; }
