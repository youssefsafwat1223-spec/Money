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
| 4a | flutter test — bulk parallel (crypto excluded) | `cd app && flutter test --exclude-tags crypto-prod` | yes (`SKIP_FLUTTER_TEST=1` local only) |
| 4b | flutter test — serialized production-cost crypto | `cd app && flutter test --tags crypto-prod --concurrency=1` | yes (`SKIP_FLUTTER_TEST=1` local only) |
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

## 9. Argon2 KDF determinism — production-cost crypto serialization (Batch-2)

Phase-7 Batch-2 was code-complete but its canonical gate was NOT deterministic: on the
first authoritative run two backup/database-key tests failed with
`Bad state: Segment processing timeout`, then passed in isolation and on a gate rerun. A
rerun is evidence of a timing flake, **not** a closure mechanism. This section records
the root cause and the deterministic fix. **No production crypto changed** — same v3
envelope wire format, same Argon2id parameters (64 MiB / 3 / 2 / 32B), same AES-GCM.

### 9.1 Root cause (from source, not inference)

`package:cryptography` 2.9.0 derives Argon2id in worker isolates. In
`DartArgon2StateImplFfi._sendSegmentsToIsolate` (`lib/src/dart/argon2_impl_default.dart`
lines 266–269) each **segment** is awaited with a **hardcoded** guard:

```dart
final error = await receivePort.first.timeout(const Duration(seconds: 10),
    onTimeout: () { throw StateError('Segment processing timeout'); });
```

- This 10s ceiling is **internal to the package**, per-segment, and cannot be raised from
  our code. It is **immune to `@Timeout`** (the flutter-test framework timeout is a
  different, outer layer).
- The memory-hard 64 MiB derivation takes ~3s uncontended on the dev machine (12 logical
  cores), split into iterations×slices = 12 segment batches (~250 ms each — ~40× headroom).
- `flutter test` defaults to **concurrency = CPU cores**. Under the full parallel suite
  the Argon2 worker isolate is CPU-starved; measured derive time inflates to ~8s at 2×
  core oversubscription and ~11s at 4×. When a single segment is starved for a full 10s
  wall (the real gate's load is *bursty* — 12 `flutter_tester` processes + memory-heavy
  Drift tests + GC), the internal timeout fires nondeterministically.
- The earlier fix `f469b69c` added `@Timeout(3 min)` to `backup_envelope_v3_test.dart`.
  That addressed the **outer framework** timeout, not the **inner segment** timeout —
  which is exactly why the flake recurred in a different file (`database_key_state_test`).

### 9.2 The fix: serialize the derivation; stop paying it in semantic tests

Two mandatory `flutter test` stages (gate 4a/4b) split by the `crypto-prod` tag
(declared in `app/dart_test.yaml`); their tag sets are disjoint and their union is the
whole suite, so **no test is dropped or double-counted**:

- **4a bulk** `flutter test --exclude-tags crypto-prod` — parallel, as before, but with
  zero production-cost Argon2 in it.
- **4b crypto** `flutter test --tags crypto-prod --concurrency=1` — the production-cost
  crypto contract set, run **serialized**. One `flutter_tester` at a time gives the
  derivation an uncontended core, so every segment finishes in ~1s — two orders of
  magnitude under the 10s ceiling. This is the real determinism fix; the generous
  file-wide `@Timeout` remains only as a secondary framework-level guard.

**Production-cost crypto contract set (tagged `crypto-prod`, serialized) — deliberately
small, NOT faked:**

| file | real-Argon2 coverage it keeps |
|---|---|
| `test/core/backup/backup_envelope_v3_test.dart` | v3 round-trip, wrong-passphrase rejection, ciphertext/auth-tag/header tamper → authenticationFailed, recovery-code path, stored-slot round-trip, slot-AAD survives schema bump, v1/v2 legacy read, self-describing header/params (param wiring) |
| `test/core/backup/backup_payload_limit_test.dart` | MALI-030 within-cap v3 round-trip at production params + over-cap `payloadTooLarge` rejection |
| `test/core/backup/production_kdf_contract_test.dart` | **production KDF wiring contract** — real Argon2id selected (no injected kdf); ALL FOUR production params pinned (64 MiB/3/2/32); derivation is deterministic + salt-sensitive; consumed through the production v3 boundary; wrong-secret typed failure; missing-DB-key stays a DISTINCT typed exception |

**Production DB-key KDF wiring (architecture — audited).** The SQLCipher database key is a
RANDOM 32-byte value in platform secure storage (`SecureDatabaseKeyStore.readOrCreateKey`)
— it is **not** passphrase-derived, so there is **no Argon2 on the raw-DB-key path**;
`db_encryption_key_ref` is a deprecated column deliberately **excluded** from backups. The
production Argon2id KDF is the **backup key-protection** boundary (`BackupCrypto` default
64 MiB/3/2/32, consumed by `EncryptedBackupService`). `production_kdf_contract_test.dart`
is the mandatory proof that this production KDF wiring is genuine production-cost Argon2id
and that the missing-DB-key state (`LocalDatabaseKeyUnavailableException`) stays typed and
distinct — so cheapening the *semantic* DB-key tests never erodes that proof.

**Cheap-KDF seam (fast, stays in the parallel bulk stage).** Tests that assert envelope
*semantics* — properties independent of KDF cost — inject a cheap `Argon2id` via the
existing `BackupCrypto(kdf:)` constructor seam (no production code change; matches the
idiom already used in `backup_crypto_test.dart`, `backup_device_transfer_test.dart`,
`backup_test.dart`). Applied to the two previously-flaky tests in
`database_key_state_test.dart` (`a wrong backup passphrase is a DISTINCT error…`, `the
encrypted backup blob never contains the raw-key canary as plaintext`) — both prove
error-type / plaintext-leak properties that any KDF cost satisfies identically. Genuine
production-cost wrong-passphrase and round-trip coverage is retained in the serialized
set above, so nothing is faked away.

Note: the v3 path derives from the envelope **header** parameters, not the injected
`_kdf`, so the seam intentionally does **not** cheapen v3 — those tests stay
production-cost and serialized (correct: v3 behavior must be exercised at real cost).

### 9.3 Timeout & process/isolate hygiene (§5/§6)

- **Timeout policy.** A bigger timeout is NOT the fix and is not accepted as one. The
  determinism comes from serialization (removing contention), not from waiting longer.
  The internal 10s per-segment ceiling is not ours to change; `@Timeout(3 min)` on the
  crypto files is only a coarse framework backstop. Subprocess/load tests keep *separate,
  finite* deadlines: child **readiness** (`restore_recovery_test.dart` uses a generous
  60s readiness deadline that absorbs load), the bounded reader **operation** timeout
  (`.timeout(Duration(seconds: 30))`, ≤4-attempt setup retry), and per-test framework
  timeouts — none masks contention.
- **Subprocess cleanup (audited, adequate).** `restore_recovery_test.dart` and
  `database_process_liveness_test.dart` each force-kill their `Process.start` child
  (`SIGKILL`), `await proc.exitCode` (which completes only once the OS has reaped it),
  **and** carry a defensive `addTearDown` SIGKILL for the throw-path. No orphaned child
  survives a pass or a throw.
- **Isolate hygiene (hardened).** `database_lease_test.dart` spawns a CPU-hammer isolate
  and a lease-holder isolate. Their inline cooperative-stop/kill is retained; a defensive
  `addTearDown(() => worker.kill(priority: Isolate.immediate))` was added at each spawn so
  a throw before the inline kill can no longer leak a core-burning isolate into a
  co-located Argon2 derivation. (Broader `MALI-040` test-isolation items remain scoped to
  a later batch; this change is confined to the contention surface.)

### 9.4 Rerun-normalization is forbidden (§11)

A clean canonical gate must **not** depend on rerunning a previously failed test or gate.
The prior working note that said to "re-run the affected file / the gate once, not
normalize" is **removed** — that *was* the rerun-normalization the closure rule forbids.
The gate is now green on first attempt because the contention that caused the flake is
gone, not because a retry is tolerated. Evidence is **consecutive first-attempt** green
(a failure resets the count; a failed→isolated-pass→rerun sequence is NOT accepted).

### 9.5 Consecutive first-attempt evidence

_From the reproduction-stress campaign (`argon2_stress.sh`, 2026-08-09) run from a
verified-clean process state. The harness records every FIRST-attempt exit status and
HALTS on any failure (a failed→isolated-pass→rerun sequence is NOT accepted). Nothing
below was rerun._

| Stage | What ran | Result |
|---|---|---|
| Pre/Post | stray `yes` / `flutter_tester` before & after | 0 / 0 both — no leaked procs |
| **1 — serialized crypto derivation** | `flutter test --tags crypto-prod --concurrency=1 <2 tagged files>`, **x10** | **10/10 first-attempt PASS** (exit 0; 35–69 s each; 0 `Segment processing timeout`) |
| **2a — order (random seed)** | crypto stage `--test-randomize-ordering-seed=random`, x2 | PASS, PASS |
| **2b — order (reversed files)** | `backup_payload_limit` before `backup_envelope_v3` | PASS |
| **2c — bulk parallel** | `database_key_state` + `database_lease` under `--exclude-tags crypto-prod`, random seed | PASS |
| **3 — full canonical gate** | `bash tools/ci_gates.sh`, **x3** | **3/3 first-attempt PASS** (exit 0; ~1171 s / ~1707 s / ~1497 s; each `{"passed":10,"failed":0,"unavailable":0}`) |

A separately-run full canonical gate immediately after implementation was **also**
first-attempt green (10/10), giving **4** first-attempt-green full gates over the campaign.
Aggregate: **20x "All tests passed!"**, **3x "ALL LOCAL GATES PASSED"**, **0** flutter
failures, **0** gate failures, **0** `HALT`, **0** reruns. The `--concurrency=1` derive
time sits two orders of magnitude under the internal 10 s per-segment ceiling — the
contention margin that made the flake possible is gone.

**The AUTHORITATIVE closure run is the canonical gate executed once from the committed,
clean tree** (HEAD hash recorded in the Batch-2 closure report and the ledger). The
campaign above **predates** the `production_kdf_contract_test.dart` addition (it exercised
the first 2 `crypto-prod` files); that third file's 2 tests were added and independently
verified afterward, and the authoritative committed-tree gate exercises **all 3**
`crypto-prod` files. Final canonical accounting (committed-tree run): Flutter bulk
**`--exclude-tags crypto-prod`** + Flutter serialized **`--tags crypto-prod`** = the whole
Flutter suite, disjoint, nothing dropped or double-counted (exact counts in the closure
report). The canonical gate is now **10** mandatory stages (was 9): the single
`flutter test` step became the mandatory pair 4a bulk + 4b serialized-crypto.

The original red-gate history (2 Argon2 `Segment processing timeout` failures on the
first authoritative Batch-2 gate) is intentionally preserved here and in the ledger — it
is the defect this section closes, not something to erase.
