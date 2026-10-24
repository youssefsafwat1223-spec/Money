#!/usr/bin/env bash
# preflight.sh — READ-ONLY safety gate for the account_deletion_fence harness.
# NOT EXECUTED by its author. Starts nothing, writes nothing, reads no
# credentials and no .env. Exit 0 only when every check passes.
#
# Usage:
#   preflight.sh --runtime-dir <absolute new dir> [--post-start]
# Env (post-start only, loopback only): FENCE_DB_URL FENCE_API_URL
set -euo pipefail

RUNTIME_DIR=""
POST_START=0
while [ $# -gt 0 ]; do
  case "$1" in
    --runtime-dir) RUNTIME_DIR="${2:-}"; shift 2 ;;
    --post-start) POST_START=1; shift ;;
    *) echo "preflight: unknown argument: $1" >&2; exit 2 ;;
  esac
done

fail() { echo "PREFLIGHT REFUSED: $*" >&2; exit 1; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"

[ -n "$RUNTIME_DIR" ] || fail "--runtime-dir is required"
case "$RUNTIME_DIR" in /*) ;; *) fail "--runtime-dir must be an absolute path" ;; esac
case "$RUNTIME_DIR" in
  "$REPO_ROOT"|"$REPO_ROOT"/*) fail "runtime dir must be outside the repository" ;;
esac
case "$RUNTIME_DIR" in
  *..*) fail "runtime dir must not contain '..'" ;;
esac

# Loopback-only: accepts 127.0.0.1, localhost, [::1] (with optional port/path); nothing else.
is_loopback_url() {
  local url="$1" host
  host="${url#*://}"; host="${host%%/*}"; host="${host#*@}"
  case "$host" in
    127.0.0.1|127.0.0.1:*|localhost|localhost:*|\[::1\]|\[::1\]:*) return 0 ;;
    *) return 1 ;;
  esac
}

if [ "$POST_START" -eq 0 ]; then
  # Pre-start: the directory must be new (or empty) and there must be no
  # leftover or linked project state anywhere we might touch.
  if [ -e "$RUNTIME_DIR" ] && [ -n "$(ls -A "$RUNTIME_DIR" 2>/dev/null || true)" ]; then
    [ -f "$RUNTIME_DIR/.qirsh-fence-runtime" ] || fail "runtime dir exists, is not empty and has no harness marker (shared/pre-existing resource)"
    fail "runtime dir already provisioned; choose a NEW directory per run"
  fi
  [ ! -e "$REPO_ROOT/supabase/.temp/project-ref" ] || fail "repository supabase/ is linked to a project (.temp/project-ref); refuse"
  [ ! -e "$RUNTIME_DIR/supabase/.temp/project-ref" ] || fail "runtime dir carries linked-project state"

  for tool in supabase docker deno psql curl; do
    command -v "$tool" >/dev/null 2>&1 || fail "required tool missing: $tool"
  done
  docker info >/dev/null 2>&1 || fail "docker daemon is not reachable (do not substitute a hosted environment)"

  # No pre-existing/shared containers for this task's project id.
  token="$(basename "$RUNTIME_DIR")"
  [ -z "$(docker ps -a --format '{{.Names}}' | grep -E "_qirsh-fence-${token}\$" || true)" ] \
    || fail "containers for project qirsh-fence-${token} already exist"
  # The default project id used by the developer stack must not be reused.
  [ "$token" != "Money" ] && [ "$token" != "supabase" ] || fail "runtime dir name collides with a default project id"
  echo "preflight (pre-start): OK"
  exit 0
fi

# Post-start: prove loopback + marker + real capabilities.
[ -f "$RUNTIME_DIR/.qirsh-fence-runtime" ] || fail "missing unique project marker file"
marker_project="$(sed -n 's/^project_id=//p' "$RUNTIME_DIR/.qirsh-fence-runtime")"
case "$marker_project" in qirsh-fence-*) ;; *) fail "marker has no qirsh-fence-* project id" ;; esac
grep -qx "project_id = \"${marker_project}\"" "$RUNTIME_DIR/supabase/config.toml" \
  || fail "runtime config.toml project_id does not match the marker"

: "${FENCE_DB_URL:?FENCE_DB_URL is required}"
: "${FENCE_API_URL:?FENCE_API_URL is required}"
is_loopback_url "$FENCE_DB_URL"  || fail "FENCE_DB_URL is not loopback"
is_loopback_url "$FENCE_API_URL" || fail "FENCE_API_URL is not loopback"

# Real capability probes (loopback only).
curl -fsS --max-time 5 "$FENCE_API_URL/auth/v1/health"    >/dev/null || fail "Auth (GoTrue) not reachable"
curl -fsS --max-time 5 -o /dev/null -w '%{http_code}' "$FENCE_API_URL/rest/v1/" | grep -qE '^(200|401)$' || fail "PostgREST not reachable"
curl -sS  --max-time 5 -o /dev/null -w '%{http_code}' "$FENCE_API_URL/storage/v1/version" | grep -qE '^(200|401|404)$' || fail "Storage API not reachable"

psql -X -q -A -t "$FENCE_DB_URL" -v ON_ERROR_STOP=1 -c "select 1 from auth.users limit 0; select 1 from storage.objects limit 0;" >/dev/null \
  || fail "auth/storage schemas not present (real stack required, no stand-ins)"
for ext in pgcrypto; do
  psql -X -q -A -t "$FENCE_DB_URL" -c "select 1 from pg_extension where extname='${ext}'" | grep -q 1 \
    || fail "extension missing: ${ext}"
done
# The local default superuser database must be disposable: refuse a DB that
# already contains the fence or someone else's schemas.
psql -X -q -A -t "$FENCE_DB_URL" -c "select count(*) from pg_namespace where nspname in ('account_fence','account_fence_impl')" | grep -qx 0 \
  || fail "fence schemas already exist in this database"

echo "preflight (post-start): OK"
