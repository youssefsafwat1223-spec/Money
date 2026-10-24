#!/bin/bash
# Launches the disposable loopback-only stack (db, auth, rest, storage, kong gateway) with fresh synthetic
# credentials. Never uses the Supabase CLI, never pulls, never publishes a port that is not 127.0.0.1-bound.
# Usage: up.sh            -> prints RUNDIR=<private temp dir> on success (no secrets are printed).
# Env:   QIRSH_FENCE_RUN_BASE  parent directory for the private run dir (default: $TMPDIR or /tmp).
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
compose_file="$here/docker-compose.yml"
project="$(sed -n 's/^name: \(qirsh-fence-[0-9a-f]\{8\}\)$/\1/p' "$compose_file")"
[ -n "$project" ] || { echo "up: cannot read fixed project name" >&2; exit 2; }
case "$project" in *qirsh_beta1_sync_rc5800*|*qirsh_proof*|*frasaaaaa*) echo "up: project name collides with a protected one" >&2; exit 2;; esac

dc_env() { env -i PATH="$PATH" HOME="$HOME" "$@"; }
rundir=""
teardown() { if [ -n "$rundir" ] && [ -f "$rundir/stack.env" ]; then "$here/down.sh" "$rundir" || true; fi; }
fail() { echo "up: $*" >&2; teardown; exit 1; }

# 1. images present locally, no collision with an existing project of the same name
for img in postgres:17.6.1.167 gotrue:v2.197.0 postgrest:v14.5 storage-api:v1.77.5 kong:2.8.1; do
  docker image inspect "public.ecr.aws/supabase/$img" >/dev/null 2>&1 || { echo "up: image missing locally: $img (no pulls allowed)" >&2; exit 1; }
done
if [ -n "$(docker ps -aq --filter "label=com.docker.compose.project=$project")" ]; then
  echo "up: project $project already has containers; run down.sh first" >&2; exit 1
fi

# 2. fresh synthetic credentials in a private dir outside the repo
base="${QIRSH_FENCE_RUN_BASE:-${TMPDIR:-/tmp}}"
rundir="$(mktemp -d "${base%/}/qirsh-fence-run.XXXXXXXX")"
chmod 700 "$rundir"
pick_port() {
  local p tries=0
  while [ $tries -lt 200 ]; do
    p=$((59100 + RANDOM % 100)); tries=$((tries+1))
    case " $* " in *" $p "*) continue;; esac
    if ! lsof -nP -iTCP:"$p" -sTCP:LISTEN >/dev/null 2>&1; then echo "$p"; return 0; fi
  done
  return 1
}
db_port="$(pick_port)" || fail "no free port"
api_port="$(pick_port "$db_port")" || fail "no free port"
umask 077
python3 -I - "$rundir" "$db_port" "$api_port" <<'PY'
import base64, hashlib, hmac, json, os, secrets, sys, time
rundir, db_port, api_port = sys.argv[1:4]
secret = secrets.token_hex(32)
def b64(b): return base64.urlsafe_b64encode(b).rstrip(b"=").decode()
def jwt(role):
    h = b64(json.dumps({"alg": "HS256", "typ": "JWT"}, separators=(",", ":")).encode())
    now = int(time.time())
    p = b64(json.dumps({"role": role, "iss": "supabase-local", "iat": now, "exp": now + 86400}, separators=(",", ":")).encode())
    s = b64(hmac.new(secret.encode(), f"{h}.{p}".encode(), hashlib.sha256).digest())
    return f"{h}.{p}.{s}"
pw = secrets.token_hex(24)
anon, svc = jwt("anon"), jwt("service_role")
fd = os.open(os.path.join(rundir, "stack.env"), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
with os.fdopen(fd, "w") as f:
    f.write(f"POSTGRES_PASSWORD={pw}\nJWT_SECRET={secret}\nANON_KEY={anon}\nSERVICE_ROLE_KEY={svc}\n"
            f"FENCE_DB_PORT={db_port}\nFENCE_API_PORT={api_port}\n")
fd = os.open(os.path.join(rundir, "test.env"), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
with os.fdopen(fd, "w") as f:
    f.write(f"FENCE_DB_URL=postgres://postgres:{pw}@127.0.0.1:{db_port}/postgres\nFENCE_API_URL=http://127.0.0.1:{api_port}\n"
            f"FENCE_SERVICE_KEY={svc}\nFENCE_ANON_KEY={anon}\n")
PY
printf 'PROJECT=%s\nCOMPOSE_FILE=%s\nDB_PORT=%s\nAPI_PORT=%s\n' "$project" "$compose_file" "$db_port" "$api_port" > "$rundir/state"
dc() { dc_env docker compose -p "$project" -f "$compose_file" --env-file "$rundir/stack.env" "$@"; }

# 3. validate the resolved compose model BEFORE launch: every published port is 127.0.0.1-bound
cfg="$(dc config --format json)" || fail "compose config invalid"
printf '%s' "$cfg" | jq -e '
  [.services[] | (.ports // [])[]] as $p
  | ($p | length) == 2 and ($p | all(.host_ip == "127.0.0.1")) and ([.services[] | .image] | all(startswith("public.ecr.aws/supabase/")))
  and ([.services[] | .pull_policy] | all(. == "never")) and ([.services[] | .restart // "no"] | all(. == "no"))
  and (.name == "'"$project"'")' >/dev/null || fail "resolved compose model violates loopback/pull/restart policy"
unset cfg

# 4. db first; give the service roles (created by the image) the per-run password
dc up -d --no-build --pull never db >/dev/null 2>&1 || fail "db failed to start"
for _ in $(seq 1 90); do
  [ "$(dc ps --format '{{.Health}}' db 2>/dev/null)" = "healthy" ] && break; sleep 2
done
[ "$(dc ps --format '{{.Health}}' db 2>/dev/null)" = "healthy" ] || fail "db not healthy"
dc exec -T db sh -c 'psql -X -q -v ON_ERROR_STOP=1 -U supabase_admin -d postgres -v pw="$POSTGRES_PASSWORD"' >/dev/null <<'SQL' || fail "role password setup failed"
alter role postgres with password :'pw';
alter role authenticator with password :'pw';
alter role supabase_auth_admin with password :'pw';
alter role supabase_storage_admin with password :'pw';
SQL

# 5. rest of the stack
dc up -d --no-build --pull never auth rest storage gateway >/dev/null 2>&1 || fail "service start failed"

# 6. post-launch binding proof: every published port listens on 127.0.0.1 only
for p in "$db_port" "$api_port"; do
  out="$(lsof -nP -iTCP:"$p" -sTCP:LISTEN 2>/dev/null | tail -n +2 || true)"
  [ -n "$out" ] || fail "port $p is not listening"
  if printf '%s\n' "$out" | awk '{print $9}' | grep -vqx "127.0.0.1:$p"; then fail "port $p listens beyond 127.0.0.1"; fi
done
echo "up: published ports verified 127.0.0.1-only ($db_port, $api_port)"

# 7. readiness: auth schema, storage schema, gateway
psql_admin() { dc exec -T db psql -X -q -A -t -U supabase_admin -d postgres -c "$1"; }
ready=0
for _ in $(seq 1 90); do
  if [ "$(psql_admin "select (to_regclass('auth.users') is not null and to_regclass('auth.identities') is not null and to_regclass('storage.objects') is not null and to_regclass('storage.buckets') is not null)" 2>/dev/null | tr -d '[:space:]')" = "t" ] \
     && [ "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$api_port/auth/v1/health" || true)" = "200" ]; then ready=1; break; fi
  sleep 2
done
[ $ready -eq 1 ] || fail "auth/storage schemas or gateway not ready"
echo "RUNDIR=$rundir"
