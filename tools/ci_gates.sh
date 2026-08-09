#!/usr/bin/env bash
# Canonical CI gate runner (MALI-036 / Phase-7 Batch-1) — the SINGLE source of truth
# for local + CI validation of everything that does NOT need cloud infra. CI invokes
# this exact script (see .github/workflows/ci.yml); there is no CI-only subset.
#
# Gates (mandatory unless the toolchain is unavailable):
#   1. supabase migration lint (numbering + SECURITY DEFINER lockdown)
#   2. Deno edge-function tests (ALL functions, not just _shared/) + Deno lint (_shared)
#   3. flutter analyze
#   4a. flutter test — BULK parallel; production-cost Argon2 crypto EXCLUDED
#       (--exclude-tags crypto-prod). SKIP_FLUTTER_TEST=1 for fast local iteration.
#   4b. flutter test — SERIALIZED production-cost crypto (--tags crypto-prod
#       --concurrency=1). Split is a DETERMINISM fix, not a convenience: the v3
#       Argon2id KDF derives each segment in a worker isolate guarded by a hardcoded
#       10s per-segment timeout (cryptography 2.9.0) that no @Timeout can raise; under
#       the parallel bulk run's CPU saturation a starved segment trips it
#       nondeterministically ("Segment processing timeout"). Serializing gives the
#       derivation an uncontended core. BOTH stages are mandatory; no test is dropped
#       (bulk + crypto = the whole suite). See dart_test.yaml + PHASE_7_TEST_AND_CI_CONTRACT.md.
#   5. Node contract tests (supabase/tests/*.mjs; live cases self-skip)
#   6. skip/ignore manifest enforcement (tools/test_skip_manifest.json)
#   7. admin authorization tests
#   8. l10n freshness (flutter gen-l10n + git diff app/lib/l10n; .g.dart is gitignored)
#   9. MALI-034 architecture guard — the retired Supabase-primary financial
#      authority (flags / FinancialCacheRepairService / legacy Supabase financial
#      repos / Routed* wrappers) cannot silently return; schema stays 29.
#  10. iOS packaging inventory (MALI-066n) — CONDITIONAL/external: runs the
#      built-Runner.app check only when a bundle exists (real archive evidence),
#      else UNAVAILABLE. The static Info.plist/privacy contract is in flutter test.
#
# Truthfulness contract (Phase-7 B1):
#   * an unexpected failure returns non-zero; a failed subcommand is NEVER hidden;
#   * pipelines use PIPESTATUS so a tee'd command's real status is used;
#   * an UNAVAILABLE toolchain is reported separately — never counted as pass;
#   * the final summary surfaces NESTED status (skips/ignored/external) truthfully and
#     never rolls skipped/ignored into passed;
#   * the success banner is guarded by fail==0; it cannot print while a mandatory
#     suite failed;
#   * `--self-test` / CI_GATES_INJECT_FAILURE prove a failed gate fails the script.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

pass_count=0; fail_count=0; unavail_count=0; fail=0
node_skips="n/a"; deno_ignored="n/a"; manifest_state="not-run"
LINT_EXCEPTIONS=7  # deno-lint-ignore no-explicit-any suppressions (2 prod Edge helpers + 5 test doubles); see PHASE_7_TEST_AND_CI_CONTRACT.md

TMP="$(mktemp -d "${TMPDIR:-/tmp}/ci_gates.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
NODE_TAP="$TMP/node.tap"; DENO_OUT="$TMP/deno.txt"

step() { echo; echo "══ $1 ══"; }
ok() { echo "  ✓ $1"; pass_count=$((pass_count + 1)); }
bad() { echo "  ✗ $1"; fail_count=$((fail_count + 1)); fail=1; }
unavail() { echo "  ! $1 — UNAVAILABLE (reported separately, not a pass)"; unavail_count=$((unavail_count + 1)); }

# --- Self-test: prove a failed gate makes the script exit non-zero ----------------
if [ "${1:-}" = "--self-test" ]; then
  fail=0
  if false; then ok "unreachable"; else bad "injected self-test failure"; fi
  if [ "$fail" -eq 1 ]; then echo "SELF-TEST PASS: a failed gate sets fail=1 and would exit non-zero."; exit 0; fi
  echo "SELF-TEST FAIL: failure was not detected."; exit 1
fi

step "migration lint"
if bash "$ROOT/supabase/tools/check_migrations.sh"; then ok "migrations"; else bad "migrations"; fi

step "deno edge-function tests + lint"
if command -v deno >/dev/null 2>&1; then
  # MALI-042/066n — run EVERY Edge-function Deno test, not just _shared/. The
  # whole-tree run picks up per-function suites (e.g. catalog-delta's country-code
  # injection guard) that were previously CI-invisible; live-backend cases
  # self-skip via the skip/ignore manifest (deno_ignored).
  ( cd "$ROOT/supabase/functions" && deno test --allow-all ) 2>&1 | tee "$DENO_OUT"
  if [ "${PIPESTATUS[0]}" -eq 0 ]; then ok "deno tests (all functions)"; else bad "deno tests (all functions)"; fi
  if ( cd "$ROOT/supabase/functions" && deno lint _shared/ ); then ok "deno lint"; else bad "deno lint"; fi
else
  unavail "deno"
fi

step "flutter analyze"
if ( cd "$ROOT/app" && flutter analyze ); then ok "analyze"; else bad "analyze"; fi

# flutter test is split into two MANDATORY stages for Argon2 determinism (see header):
#   4a bulk parallel with production-cost crypto EXCLUDED, 4b that crypto SERIALIZED.
# Union of the two tag sets = the whole suite, so no test is dropped or double-counted.
step "flutter test (bulk — parallel; production-cost crypto excluded)"
if [ "${SKIP_FLUTTER_TEST:-0}" != "1" ]; then
  if ( cd "$ROOT/app" && flutter test --exclude-tags crypto-prod ); then ok "flutter test (bulk)"; else bad "flutter test (bulk)"; fi
else
  unavail "flutter test bulk (SKIP_FLUTTER_TEST=1)"
fi

step "flutter test (crypto — serialized production-cost Argon2, --concurrency=1)"
if [ "${SKIP_FLUTTER_TEST:-0}" != "1" ]; then
  if ( cd "$ROOT/app" && flutter test --tags crypto-prod --concurrency=1 ); then ok "flutter test (crypto serialized)"; else bad "flutter test (crypto serialized)"; fi
else
  unavail "flutter test crypto (SKIP_FLUTTER_TEST=1)"
fi

step "node contract tests"
if command -v node >/dev/null 2>&1; then
  ( cd "$ROOT" && node --test --test-reporter=spec --test-reporter-destination=stdout \
      --test-reporter=tap --test-reporter-destination="$NODE_TAP" supabase/tests/*.mjs )
  node_status=$?
  node_skips="$(grep -c '# SKIP' "$NODE_TAP" 2>/dev/null || echo 0)"
  if [ "$node_status" -eq 0 ]; then ok "node contract"; else bad "node contract"; fi
else
  unavail "node"
fi

step "skip/ignore manifest enforcement"
if command -v node >/dev/null 2>&1; then
  args=()
  [ -f "$NODE_TAP" ] && args+=(--node "$NODE_TAP")
  [ -f "$DENO_OUT" ] && args+=(--deno "$DENO_OUT")
  if node "$ROOT/tools/check_test_skips.mjs" "${args[@]}"; then
    ok "skip/ignore manifest"; manifest_state="satisfied"
  else
    bad "skip/ignore manifest"; manifest_state="VIOLATED"
  fi
  deno_ignored="$(grep -c '\.\.\. .*ignored' "$DENO_OUT" 2>/dev/null || echo 0)"
else
  unavail "skip manifest (needs node)"
fi

step "admin authorization tests"
if command -v npm >/dev/null 2>&1 && [ -d "$ROOT/admin/node_modules" ]; then
  if ( cd "$ROOT/admin" && npm run --silent test:auth ); then ok "admin auth"; else bad "admin auth"; fi
elif command -v npm >/dev/null 2>&1; then
  unavail "admin auth (run 'npm ci' in admin/ first)"
else
  unavail "npm"
fi

# Generated-code freshness: drift/freezed/json .g.dart is GITIGNORED (regenerated by
# build_runner every build — no committed-staleness surface). The COMMITTED generated
# artifact is the l10n output (flutter gen-l10n → app/lib/l10n/*.dart), so THAT is the
# real, fast staleness check.
step "l10n freshness (flutter gen-l10n)"
if ( cd "$ROOT/app" && flutter gen-l10n >/dev/null 2>&1 ) && git -C "$ROOT" diff --quiet -- app/lib/l10n/; then
  ok "l10n freshness"
else
  bad "l10n freshness (committed app/lib/l10n is stale — run 'flutter gen-l10n' and commit)"
fi

step "MALI-034 architecture guard (retired Supabase-primary authority stays gone)"
if bash "$ROOT/tools/check_arch_guard.sh"; then ok "arch guard"; else bad "arch guard"; fi

# MALI-066n — iOS packaging inventory. The BUILT-bundle check needs a freshly
# built Runner.app (extensions, PrivacyInfo, bundle ids, Mach-O) — real archive
# evidence that only exists after a macOS/CI build. When a bundle is present it
# runs and must pass; otherwise it is reported UNAVAILABLE (never a pass, never
# faked). The source/static packaging contract (Info.plist usage descriptions /
# privacy manifest) is covered deterministically by `flutter test`
# (test/ios/ios_privacy_manifest_test.dart), which runs in stage 4a.
step "iOS packaging inventory (built Runner.app — external build evidence)"
IOS_APP="$ROOT/app/build/ios/iphonesimulator/Runner.app"
if [ -d "$IOS_APP" ]; then
  if bash "$ROOT/app/tools/verify_ios_packaging.sh" "$IOS_APP"; then ok "ios packaging"; else bad "ios packaging"; fi
else
  unavail "ios packaging (no built Runner.app; static Info.plist contract runs in flutter test)"
fi

# --- intentional-failure injection self-test hook ---------------------------------
if [ "${CI_GATES_INJECT_FAILURE:-0}" = "1" ]; then
  step "INJECTED FAILURE (self-test)"; bad "intentional failure (CI_GATES_INJECT_FAILURE=1)"
fi

echo
echo "══ truthful summary ══"
echo "  mandatory gates passed : $pass_count"
echo "  mandatory gates failed : $fail_count"
echo "  tools unavailable      : $unavail_count"
echo "  node tests skipped     : $node_skips  (credentials absent — see manifest)"
echo "  deno tests ignored     : $deno_ignored  (live-Postgres — see manifest)"
echo "  skip/ignore manifest   : $manifest_state"
echo "  external verification  : pending (device / live Supabase / native timing — see PHASE_6 checklist)"
echo "  retained lint exceptions: $LINT_EXCEPTIONS deno-lint-ignore (no-explicit-any; loosely-typed Supabase Edge client — see PHASE_7 doc)"
# machine-readable line for CI assertions (no secrets):
echo "CI_GATES_JSON {\"passed\":$pass_count,\"failed\":$fail_count,\"unavailable\":$unavail_count,\"node_skipped\":\"$node_skips\",\"deno_ignored\":\"$deno_ignored\",\"manifest\":\"$manifest_state\",\"lint_exceptions\":$LINT_EXCEPTIONS}"
echo
if [ "$fail" -eq 0 ]; then
  if [ "$unavail_count" -gt 0 ]; then echo "ALL RUN GATES PASSED ($unavail_count unavailable — see notes)"; else echo "ALL LOCAL GATES PASSED"; fi
else
  echo "SOME GATES FAILED ($fail_count) — see ✗ above"
fi
exit "$fail"
