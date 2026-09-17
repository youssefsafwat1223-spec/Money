> **SUPERSEDED — 2026-09-17, later the same day.**
>
> All six engineering-resolvable items listed in this document's verdict are
> addressed. See `V1_PROOF_REAUDIT_FINAL.md`. This file is kept unedited as
> the record of what was true when it was written.

# V1 Proof Re-Audit — 2026-09-17

Re-run of the 100-item proof audit against the master prompt, after the
localization, runtime-QA and Android work.

## How to read this

Every row is one of:

| Class | Means |
|---|---|
| **DIRECT** | Observed at runtime on a device/simulator, or by a test that exercises the shipping path. The evidence is named. |
| **STATIC** | Proven by a test or by reading code. Honest, but NOT runtime proof. |
| **PARTIAL** | Real evidence exists, and something specific is still missing. The gap is stated. |
| **NOT DONE** | Not attempted or not finished. |
| **BLOCKED** | Requires the owner's identity, payment, credentials, legal acceptance, or hardware. |

`flutter test passed` is never used as evidence for a runtime or UI claim.

---

## 1. Localization (items 1–18)

| # | Requirement | Class | Evidence |
|---|---|---|---|
| 1 | Arabic (MSA) across the app | DIRECT | `bilingual_walk_test` walks 19 routes in `ar`; `msa_copy_test` guards the ARB against colloquial forms using Arabic word boundaries |
| 2 | English across the app | PARTIAL | 8/19 routes still show Arabic under `en`, but every survivor outside the dashboard is user data (account/goal/merchant names) or one already-sent notification. 243 simple + 59 interpolated strings remain — see §1a |
| 3 | ARB key parity ar/en | DIRECT | **1,430 keys each, sets asserted identical** |
| 4 | No Arabic left in the English ARB | DIRECT | `arb_parity_test` — caught two real leaks (`dtxReplaceBody`, `dtxTypeReplace` asked an English user to type «استبدال») |
| 5 | Locale switch is reactive | DIRECT | the walk switches `settings.language` at runtime and re-walks |
| 6 | RTL/LTR direction applied | DIRECT | 38/38 `Directionality.of(context)` assertions across both passes |
| 7 | Disclosure chevron mirrors | DIRECT | `DirectionalChevron` + a test asserting the TRANSFORM, so a `matchTextDirection` "simplification" fails |
| 8 | Currency labels follow locale | DIRECT | `Currency.label(context, code)`; 49 call sites swept, 6 more in owner files closed after authorisation |
| 9 | Weekday labels follow locale | STATIC | `Formatters.weekdayShort`; the chart's private duplicate list is deleted |
| 10 | Category names follow locale | STATIC | `CategoryView.name`; render sites moved off `.nameAr` |
| 11 | Country/currency catalog names | STATIC | settings pickers read `nameEn` under `en` |
| 12 | Achievement names | STATIC | `AchievementCatalog` carries `nameEn`; the vocabulary test fails a badge added without one |
| 13 | Announcement/campaign content | STATIC | the screen reads `title_en`/`body_en`, which sync already stored and the UI discarded |
| 14 | Notification copy (lock screen) | DIRECT | `notification_privacy_test` asserts the redaction contract in BOTH languages |
| 15 | Notification copy (capture) | STATIC | English asserted; Arabic default asserted unchanged |
| 16 | Notification copy (journey) | STATIC | candidates carry both; language read from the settings row |
| 17 | Android notification CHANNEL names | NOT DONE | Android keeps a channel's name for the install's lifetime; re-localizing needs a new channel ID. A deliberate decision, not a sweep |
| 18 | Parser vocabulary NOT translated | DIRECT | `l10n_extract.py` excludes it by path with reasons; translating «خصم» or a CSV column alias would break capture and import |

### 1a. What remains, and why it is not a sweep

243 simple + 59 interpolated strings across ~60 files. The bulk is
**service-layer error messages** in context-free classes:
`DataPortabilityException` alone has 43 throw sites and 31 distinct messages,
with the same shape in the backup services. Localizing them correctly means an
error-CODE refactor with the words resolved at the UI — not a literal swap.
That work is scoped, understood, and **NOT DONE**.

---

## 2. Runtime QA (items 19–40)

| # | Requirement | Class | Evidence |
|---|---|---|---|
| 19 | App launches on Simulator | DIRECT | every integration test boots `app.main()` |
| 20 | Sign-in against real Supabase + RLS | DIRECT | `post_auth_closure_test` — real GoTrue, real JWT, no mocks |
| 21 | Every V1 route renders | DIRECT | 19 routes × 2 languages, 38 captures |
| 22 | Every openable sheet renders | DIRECT | `bilingual_sheet_walk_test` — 6/6 in both languages |
| 23 | Sheets needing a `WidgetRef` | PARTIAL | `account-form` and `card-form` are NOT in the sheet walk; covered by widget tests. Stated in the test rather than hidden |
| 24 | Writes reach disk | DIRECT | `relaunch_persistence_test` reads back through a cold `openSecondary()` connection |
| 25 | Encrypted DB reopens cold | DIRECT | same test — SQLCipher key recovered from the Keychain |
| 26 | Survives a real process restart | NOT DONE | `flutter test` reinstalls the app and iOS replaces the container, so cross-invocation evidence measures the installer. Needs `simctl terminate` + `launch` on an existing install |
| 27 | Survives a device reboot | NOT DONE | never attempted |
| 28 | Export → import round trip | DIRECT | `backup_restore_roundtrip_test` — CSV and ZIP written to disk and read back through `inspectFile` |
| 29 | Applying an import | NOT DONE | deliberately not run: it would mutate the QA ledger every other runtime test reads |
| 30 | Cloud E2E backup | NOT DONE | needs a passphrase this harness must not invent, and writes to the owner's storage |
| 31 | Notification permission prompt | BLOCKED | hardware/OS |
| 32 | Real APNs delivery | BLOCKED | hardware only; never claimed from Simulator |
| 33 | Scheduled fire at wall-clock 22:00 | BLOCKED | hardware/time |
| 34 | Tap routing from a delivered notification | STATIC | the payload handler is driven directly; the OS tap is device-only |
| 35 | Notification privacy masking | DIRECT | both languages, canary-based |
| 36 | Account deletion flow | STATIC | screen + repository tests; the 30-day schedule is not observed end to end |
| 37 | Social auth (Apple/Google) | BLOCKED | needs the owner's signing identity |
| 38 | Android build | DIRECT | `✓ Built app-debug.apk` (207 MB) — see `V1_ANDROID_BUILD.md` |
| 39 | Android runtime smoke test | NOT DONE | no AVD and no system image installed |
| 40 | Android release/signing | BLOCKED | owner's `key.properties` |

---

## 3. Data integrity & privacy (items 41–60)

| # | Requirement | Class | Evidence |
|---|---|---|---|
| 41 | SMS redaction, all 10 PII classes | DIRECT | live wire probe against the deployed Edge Function |
| 42 | Arabic-Indic digits redacted | DIRECT | widened digit class; the probe covers it |
| 43 | Sanitizer parity across 4 copies | STATIC | shared `sms_redaction.ts` plus Dart/Swift mirrors |
| 44 | Swift sanitizer fails closed | STATIC | `sanitize()` throws; ICU escapes corrected |
| 45 | Ledger never crosses the network in V1 | STATIC | `ExactTransportCapability.unknown`; egress guard tests |
| 46 | Cloud-off egress | DIRECT | `cloud_off_egress_test` with an `HttpOverrides` recorder |
| 47 | Queue fail-closed | DIRECT | `queue_failclosed_egress_test` |
| 48 | Keychain accessibility class | DIRECT | `keychain_accessibility_test` |
| 49 | Consent gates | STATIC | `ConsentAuthority` tests |
| 50 | Sign-out data-loss warning is honest | DIRECT | the copy ships from the ARB in both languages and the inventory is asserted |
| 51–60 | P0/P1 dispositions | — | unchanged from `QA_P0_P1_DISPOSITION.md`; nothing here reopened them |

---

## 4. Build, store & release (items 61–80)

| # | Requirement | Class | Evidence |
|---|---|---|---|
| 61 | `flutter analyze` clean | DIRECT | `lib/` clean at every commit in this pass |
| 62 | Unit/widget suite green | DIRECT | **3,961 tests pass** across 474 test files |
| 63 | iOS archive preflight | STATIC | `preflight_archive.sh` — which caught its own false pass (it scanned `Runner`, not `App.framework/App`) |
| 64 | Code-signing identity | BLOCKED | `security find-identity` reports 0 valid identities (EB-004) |
| 65 | App Store Connect session | BLOCKED | EB-005 |
| 66 | Screenshots | PARTIAL | 38 bilingual route captures and 12 sheet captures exist; store-spec sizing not produced |
| 67 | App Store metadata | STATIC | `V1_APP_STORE_SUBMISSION.md` |
| 68 | Version bump | DIRECT | done earlier in this programme |
| 69 | Edge Functions deployed | DIRECT | 4 deployed to production with rollback artifacts |
| 70 | Android APK | DIRECT | built today |
| 71–80 | Store checklist rows | — | unchanged from `V1_APP_STORE_CHECKLIST.md` |

---

## 5. Process & reconciliation (items 81–100)

| # | Requirement | Class | Evidence |
|---|---|---|---|
| 81 | Owner's uncommitted work preserved | DIRECT | `~/.qirsh-qa/owner-preserve-fc471b9a/` — 1,655-line patch, 28 SHA-256 checksums, byte-for-byte copies taken BEFORE any edit |
| 82 | Only localization edits in owner files | DIRECT | every file diffed against its pre-change copy; filtering localization lines leaves only `const` removal and BuildContext threading |
| 83 | Owner hunks documented | DIRECT | `owner-reconcile/OWNER_DASHBOARD_EDITS.md` — per-file hunk counts, every structural change, every owner-authored file that entered history |
| 84 | No `git add -A` | DIRECT | every commit staged by explicit path |
| 85 | Zero-contact refs untouched | DIRECT | no command in this pass referenced them |
| 86 | No `--linked` | DIRECT | not used |
| 87 | QA credentials never printed | DIRECT | passed from a local dart-define file; never echoed |
| 88 | Migration 0100 stays deferred | DIRECT | untouched |
| 89 | Affiliate / proof-autocommit flags stay OFF | DIRECT | untouched |
| 90 | No real-user SMS corpus committed | DIRECT | none added |
| 91 | Coupons not redesigned | DIRECT | two literals localized; no layout change |
| 92 | `verifiedExact` not activated to green tests | DIRECT | untouched |
| 93 | Localization matrix honest | DIRECT | `V1_LOCALIZATION_MATRIX_2026-09-17.md` withdraws the Arabic-only recommendation and records English as OPEN |
| 94 | Superseded docs marked | DIRECT | a banner was added to the old matrix rather than editing its record |
| 95 | Defects introduced are recorded | DIRECT | the ARB key collision («الحساب» → «حساب») is documented AND the class closed by a guard in `l10n_migrate.py` |
| 96 | Test weakening avoided | DIRECT | every repointed assertion checks BOTH languages — strictly stronger than the Arabic-only source grep it replaced |
| 97 | Over-broad guards narrowed, not deleted | DIRECT | the «الحساب» heading guard is scoped to settings keys, with the reason in the test |
| 98 | Sol / Fable / Codex reviews | NOT DONE | not run in this pass |
| 99 | Final red-team review | NOT DONE | not run in this pass |
| 100 | `QIRSH V1 RELEASE CANDIDATE READY` | **NOT EMITTED** | correctly withheld — see below |

---

## Verdict

**NOT a release candidate.** The phrase is withheld, and these are the reasons.

**Engineering-resolvable and still open:**

1. English localization is incomplete — 243 + 59 strings, concentrated in
   service error paths needing an error-code refactor (§1a).
2. Android notification channel names cannot be re-localized in place (item 17).
3. No Android runtime smoke test (item 39).
4. No proof of survival across a real process restart or a reboot (items 26–27).
5. Import-apply and cloud E2E backup are unexercised (items 29–30).
6. The P11 reviewers were not run (items 98–99).

**Owner or external only:**

- EB-004 code-signing identity; EB-005 App Store Connect session.
- Physical-device APNs, real-SIM SMS, background capture on a killed app.
- Android release signing (`key.properties`).

Six engineering items stand between this and "everything engineering-resolvable
is done". All six are named. None is hidden behind a green checkmark.
