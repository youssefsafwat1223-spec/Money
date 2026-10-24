#!/bin/bash
# Tears down exactly the project recorded in the given run dir: compose down -v --remove-orphans, nothing else.
# Usage: down.sh <rundir>     (rundir contains `state` and `stack.env` written by up.sh)
set -euo pipefail
rundir="${1:?usage: down.sh <rundir>}"
[ -f "$rundir/state" ] || { echo "down: no state file in $rundir" >&2; exit 2; }
project="$(sed -n 's/^PROJECT=\(qirsh-fence-[0-9a-f]\{8\}\)$/\1/p' "$rundir/state")"
compose_file="$(sed -n 's/^COMPOSE_FILE=\(.*\)$/\1/p' "$rundir/state")"
[ -n "$project" ] && [ -f "$compose_file" ] || { echo "down: bad state" >&2; exit 2; }
case "$project" in *qirsh_beta1_sync_rc5800*|*qirsh_proof*|*frasaaaaa*) echo "down: protected name" >&2; exit 2;; esac
env -i PATH="$PATH" HOME="$HOME" docker compose -p "$project" -f "$compose_file" --env-file "$rundir/stack.env" down -v --remove-orphans
echo "down: $project removed"
