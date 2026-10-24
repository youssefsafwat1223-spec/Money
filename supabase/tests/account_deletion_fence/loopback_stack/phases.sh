#!/bin/bash
# Runs qualification phases against a stack started by up.sh (explicitly owner-approved loopback runtime path;
# run.sh / preflight.sh remain refusal gates and are not used). Connection values are read from the private
# test.env in <rundir> and never printed.
# Usage: phases.sh <rundir> migrate|baseline-pre|apply|acl|concurrency|drain|rollback|baseline-post|compare|all
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tests="$(cd "$here/.." && pwd)"
repo="$(cd "$here/../../../.." && pwd)"
rundir="${1:?usage: phases.sh <rundir> <phase>}"; phase="${2:?phase}"
set -a; . "$rundir/test.env"; set +a
case "$FENCE_DB_URL" in postgres://postgres:*@127.0.0.1:*) ;; *) echo "phases: refusing non-loopback DB URL" >&2; exit 2;; esac
psqlx() { psql -X -q -v ON_ERROR_STOP=1 "$FENCE_DB_URL" "$@"; }
case "$phase" in
  migrate)
    for f in $(ls "$repo"/supabase/migrations/*.sql | LC_ALL=C sort); do
      psqlx -f "$f" >/dev/null 2>"$rundir/migrate.err" || { echo "MIGRATION FAILED: $(basename "$f")" >&2; sed -n 1,10p "$rundir/migrate.err" >&2; exit 1; }
    done
    echo "migrate: $(ls "$repo"/supabase/migrations/*.sql | wc -l | tr -d ' ') migrations applied" ;;
  baseline-pre)  psqlx -f "$tests/baseline.sql" > "$rundir/baseline_pre.txt" 2>&1; echo "baseline-pre: $(wc -l < "$rundir/baseline_pre.txt") lines" ;;
  apply)         psqlx -f "$repo/supabase/drafts/account_deletion_fence/fence.sql" ;;
  acl)           psqlx -f "$tests/acl.sql" ;;
  concurrency)   cd "$tests" && deno test --cached-only --no-check --allow-env --allow-run --allow-net concurrency_test.ts ;;
  drain)         "$here/drain.sh" "$rundir" ;;
  rollback)      psqlx -f "$repo/supabase/drafts/account_deletion_fence/rollback.sql" ;;
  baseline-post) psqlx -f "$tests/baseline.sql" > "$rundir/baseline_post.txt" 2>&1; echo "baseline-post: $(wc -l < "$rundir/baseline_post.txt") lines" ;;
  compare)       diff "$rundir/baseline_pre.txt" "$rundir/baseline_post.txt" && echo "compare: post-rollback baseline identical to pre-fence baseline" ;;
  all) for p in migrate baseline-pre apply acl concurrency drain rollback baseline-post compare; do echo "== $p"; "$0" "$rundir" "$p"; done ;;
  *) echo "phases: unknown phase" >&2; exit 2;;
esac
