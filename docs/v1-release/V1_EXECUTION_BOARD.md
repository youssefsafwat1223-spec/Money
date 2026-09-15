# V1 Execution Board

States: `TODO` · `ACTIVE` · `VERIFYING` · `REVIEW` · `DONE` · `BLOCKED`

Updated 2026-09-15.

---

## Stage A — Foundation

| ID | Task | State | Evidence |
|---|---|---|---|
| A-1 | Repair the build environment (4 stale/blocked machine settings) | **DONE** | `~/.qirsh-qa/env.sh`; `flutter pub get`, `analyze`, `test` all run |
| A-2 | Baseline the suite | **DONE** | 3,876 pass / 2 skipped / 0 fail (2:59) |
| A-3 | Analyzer to zero | **DONE** | `flutter analyze` → *No issues found!* (was 25) |
| A-4 | **Restore defect: legacy backup fallback was unreachable** | **DONE** | reproduction + fix, below |
| A-5 | `destructive_phase_test.dart` cannot fail — make it assert | **DONE** | 1 → 5 `expect()`; wipe asserted, early-return hole closed, run fails if any step records FAIL |
| A-6 | Commit Stage A | **DONE** | `9cecbf42` |

### A-4 — the first real defect of this release

`BackupCrypto.decryptJson` returned `decryptJsonWithRawKey(...)` from inside its
own `try` **without awaiting it**. In Dart the implicit await then happens
outside the `try`, so the `SecretBoxAuthenticationError` raised during
decryption escaped the `on SecretBoxAuthenticationError` handler directly below
it — and the legacy-key fallback that handler exists to run was **dead code**.

Impact: a backup whose key slots unwrap correctly but whose **body** was sealed
with the older passphrase-derived key **fails to restore**, when the code was
written specifically to recover it. Restore of older backups — the exact case the
fallback was for.

Evidence: `test/core/backup/backup_crypto_test.dart` — a v2 blob with a slot
keyed to the passphrase (so the unwrap *succeeds*) wrapping the wrong key, over a
body sealed with the legacy key. Before the fix it threw
`SecretBoxAuthenticationError: SecretBox has wrong message authentication code`;
after `return await`, it restores.

Note on the reproduction: the first attempt passed for the wrong reason — the
slot secret did not match the passphrase, so it failed inside the *awaited*
unwrap and exited through a path that already worked. Only a slot whose secret
matches reaches the unreachable branch. A test that passes for the wrong reason
is worth less than no test.

### A-3 — the eight money-path warnings were the same bug shape

`unawaited_return_in_try_block` fired at eight more sites, all
`return _resolveDeleteConflict(...)` / `_resolveUpsertConflict(...)` inside a
`try` in `ledger_push_service`, `accounts_push_service`, `planning_push_service`.
Every one of those catches classifies conflicts and rethrows everything else, so
`return await` widens the catch to cover the resolver without changing what a
non-conflict error does. Checked each catch before changing it rather than
applying the lint blind.

The remaining 15 were mechanical test-file lints (`dart fix`), except two
deliberate raw-string regex concatenations which carry a targeted ignore and a
reason.

---

## Stage B — Required product changes

| ID | Task | State |
|---|---|---|
| B-1 | RC-2 — remove the streak reminder | **DONE** — `e54d1dfe` |
| B-2 | RC-1 — smoking/tobacco default category | **DONE** — `6ad087f7` |
| B-3 | RC-4 — daily reminder at 22:00 + migration off the old time | **DONE** — `ed0250ed` |
| B-4 | RC-3 — annual/year reporting | **DONE** — `41f31733` |
| B-5a | RC-5 Layer B — persistent Help surface | **DONE** — `5ef891fe` |
| B-5b | RC-5 Layer A — first-use coach marks | TODO |
| B-5c | RC-5 — guidance screenshots from final UI | TODO (Stage E) |

## Stage C — P0 closure (45 P0 + UNVERIFIED)

| ID | Task | State |
|---|---|---|
| C-1 | Authorization: `register-device` credential minting, `sync-captures` row ownership, RLS coverage, `feature_flag_overrides` write surface | TODO |
| C-2 | Privacy egress: consent gating per egress point; three divergent sanitizers | TODO |
| C-3 | Money/data loss: sign-out wipe ordering, parked-mutation destruction, restore reconcile | TODO |
| C-4 | Dedup/idempotency: canonical identity rule and its delivery paths | TODO |

## Stage D — Closure

| ID | Task | State |
|---|---|---|
| D-1 | Feature activation matrix — every flag, route, hidden surface | TODO |
| D-2 | Localization closure (AR Fusha / EN, RTL / LTR) | TODO |
| D-3 | Notification matrix | TODO |
| D-4 | App Store checklist | TODO |
| D-5 | Secret hygiene — QA defines out of build configuration | TODO |
| D-6 | Android compatibility check | TODO |

## Stage E — Release candidate — **UNBLOCKED 2026-09-15**

EB-001 was cleared by the owner (`sudo xcodebuild -license accept`). Verified:
`xcrun simctl` lists the iOS 26.5 runtime and the iPhone 17 family;
`flutter build ios --simulator --debug` produces `Runner.app`; it installs,
launches, and screenshots on `iPhone 17`. The `DEVELOPER_DIR`/`xcrun`-shim
workaround is retired — forcing CommandLineTools would now hide the Simulator.

| ID | Task | State |
|---|---|---|
| E-0 | iOS build pipeline proven end to end | **DONE** — build → install → launch → screenshot |
| E-1 | Simulator walk — every V1 surface, AR + EN, RTL + LTR | TODO |
| E-2 | UI Atlas visual acceptance | TODO |
| E-3 | Guidance screenshots from final UI | TODO (needs RC-5) |
| E-4 | Release archive + validation | TODO |


---

## Findings raised during Stage B (tracked, not yet scheduled)

| # | Finding | Severity | Note |
|---|---|---|---|
| F-1 | The local `categories` table has no `name_en`; English category names exist only in `remote_categories`, so the app renders Arabic category names in both locales | P1 | Affects all 26 categories, not just the new one. Real gap against the bilingual V1 contract. Belongs to D-2. |
| F-2 | Four duplicated `TransactionsDatePreset` label maps (`transactions_providers`, `transactions_screen`, `dashboard_screen`, `account_range_controls`) | P2 | Exhaustive switches keep them honest, so this is duplication rather than a defect. Not V1-blocking. |
| F-3 | `dashboard_screen.dart` carries ~925 lines of uncommitted owner work (a daily-allowance feature) | — | Preserved byte-identically. Only the two label lines RC-3 required were committed, because the switch is exhaustive and HEAD would not otherwise compile. |
| F-4 | No URL scheme is registered, so `qirsh://` deep links do not open | P2 | Discovered attempting a direct Simulator capture of `/help`. Worth confirming against the App Store checklist — the router accepts parameterised paths that nothing external can currently reach. |
