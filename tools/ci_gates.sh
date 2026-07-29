#!/usr/bin/env bash
# Local CI gate runner (MALI-036). Runs every quality gate that does NOT need
# cloud infra, so a developer reproduces CI's bar before pushing:
#   1. supabase migration lint (numbering + SECURITY DEFINER lockdown)
#   2. Deno Edge-function unit tests (_shared)
#   3. flutter analyze
#   4. flutter test (full suite; set SKIP_FLUTTER_TEST=1 to skip)
#
# Cloud/device-only gates (Android + iOS device builds, live SQL/RLS apply,
# APNs, App Store archive) run in CI or are external release prerequisites —
# see app/docs/FULL_APP_AUDIT.md.
#
# Exit 0 = all run gates passed; non-zero = at least one failed.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail=0
step() { echo; echo "══ $1 ══"; }
ok() { echo "  ✓ $1"; }
bad() { echo "  ✗ $1"; fail=1; }

step "migration lint"
if bash "$ROOT/supabase/tools/check_migrations.sh"; then ok "migrations"; else bad "migrations"; fi

step "deno edge-function tests"
if command -v deno >/dev/null 2>&1; then
  if ( cd "$ROOT/supabase/functions" && deno test --allow-all _shared/ ); then
    ok "deno _shared"
  else
    bad "deno _shared"
  fi
else
  echo "  ! deno not installed — skipped (CI runs it)"
fi

step "flutter analyze"
if ( cd "$ROOT/app" && flutter analyze ); then ok "analyze"; else bad "analyze"; fi

if [ "${SKIP_FLUTTER_TEST:-0}" != "1" ]; then
  step "flutter test"
  if ( cd "$ROOT/app" && flutter test ); then ok "flutter test"; else bad "flutter test"; fi
fi

echo
if [ "$fail" -eq 0 ]; then echo "ALL LOCAL GATES PASSED"; else echo "SOME GATES FAILED"; fi
exit "$fail"
