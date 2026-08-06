# Phase 7 — Test & CI Contract (Batch 1)

The canonical, truthful test/gate contract for local + CI validation. Batch 1 fixed
the known harness/lint/known-failure truthfulness gaps; it changed **no** production
feature behavior.

## 1. Canonical gate

**`tools/ci_gates.sh` is the single source of truth**, run identically locally and in
CI (`.github/workflows/ci.yml` invokes it — no CI-only subset). Gates, in order:

| # | Gate | Command (from repo root) | Mandatory |
|---|---|---|---|
| 1 | migration lint (numbering + SECURITY DEFINER lockdown) | `bash supabase/tools/check_migrations.sh` | yes |
| 2 | Deno `_shared` unit tests | `cd supabase/functions && deno test --allow-all _shared/` | yes (if deno) |
| 3 | Deno lint `_shared` | `cd supabase/functions && deno lint _shared/` | yes (if deno) |
| 4 | flutter analyze | `cd app && flutter analyze` | yes |
| 5 | flutter test (full) | `cd app && flutter test` | yes (`SKIP_FLUTTER_TEST=1` local only) |
| 6 | Node contract tests | `node --test supabase/tests/*.mjs` | yes (if node) |
| 7 | admin authorization tests | `cd admin && npm run test:auth` | yes (if npm + `admin/node_modules`) |

**Truthfulness contract (enforced + self-tested):**
- an unexpected failure returns a non-zero exit; a failed subcommand is never hidden
  by a later success (each gate is checked individually, `fail=1` latches);
- `set -uo pipefail`; the success banner is guarded by `[ "$fail" -eq 0 ]`, so the
  script can NEVER print "passed" while a mandatory suite failed;
- a toolchain that is **UNAVAILABLE** (deno/node/npm absent, or `admin/node_modules`
  not installed) is reported in a separate `unavailable:` count — never as a pass;
- `bash tools/ci_gates.sh --self-test` proves the failure-propagation machinery
  (a failed gate → non-zero exit); `CI_GATES_INJECT_FAILURE=1` injects a real failing
  step for a full-run demonstration. Both are covered by
  `supabase/tests/ci_gates_contract_node_test.mjs`.

Previously the gate omitted Deno lint, Node contract tests, and the admin auth suite
(MALI-066n — the admin test reached no CI step), so it could print "ALL LOCAL GATES
PASSED" while the admin test failed. That false-green is closed.

## 2. Known-failure & MALI-041 disposition

**MALI-041 — RESOLVED.** Root cause: `admin/tests/admin-authorization.test.mjs` matched
the parser-test source with the double-quoted literal `.from("admin_users")`, but the
source uses single quotes (`.from('admin_users')`) — a formatting-sensitive assertion,
not a behavioral one. It was also invisible to CI (MALI-066n). Fix: a quote/whitespace-
independent structural contract (`enforcesAuthThenAdminThenRead`) proving
`auth.getUser → admin_users allowlist → sms_parsers read` order + no caller-supplied
admin identity, PLUS three negative self-tests that fail if the auth check, the
allowlist check, or the ordering is broken. The suite is now **7 pass / 0 fail** and is
wired into the canonical gate. It is **no longer a known failure.**

There are currently **no** accepted known-failure test entries.

## 3. Skip / ignored policy

Skips are permitted ONLY for an absent environment prerequisite, each with an explicit
machine-readable reason emitted by the test framework:

- **Node contract tests** — credential-gated live cases self-skip with
  `# requires SUPABASE_URL + SUPABASE_ANON_KEY + SUPABASE_SERVICE_ROLE_KEY …`. With
  credentials present, a failing live case FAILS the suite (never a silent skip).
  Current: 29 pass / 0 fail / 27 credential-gated skips.
- **Deno `_shared`** — 2 ignored fixtures (framework `ignore`), 76 pass / 0 fail.
- **flutter** — the real `Process.start` native-sqlite kill test is skip-safe under
  load / when `dart` is unavailable (native SQLCipher/process timing is external); the
  pure-Dart, file-backed crash + commit-before-ack recovery tests run deterministically.

Exact global counts are intentionally NOT encoded as a gate assertion (they are
volatile and there is no generated manifest); the stable skip **reasons** are the
contract. A credential-gated case never reports a malformed-credential misconfig as a
successful skip — the test asserts the required vars explicitly.

## 4. Deno-lint disposition

`deno lint _shared/` is now **clean (0 findings)**. The four pre-existing findings were
fixed with no production semantic change:
- `ledger.ts` `isLedgerDualWriteEnabled` — removed the redundant `async` (returns the
  resolver Promise directly; identical runtime behavior);
- `notification_policy.ts` — moved the misplaced `deno-lint-ignore no-explicit-any` to
  the exact `supabase` parameter line (resolves the unused-ignore AND the `any`), with
  a justification comment (the Edge client is loosely typed);
- `fingerprint_reservation_test.ts` `find` — added `await Promise.resolve()` to match
  the sibling `insert` and keep the async store-interface signature.

No broad lint baseline was introduced; a new finding fails the gate. Retained
exceptions: one narrowed per-line `no-explicit-any` ignore at
`notification_policy.ts` `loadNotificationPolicy(supabase)` (loosely-typed Edge client).

## 5. Child-process test contract

The pure-Dart, file-backed crash/replay tests (`restore_recovery_test.dart`) run
deterministically in-process (throw-mid-transaction → reopen file → old state; commit
→ restart → discovered, not replayed). The REAL `Process.start` native-sqlite kill test
is the only externally-timed case: it uses an explicit ready-file handshake, a bounded
readiness window, a bounded reader timeout, always kills + awaits the child, and
isolates its temp DB per test — and it skips (never fails) on native/subprocess
ambiguity under load. Only native SQLCipher/OS-kill timing remains external.

## 6. Generated-code freshness

CI runs `build_runner` then `git diff --exit-code` (app) so committed generated Drift
output cannot go stale silently.

## 7. CI / local parity

`.github/workflows/ci.yml` sets up Flutter + Deno + Node + admin deps and runs the
single canonical gate `bash tools/ci_gates.sh` (plus the generated-code freshness
check). There is no shorter CI-only path. A static contract test asserts CI invokes
the gate.

## 8. Remaining external / platform prerequisites

- Native iOS/Android device builds & tests (run only if native/build files change).
- Live Supabase credential-gated tests (skip locally; run where credentials exist).
- Native SQLCipher/OS process-kill timing.

See `PHASE_6_EXTERNAL_VERIFICATION_CHECKLIST.md`.
