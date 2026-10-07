#!/usr/bin/env bash
# T25 - concurrent same-user commits on two sessions: commit order == sync_seq
# order and a reader never observes a hole (cursor never skips).
#
# Needs a LOCAL throwaway Postgres already migrated through 0105 (e.g. the DB that
# sync_foundation_0103_0114.sh leaves behind). Uses real concurrent psql sessions;
# it creates two scratch users and deletes them at the end.
#
#   PGHOST=/path/to/socket-dir [PGUSER=postgres] DB=qirsh_sync_proof \
#     supabase/tests/sync_seq_concurrency_t25.sh
#
# Part 1 (deterministic): session A inserts and HOLDS its transaction open for 3 s;
#   session B (same user) starts 1 s later. B must block on the per-user lock,
#   finish only after A commits, and receive the larger sync_seq.
# Part 2 (stress): two writer sessions each commit 150 single-row transactions for
#   the same user while a reader samples the table every ~20 ms. Every sample must
#   be a gap-free run of sync_seq (a lock-free counter would show seq n+1 committed
#   before seq n), and all 300 sync_seq values must be unique and dense.
set -uo pipefail
export PGHOST="${PGHOST:?set PGHOST to the local postgres socket dir/host}"
PGUSER="${PGUSER:-postgres}"; DB="${DB:?set DB to the migrated database}"
Q() { psql -U "$PGUSER" -d "$DB" -v ON_ERROR_STOP=1 -qAt "$@"; }
U1=00000000-0000-0000-0000-0000000000e1
U2=00000000-0000-0000-0000-0000000000e2
fail=0
cleanup() { Q -c "DELETE FROM auth.users WHERE id IN ('$U1','$U2')" >/dev/null 2>&1; }
trap cleanup EXIT
cleanup
Q -c "INSERT INTO auth.users (id) VALUES ('$U1'), ('$U2')" || exit 1

# ── Part 1: blocking + order ────────────────────────────────────────────────
A_OUT=$(mktemp); B_OUT=$(mktemp)
( Q <<SQL > "$A_OUT"
BEGIN;
INSERT INTO public.user_cards (user_id, local_id, last4) VALUES ('$U1', 'a', '0001') RETURNING sync_seq;
SELECT pg_sleep(3);
COMMIT;
SELECT floor(extract(epoch FROM clock_timestamp()) * 1000)::bigint;
SQL
) &
sleep 1
( Q <<SQL > "$B_OUT"
BEGIN;
INSERT INTO public.user_cards (user_id, local_id, last4) VALUES ('$U1', 'b', '0002') RETURNING sync_seq;
COMMIT;
SELECT floor(extract(epoch FROM clock_timestamp()) * 1000)::bigint;
SQL
) &
wait
a_seq=$(sed -n 1p "$A_OUT" | tr -d '[:space:]'); a_end=$(grep -E '^[0-9]{10,}$' "$A_OUT" | tail -1)
b_seq=$(sed -n 1p "$B_OUT" | tr -d '[:space:]'); b_end=$(grep -E '^[0-9]{10,}$' "$B_OUT" | tail -1)
rm -f "$A_OUT" "$B_OUT"
echo "part 1: A seq=$a_seq (commit at $a_end ms), B seq=$b_seq (finished at $b_end ms)"
if [ -n "$a_seq" ] && [ -n "$b_seq" ] && [ "$a_seq" -lt "$b_seq" ] && [ "$b_end" -ge "$a_end" ]; then
  echo "PASS part 1: B waited for A's commit and drew the larger sync_seq"
else
  echo "FAIL part 1"; fail=1
fi

# ── Part 2: stress with a gap-watching reader ───────────────────────────────
writer() { # tag
  Q -c "DO \$\$ BEGIN FOR i IN 1..150 LOOP
          INSERT INTO public.user_cards (user_id, local_id, last4) VALUES ('$U2', '$1-' || i, '0000');
          COMMIT;
        END LOOP; END \$\$"
}
writer w1 & w1=$!
writer w2 & w2=$!
holes=0; samples=0
while kill -0 "$w1" 2>/dev/null || kill -0 "$w2" 2>/dev/null; do
  ok=$(Q -c "SELECT coalesce(count(*) = max(sync_seq) - min(sync_seq) + 1 AND min(sync_seq) = 1, true) FROM public.user_cards WHERE user_id = '$U2'")
  samples=$((samples + 1)); [ "$ok" = "t" ] || holes=$((holes + 1))
  sleep 0.02
done
wait "$w1" "$w2"
final=$(Q -c "SELECT count(*), count(DISTINCT sync_seq), min(sync_seq), max(sync_seq) FROM public.user_cards WHERE user_id = '$U2'")
head=$(Q -c "SELECT last_seq FROM public.user_sync_state WHERE user_id = '$U2'")
echo "part 2: samples=$samples samples_with_holes=$holes final(count,distinct,min,max)=$final state.last_seq=$head"
if [ "$holes" -eq 0 ] && [ "$final" = "300|300|1|300" ] && [ "$head" = "300" ]; then
  echo "PASS part 2: no reader ever saw a hole; 300 unique dense sync_seq values; head = 300"
else
  echo "FAIL part 2"; fail=1
fi
exit "$fail"
