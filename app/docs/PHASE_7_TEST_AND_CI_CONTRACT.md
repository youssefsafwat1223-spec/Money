# Phase 7 — Test & CI Contract (Batch 1)

The canonical, truthful test/gate contract for local + CI validation. Batch 1 fixed the
known harness / lint / skip-policy / known-failure truthfulness gaps; it changed **no**
production feature behavior.

## 1. Canonical gate

**`tools/ci_gates.sh` is the single source of truth**, run identically locally and in CI
(`.github/workflows/ci.yml` invokes exactly this script — there is no CI-only subset, and
no CI-only extra step). Gates, in order:

| # | Gate | Command (from repo root) | Mandatory |
|---|---|---|---|
| 1 | migration lint (numbering + SECURITY DEFINER lockdown) | `bash supabase/tools/check_migrations.sh` | yes |
| 2 | Deno `_shared` unit tests | `cd supabase/functions && deno test --allow-all _shared/` | yes (if deno) |
| 2 | Deno lint `_shared` | `cd supabase/functions && deno lint _shared/` | yes (if deno) |
| 3 | flutter analyze | `cd app && flutter analyze` | yes |
| 4 | flutter test (full) | `cd app && flutter test` | yes (`SKIP_FLUTTER_TEST=1` local only) |
| 5 | Node contract tests | `node --test supabase/tests/*.mjs` | yes (if node) |
| 6 | skip/ignore manifest enforcement | `node tools/check_test_skips.mjs --node <tap> --deno <out>` | yes (if node) |
| 7 | admin authorization tests | `cd admin && npm run test:auth` | yes (if npm + `admin/node_modules`) |
| 8 | l10n freshness | `cd app && flutter gen-l10n && git diff --quiet -- app/lib/l10n/` | yes |

**Truthfulness contract (enforced + self-tested):**
- an unexpected failure returns a non-zero exit; a failed subcommand is never hidden by a
  later success (each gate is checked individually, `fail=1` latches). A tee'd command's
  real status is read via `PIPESTATUS[0]`, never the `tee`;
- `set -uo pipefail`; the success banner is guarded by `[ "$fail" -eq 0 ]`, so the script
  can NEVER print "passed" while a mandatory suite failed;
- a toolchain that is **UNAVAILABLE** (deno/node/npm absent, or `admin/node_modules` not
  installed) is reported in a separate `tools unavailable` count — never as a pass;
- `bash tools/ci_gates.sh --self-test` proves the failure-propagation machinery (a failed
  gate → non-zero exit); `CI_GATES_INJECT_FAILURE=1` injects a real failing step for a
  full-run demonstration. Both are covered by
  `supabase/tests/ci_gates_contract_node_test.mjs`.

### Truthful nested summary (§Blocker-4)

The final summary reports **separate** fields — skipped/ignored/unavailable are NEVER
rolled into the passed count:

```
mandatory gates passed  : <ok() only>
mandatory gates failed  : <bad() only>
tools unavailable       : <unavail() only — not a pass>
node tests skipped      : <count of # SKIP, credential-gated — see manifest>
deno tests ignored      : <count of "... ignored" — see manifest>
skip/ignore manifest    : satisfied | VIOLATED
external verification   : pending (device / live Supabase / native timing)
retained lint exceptions: <N> deno-lint-ignore (no-explicit-any)
CI_GATES_JSON {...}      # machine-readable, secret-free
```

A malformed/partial credential set is a **config failure** (`bad`), not a skip. The
machine-readable `CI_GATES_JSON {...}` line carries no secrets.

## 2. MALI-041 disposition (§Blocker-1)

**Authoritative finding.** MALI-041 is the admin-authorization **static test-quality**
defect, not a runtime authz defect:

- `FULL_APP_AUDIT.md:622` — "Admin test quality | `admin/tests/admin-authorization.test.mjs`;
  `functions/parser-test/index.ts:57-76` | Static test **assumes double quotes and fails**
  despite auth→admin→parser ordering being correct."
- `FINAL_FULL_PRODUCTION_AUDIT.md:122` — "Executed: 3 pass / 1 fail — still the quote-style
  regex … AND the test is wired into no CI step → **MALI-066n**."

So MALI-041 (brittle assertion) and MALI-066n (the same test — and other suites — reaching
no CI step) are **distinct** findings; this batch fixes both without conflating them.

**Baseline reproduction.** The real source uses single quotes
(`parser-test/index.ts:64` → `.from('admin_users')`, `:73` → `.from('sms_parsers')`,
`:61` → `auth.getUser`). The original assertion's double-quote literal
`.indexOf('.from("admin_users")')` returns **-1** against that source → a **false
failure** while the auth→admin→read ordering is in fact correct. That is exactly the
authoritative symptom.

**Fix + regression.** A quote/whitespace-independent structural contract
(`enforcesAuthThenAdminThenRead`) proves `auth.getUser → admin_users allowlist →
sms_parsers read` order and no caller-supplied admin identity. Guarding it:
- three **negative** self-tests (auth removed / allowlist removed / read-before-checks all
  make the contract return `false`);
- one **regression** (`MALI-041 regression: auth-order contract is quote-style invariant`)
  that feeds the correctly-ordered path in **single- and double-quote** form, asserts both
  pass and are equal, and asserts the **live source** satisfies it — locking in that the
  original single-quote false-failure input now passes.

The admin suite is **8 pass / 0 fail** and is wired into the canonical gate (gate 7).
MALI-041 is **RESOLVED**; there are currently **no** accepted known-failure entries.

## 3. Skip / ignored policy — machine-readable + enforced (§Blocker-2)

Skips/ignores are governed by **`tools/test_skip_manifest.json`** and enforced by
**`tools/check_test_skips.mjs`** (gate 6). The manifest is keyed by **stable
test/suite identifiers** (suite + reason substring), NOT by volatile global counts.

**Node credential-gated skips.** Each entry records the credential group it needs
(`credentialGroups` in the manifest):

| group | required env vars |
|---|---|
| `supabaseAnon` | `SUPABASE_URL`, `SUPABASE_ANON_KEY` |
| `supabaseServiceRole` | `SUPABASE_URL`, `SUPABASE_ANON_KEY`, `SUPABASE_SERVICE_ROLE_KEY` |

Credential behavior (enforced):
- **absent** (0 vars set) → the case may skip (expected);
- **partial/malformed** (some but not all) → the checker **FAILS** as a config error — a
  half-configured env is never accepted as a successful skip;
- **present** (all set) → the case must **execute**; a still-skipped case **FAILS**.

**Deno ignored fixtures.** Two `_shared` tests use the framework `ignore` flag because
they require a **live Postgres** advisory-lock/transaction (MALI-060n):
`claim_ai_idempotency: claimed` and `concurrent claims resolve to exactly one claimed`.
Both are manifest entries (`deno.expectedIgnored`).

**The checker FAILS on:** a new/unexpected skip, a disappeared expected skip, a changed
skip reason, an ignored test with no manifest entry, partial/malformed credentials,
credentials-present-but-still-skipped, a mandatory test disappearing, or a
resolved-known-failure that is still active. Contract tests:
`supabase/tests/skip_manifest_node_test.mjs`.

## 4. Deno-lint disposition + exact retained exceptions (§Blocker-6)

`deno lint _shared/` is **clean (0 findings)**. Four pre-existing findings were fixed with
no production semantic change (ledger.ts redundant `async`; notification_policy.ts
misplaced ignore; fingerprint_reservation_test.ts `find` await). No broad lint baseline —
a new finding fails the gate.

**Retained `deno-lint-ignore` exceptions — exactly 7, all `no-explicit-any`**, each
suppressing the loosely-typed Supabase Edge client on the specific line it precedes:

| file | count | kind | why it can't hide neighbors |
|---|---|---|---|
| `_shared/notification_logs.ts` | 1 | production (`SupabaseClientLike` type alias) | per-line directive; `ban-unused-ignore` fails if the `any` is removed |
| `_shared/notification_policy.ts` | 1 | production (`loadNotificationPolicy(supabase)` param) | per-line directive immediately above the param |
| `_shared/ai_endpoint_test.ts` | 2 | test doubles | per-line directives |
| `_shared/notification_policy_test.ts` | 3 | test doubles | per-line directives |

`deno-lint-ignore` is **per-line only** (it suppresses the single following line), and
`ban-unused-ignore` is enabled, so an ignore that stops matching a real finding itself
becomes a lint error — an exception cannot silently mask a neighboring new finding.

**Allowlist contract** (`supabase/tests/deno_lint_exceptions_node_test.mjs`): asserts the
`{file → count}` set is EXACTLY the table above and every directive names
`no-explicit-any`; any new/moved/removed suppression fails the test. Combined with gate 2
(`deno lint` fails on any new finding), the allowlist is provably exact. Owner: backend;
removal condition: adopt a typed Supabase Edge client, then delete the directives.

## 5. Child-process test contract (§Blocker-5)

`restore_recovery_test.dart`:
- The pure-Dart, file-backed crash/replay tests run **deterministically in-process**
  (throw-mid-transaction → reopen file → old state; commit → restart → discovered).
- The REAL `Process.start` native-sqlite kill test is a **locally testable** process test
  (pure Dart + the on-disk sqlite native lib). **A busy machine is NOT an external
  prerequisite** and NEVER causes a skip:
  - readiness uses a generous **60 s** deadline that absorbs load;
  - a transient post-`SIGKILL` "database is locked" triggers a **bounded SETUP retry**
    (≤4 attempts), not a skip;
  - the rollback result is **ASSERTED** — a surviving `uncommitted-restore` row **FAILS**
    as the real durability defect it would be. No assertion/transaction failure is ever
    converted into a skip;
  - the **only** skips are genuine platform absence: no `dart` executable, or the sqlite3
    **native library cannot be loaded at all** (detected from child/reader stderr via
    `_nativeSqliteUnavailable`).

Verified: 3/3 pass, 0 skips under full CPU saturation (busy-loops ≥ cores).

## 6. Generated-code freshness (§Blocker-3)

Freshness lives **inside** the canonical gate (gate 8) — there is no separate CI-only
freshness step. Correct staleness surface:
- Drift/freezed/json `*.g.dart` / `*.freezed.dart` are **git-ignored** (regenerated by
  `build_runner` every build) → they have **no committed-staleness surface** and a
  `git diff` on them is meaningless (a prior gate wrongly diffed these gitignored files;
  that false-green is removed).
- The **committed** generated artifact is the l10n output
  (`flutter gen-l10n → app/lib/l10n/*.dart`). Gate 8 regenerates it and fails if
  `git diff -- app/lib/l10n/` is non-empty → committed l10n cannot go stale silently.

CI regenerates the gitignored `build_runner` output before running the gate (so the
Flutter suite compiles); the gate itself performs the l10n freshness check.

## 7. CI / local parity (§Blocker-3)

`.github/workflows/ci.yml` sets up Flutter + Deno + Node + admin deps, regenerates the
gitignored `build_runner` output, then runs **`bash tools/ci_gates.sh` as the ONLY
validation step**. There is no shorter CI-only path and no CI-only extra step. A static
contract test (`ci_gates_contract_node_test.mjs`) asserts CI invokes the gate and that no
competing `git diff --exit-code` validation step exists.

## 8. Remaining external / platform prerequisites

- Native iOS/Android device builds & tests (run only if native/build files change).
- Live Supabase credential-gated tests (skip locally with credentials absent; run where
  credentials exist — see the manifest).
- Native SQLCipher/OS process-kill timing (the local native-sqlite kill test is covered;
  SQLCipher-on-device timing remains a device check).

See `PHASE_6_EXTERNAL_VERIFICATION_CHECKLIST.md`.
