#!/usr/bin/env bash
# Apply the migration chain to a THROWAWAY LOCAL Postgres and report where it
# stops. Release-prep verification for the exact production execution order.
#
# SAFETY. This never contacts a hosted project, and cannot:
#   * the container runs with `--network none`;
#   * the connection is made with `docker exec`, not over TCP;
#   * the Supabase CLI is not used at all, so the locally-linked project ref
#     (`supabase/.temp/project-ref`) is irrelevant here.
#
# WHAT A GREEN RUN PROVES: every statement parses, every object exists before it
# is referenced, and the numeric filename order is a valid apply order — which
# is the order the owner will run in production.
#
# WHAT IT DOES NOT PROVE: behaviour. `pg_cron`, `pg_net` and `vault` are stubs
# (see dryrun_scaffold.sql), RLS policies compile but are not exercised, and no
# Supabase platform trigger exists. Read a pass as "applies cleanly", not as
# "behaves correctly".
#
# Usage: supabase/tools/dryrun_migrations.sh [container] [first] [last]
set -uo pipefail

CONTAINER="${1:-qirsh-dryrun}"
FIRST="${2:-0000}"
LAST="${3:-9999}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
MIG="$ROOT/supabase/migrations"
DB="qirsh"

psql_run() { docker exec -i "$CONTAINER" psql -U postgres -d "$DB" -v ON_ERROR_STOP=1 -q "$@"; }

docker inspect "$CONTAINER" >/dev/null 2>&1 || { echo "container $CONTAINER not running"; exit 2; }

# Refuse to run against anything with a network — belt and braces on the safety
# claim above, since the whole point is that this cannot reach a hosted project.
nets=$(docker inspect -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}' "$CONTAINER")
if [ "$(echo "$nets" | tr -d '[:space:]')" != "none" ]; then
  echo "REFUSING: container network is '$nets', expected 'none'." >&2
  exit 2
fi

echo "── scaffold ──"
psql_run < "$ROOT/supabase/tools/dryrun_scaffold.sql" || { echo "scaffold FAILED"; exit 1; }
echo "  ok"

echo "── migrations ──"
applied=0; failed=0; first_fail=""
for f in "$MIG"/*.sql; do
  n=$(basename "$f" | sed -E 's/^0*([0-9]+)_.*/\1/')
  [ "$n" -lt "$((10#$FIRST))" ] && continue
  [ "$n" -gt "$((10#$LAST))" ] && continue
  name=$(basename "$f")

  # `CREATE EXTENSION pg_cron|pg_net` cannot succeed on a stock image; the
  # scaffold already provides the surface those extensions expose. Neutralised
  # here rather than edited in the migration, which must stay production-exact.
  out=$(sed -E 's/^[[:space:]]*(CREATE|create)[[:space:]]+(EXTENSION|extension)[[:space:]]+(IF NOT EXISTS[[:space:]]+|if not exists[[:space:]]+)?(pg_cron|pg_net)[^;]*;/SELECT 1; -- stubbed: \4/I' "$f" \
        | docker exec -i "$CONTAINER" psql -U postgres -d "$DB" -v ON_ERROR_STOP=1 -q 2>&1)
  if [ $? -eq 0 ]; then
    applied=$((applied + 1))
  else
    failed=$((failed + 1))
    [ -z "$first_fail" ] && first_fail="$name"
    echo "  ✗ $name"
    echo "$out" | grep -E "^(ERROR|DETAIL|HINT|CONTEXT)" | head -4 | sed 's/^/      /'
  fi
done

echo
echo "applied: $applied   failed: $failed"
[ -n "$first_fail" ] && echo "first failure: $first_fail"
[ "$failed" -eq 0 ] && echo "DRY RUN CLEAN — the chain applies in filename order"
exit "$([ "$failed" -eq 0 ] && echo 0 || echo 1)"
