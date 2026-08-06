#!/usr/bin/env bash
# Canonical local CI gate runner (MALI-036 / Phase-7 Batch-1). The single source of
# truth for local + CI validation of everything that does NOT need cloud infra.
#
# Gates (mandatory unless the toolchain is unavailable):
#   1. supabase migration lint (numbering + SECURITY DEFINER lockdown)
#   2. Deno Edge-function unit tests (_shared)
#   3. Deno lint (_shared)                               [Phase-7 B1]
#   4. flutter analyze
#   5. flutter test (full suite; set SKIP_FLUTTER_TEST=1 to skip locally)
#   6. Node contract tests (supabase/tests/*.mjs; credential-gated cases self-skip) [B1]
#   7. admin authorization tests (admin/tests)           [B1 — was CI-invisible: MALI-066n]
#
# Truthfulness contract (Phase-7 B1):
#   * an unexpected failure returns a non-zero exit code;
#   * a failed subcommand is NEVER hidden by a later success;
#   * a toolchain that is UNAVAILABLE is reported separately — never counted as pass;
#   * the final summary matches actual results; it cannot print "passed" while a
#     mandatory suite failed;
#   * `--self-test` / CI_GATES_INJECT_FAILURE prove a failed gate fails the script.
#
# Cloud/device-only gates (Android + iOS device builds, live SQL/RLS apply, APNs,
# App Store archive, credential-gated live Supabase tests) run in CI or are external
# release prerequisites — see app/docs/PHASE_6_EXTERNAL_VERIFICATION_CHECKLIST.md.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

pass_count=0
fail_count=0
unavail_count=0
fail=0

step() { echo; echo "══ $1 ══"; }
ok() { echo "  ✓ $1"; pass_count=$((pass_count + 1)); }
bad() { echo "  ✗ $1"; fail_count=$((fail_count + 1)); fail=1; }
unavail() { echo "  ! $1 — UNAVAILABLE (reported separately, not a pass)"; unavail_count=$((unavail_count + 1)); }

# --- Self-test: prove a failed gate makes the script exit non-zero (Phase-7 B1) ---
if [ "${1:-}" = "--self-test" ]; then
  fail=0
  if false; then ok "unreachable"; else bad "injected self-test failure"; fi
  if [ "$fail" -eq 1 ]; then
    echo "SELF-TEST PASS: a failed gate sets fail=1 and would exit non-zero."
    exit 0
  fi
  echo "SELF-TEST FAIL: failure was not detected."
  exit 1
fi

step "migration lint"
if bash "$ROOT/supabase/tools/check_migrations.sh"; then ok "migrations"; else bad "migrations"; fi

step "deno edge-function tests + lint"
if command -v deno >/dev/null 2>&1; then
  if ( cd "$ROOT/supabase/functions" && deno test --allow-all _shared/ ); then ok "deno _shared tests"; else bad "deno _shared tests"; fi
  if ( cd "$ROOT/supabase/functions" && deno lint _shared/ ); then ok "deno lint"; else bad "deno lint"; fi
else
  unavail "deno"
fi

step "flutter analyze"
if ( cd "$ROOT/app" && flutter analyze ); then ok "analyze"; else bad "analyze"; fi

if [ "${SKIP_FLUTTER_TEST:-0}" != "1" ]; then
  step "flutter test"
  if ( cd "$ROOT/app" && flutter test ); then ok "flutter test"; else bad "flutter test"; fi
else
  step "flutter test"
  unavail "flutter test (SKIP_FLUTTER_TEST=1)"
fi

step "node contract tests"
if command -v node >/dev/null 2>&1; then
  # Credential-gated live cases self-skip (with an explicit prerequisite message);
  # when credentials ARE present a failing live case fails the suite.
  if ( cd "$ROOT" && node --test supabase/tests/*.mjs ); then ok "node contract"; else bad "node contract"; fi
else
  unavail "node"
fi

step "admin authorization tests"
if command -v npm >/dev/null 2>&1 && [ -d "$ROOT/admin/node_modules" ]; then
  if ( cd "$ROOT/admin" && npm run --silent test:auth ); then ok "admin auth"; else bad "admin auth"; fi
elif command -v npm >/dev/null 2>&1; then
  unavail "admin auth (run 'npm ci' in admin/ first)"
else
  unavail "npm"
fi

# --- Intentional-failure injection self-test hook (Phase-7 B1) ---
if [ "${CI_GATES_INJECT_FAILURE:-0}" = "1" ]; then
  step "INJECTED FAILURE (self-test)"
  bad "intentional failure (CI_GATES_INJECT_FAILURE=1)"
fi

echo
echo "── summary ── passed:$pass_count failed:$fail_count unavailable:$unavail_count"
if [ "$fail" -eq 0 ]; then
  if [ "$unavail_count" -gt 0 ]; then
    echo "ALL RUN GATES PASSED ($unavail_count unavailable — see notes above)"
  else
    echo "ALL LOCAL GATES PASSED"
  fi
else
  echo "SOME GATES FAILED ($fail_count) — see ✗ above"
fi
exit "$fail"
