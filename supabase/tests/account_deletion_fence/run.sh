#!/usr/bin/env bash
# run.sh — provisions a DISPOSABLE local stack and runs one harness phase.
# NOT EXECUTED by its author. Nothing here is approved to run: it starts Docker
# containers via the Supabase CLI, which the owner has not authorised.
#
# Usage: run.sh --runtime-dir <absolute new dir> --phase baseline|apply|concurrency|rollback|teardown
set -euo pipefail

RUNTIME_DIR=""
PHASE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --runtime-dir) RUNTIME_DIR="${2:-}"; shift 2 ;;
    --phase) PHASE="${2:-}"; shift 2 ;;
    *) echo "run: unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -n "$RUNTIME_DIR" ] && [ -n "$PHASE" ] || { echo "run: --runtime-dir and --phase are required" >&2; exit 2; }

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$HERE/../../.." && pwd -P)"
PREFLIGHT="$HERE/preflight.sh"
TOKEN="$(basename "$RUNTIME_DIR")"
PROJECT_ID="qirsh-fence-${TOKEN}"

# Ports are derived from the token so two runs cannot collide; all binds are loopback.
PORT_BASE=$(( 55000 + $(printf '%s' "$TOKEN" | cksum | cut -d' ' -f1) % 3000 * 10 ))
DB_PORT=$((PORT_BASE + 1)); API_PORT=$((PORT_BASE + 2)); STUDIO_PORT=$((PORT_BASE + 3))
export FENCE_DB_URL="postgresql://postgres:postgres@127.0.0.1:${DB_PORT}/postgres"
export FENCE_API_URL="http://127.0.0.1:${API_PORT}"

in_runtime() { ( cd "$RUNTIME_DIR" && "$@" ); }

provision() {
  bash "$PREFLIGHT" --runtime-dir "$RUNTIME_DIR"
  mkdir -p "$RUNTIME_DIR/supabase"
  # UNMODIFIED current migrations (copied, never edited). The drafts are NOT here.
  cp -R "$REPO_ROOT/supabase/migrations" "$RUNTIME_DIR/supabase/migrations"
  # Task-specific config derived from a COPY of the tracked one: project id and
  # ports replaced, nothing else. The tracked config.toml is never edited.
  sed -e "s/^project_id = .*/project_id = \"${PROJECT_ID}\"/" \
      -e "s/^port = 54321$/port = ${API_PORT}/" \
      -e "s/^port = 54322$/port = ${DB_PORT}/" \
      -e "s/^port = 54323$/port = ${STUDIO_PORT}/" \
      "$REPO_ROOT/supabase/config.toml" > "$RUNTIME_DIR/supabase/config.toml"
  printf 'project_id=%s\n' "$PROJECT_ID" > "$RUNTIME_DIR/.qirsh-fence-runtime"
  in_runtime supabase start --workdir "$RUNTIME_DIR"
  bash "$PREFLIGHT" --runtime-dir "$RUNTIME_DIR" --post-start
}

require_runtime() {
  bash "$PREFLIGHT" --runtime-dir "$RUNTIME_DIR" --post-start
}

psql_file() { psql -X -v ON_ERROR_STOP=1 "$FENCE_DB_URL" -f "$1"; }

case "$PHASE" in
  baseline)
    [ -e "$RUNTIME_DIR" ] || provision
    require_runtime
    psql_file "$HERE/baseline.sql"
    ;;
  apply)
    require_runtime
    # Only the disposable database receives the draft.
    psql_file "$REPO_ROOT/supabase/drafts/account_deletion_fence/fence.sql"
    psql_file "$HERE/acl.sql"
    ;;
  concurrency)
    require_runtime
    ( cd "$REPO_ROOT" && deno test --allow-run --allow-env --allow-net=127.0.0.1,localhost \
        "$HERE/concurrency_test.ts" )
    ;;
  rollback)
    require_runtime
    psql_file "$REPO_ROOT/supabase/drafts/account_deletion_fence/rollback.sql"
    psql_file "$HERE/baseline.sql"
    ;;
  teardown)
    [ -f "$RUNTIME_DIR/.qirsh-fence-runtime" ] || { echo "teardown refused: no harness marker" >&2; exit 1; }
    grep -qx "project_id=${PROJECT_ID}" "$RUNTIME_DIR/.qirsh-fence-runtime" || { echo "teardown refused: marker mismatch" >&2; exit 1; }
    in_runtime supabase stop --no-backup --workdir "$RUNTIME_DIR"
    rm -rf -- "$RUNTIME_DIR"
    ;;
  *)
    echo "run: unknown phase: $PHASE" >&2
    exit 2
    ;;
esac
