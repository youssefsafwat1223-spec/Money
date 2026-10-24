#!/bin/bash
# Disabled executor: all phases delegate to the unconditional refusal gate.
# No start, SQL, stop, copy or removal operation exists in this script.
set -euo pipefail
script_dir="${BASH_SOURCE[0]%/*}"
has_phase=0
for argument in "$@"; do
  if [ "$argument" = "--phase" ]; then has_phase=1; fi
done
if [ "$has_phase" -eq 0 ]; then
  echo "run: --phase is required" >&2
  exit 2
fi
exec /usr/bin/env -i PATH= /bin/bash --noprofile --norc \
  "$script_dir/preflight.sh" "$@"
