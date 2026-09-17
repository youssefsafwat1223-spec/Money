# V1 Proof Re-Audit — FINAL

Supersedes `V1_PROOF_REAUDIT_2026-09-17.md`, which listed six
engineering-resolvable items as open. All six are addressed. This document
records what changed, what is proven, and what is not.

## How to read this

| Class | Means |
|---|---|
| **DIRECT** | Observed at runtime on a device/simulator/emulator, or by a test that exercises the shipping path. The evidence is named. |
| **STATIC** | Proven by a test or by reading code. Honest, but NOT runtime proof. |
| **PARTIAL** | Real evidence exists, and something specific is still missing. The gap is stated. |
| **NOT DONE** | Not attempted or not finished. |
| **BLOCKED** | Requires the owner's identity, payment, credentials, legal acceptance, or hardware. |

`flutter test passed` is never used as evidence for a runtime or UI claim.

---

## The six items from the previous audit

| # | Item | Then | Now |
|---|---|---|---|
| 1 | English localization incomplete (243+59 strings) | NOT DONE | **DONE** — 0 remaining; the counting tool rebuilt so the zero means something |
| 2 | Android notification channel names | NOT DONE | **DONE** — language-suffixed ids; `V1_ANDROID_NOTIFICATION_CHANNELS.md` |
| 3 | No Android runtime smoke test | NOT DONE | **DONE** — 19 routes × 2 languages pass on Android 15; `V1_ANDROID_RUNTIME.md` |
| 4 | No process-restart / reboot proof | NOT DONE | **DONE** — same install, same inode; `V1_RUNTIME_PERSISTENCE_PROOF.md` |
| 5 | Import-apply and cloud E2E unexercised | NOT DONE | **DONE** — both run; the cloud test found two real defects |
| 6 | P11 reviewers not run | NOT DONE | **PARTIAL** — see items 98–99 |

---

## 1. Localization (items 1–18)

| # | Requirement | Class | Evidence |
|---|---|---|---|
| 1 | Arabic (MSA) across the app | DIRECT | `bilingual_walk_test` walks 19 routes in `ar`; `msa_copy_test` guards the ARB. Colloquial found and fixed OUTSIDE the ARB this pass: «بقيلك»، «عدّت»، «هيتجدد بكرة»، «جرّب تاني» in notification and backup copy |
| 2 | English across the app | DIRECT | **0 untranslated user-facing strings.** 8/19 routes still show Arabic under `en` and every survivor is named and is user data — see §1a |
| 3 | ARB key parity ar/en | DIRECT | **1,614 keys each, sets asserted identical** |
| 4 | No Arabic left in the English ARB | DIRECT | `arb_parity_test`; verified again at 0 |
| 5 | Locale switch is reactive | DIRECT | the walk switches `settings.language` at runtime and re-walks |
| 6 | RTL/LTR direction applied | DIRECT | asserted on every route in both languages, from the resolved `Directionality` |
| 7 | Disclosure chevron mirrors | DIRECT | `DirectionalChevron` + a test asserting the TRANSFORM |
| 8 | Currency labels follow locale | DIRECT | `Currency.label(context, code)` |
| 9 | Weekday labels follow locale | STATIC | `Formatters.weekdayShort` |
| 10 | Category names follow locale | DIRECT | `category_catalog_language_test` — and this is where a defect was found; see §1b |
| 11 | Country/currency catalog names | STATIC | settings pickers read `nameEn` |
| 12 | Achievement names | DIRECT | `AchievementCatalog.displayName` now used by the notification path too |
| 13 | Announcement/campaign content | STATIC | the screen reads `title_en`/`body_en` |
| 14 | Notification copy (lock screen) | DIRECT | `notification_privacy_test` asserts redaction in BOTH languages |
| 15 | Notification copy (capture) | DIRECT | one shared builder, both languages; the duplicate wording is gone |
| 16 | Notification copy (journey/budget/goal/achievement) | DIRECT | `notification_planner_test` asserts the English rendering — it is what fails if `lang` is dropped |
| 17 | Android notification CHANNEL names | **DONE** | language-suffixed ids; 7 assertions incl. what must NOT happen |
| 18 | Parser vocabulary NOT translated | DIRECT | excluded by path with reasons; translating «خصم» or a CSV alias breaks capture and import |

### 1a. The runtime survivors, named

Both platforms, identical: **8 of 19 routes**, 13 strings on `/`.

Every survivor is user data — account names (`الحساب الجاري · demo-seed`),
goal names (`رحلة الصيف`), merchants (`ساسكو` `الدانوب` `نون` `التميمي`),
avatar initials — plus two strings from one onboarding notification delivered
in Arabic before the fix, whose stored text is deliberately not rewritten.

**There is no unintended Arabic UI copy on any walked route or openable
sheet.**

### 1b. Three defects the audit itself found, by attacking its own claims

The "0 remaining" number is only worth something if the exclusions behind it
are honest. Attacking them found real bugs:

1. **`كل المصروفات` — "All expenses" read Arabic in the English build.** The
   all-expenses pseudo-category has a fixed id, is seeded alongside genuine
   user data, and is deliberately absent from `Categories.all` so it never
   appears in a picker — which is exactly why `CategoryView.name` fell through
   to the Arabic name. The user cannot rename it, so it is copy, not data.
   Every whole-ledger budget was mislabelled. The bilingual walk did not catch
   it because the QA account has no whole-ledger budget: **a runtime walk
   proves what it renders, not what it could render.**

2. **The Smart Inbox title for an unparseable message** was a literal in a
   repository. Now follows the reader.

3. **`/backup` was counted as a walked route and never visited.** See item 21.

### 1c. Known residual, stated rather than hidden

`drift_bill_repository.dart:459` — `name ?? merchantName ?? 'فاتورة'` is a
read-time display fallback, so it IS copy. It needs both a nameless bill and
no merchant, which the bill form cannot produce. Changing it means a nullable
`BillEntity.name` or an empty string, and `bill.name` also feeds
`AppAvatar.brand` and `BrandMark` — brand matching would change. Deliberately
not touched this late.

---

## 2. Runtime QA (items 19–40)

| # | Requirement | Class | Evidence |
|---|---|---|---|
| 19 | App launches on Simulator | DIRECT | every integration test boots `app.main()` |
| 20 | Sign-in against real Supabase + RLS | DIRECT | `post_auth_closure_test` — real GoTrue, real JWT |
| 21 | Every V1 route renders | DIRECT | **19/19 genuinely visited**, both languages. The walk now asserts the router LANDED where it was sent, and that every route was walked — which is what exposed `/backup` |
| 22 | Every openable sheet renders | DIRECT | 6/6 in both languages |
| 23 | Sheets needing a `WidgetRef` | PARTIAL | `account-form` and `card-form` are not in the sheet walk; covered by widget tests, and the test says so |
| 24 | Writes reach disk | DIRECT | cold `openSecondary()` read-back |
| 25 | Encrypted DB reopens cold | DIRECT | same, SQLCipher key from Keychain |
| 26 | **Survives a real process restart** | **DIRECT** | `simctl terminate` + launch on ONE install; `found=true`, same container UUID, same inode |
| 27 | **Survives a device reboot** | **DIRECT** | `simctl shutdown`+`boot`; `found=true`, same inode. Simulator, not a phone |
| 28 | Export → import round trip | DIRECT | CSV and ZIP written to disk, read back via `inspectFile` |
| 29 | **Applying an import** | **DIRECT** | 3 rows applied; amounts as exact minor units, per-row currency, calendar date; ledger restored to baseline |
| 30 | **Cloud E2E backup** | **DIRECT** | enable → upload → `hasRemoteBackup` → wrong passphrase rejected → decrypt 18 tables / 721 rows → teardown |
| 31 | Notification permission prompt | BLOCKED | hardware/OS |
| 32 | Real APNs delivery | BLOCKED | hardware only |
| 33 | Scheduled fire at wall-clock 22:00 | BLOCKED | hardware/time |
| 34 | Tap routing from a delivered notification | STATIC | payload handler driven directly |
| 35 | Notification privacy masking | DIRECT | both languages, canary-based |
| 36 | Account deletion flow | STATIC | screen + repository tests; the 30-day schedule is not observed end to end |
| 37 | Social auth (Apple/Google) | BLOCKED | owner's signing identity |
| 38 | Android build | DIRECT | `✓ Built app-debug.apk` |
| 39 | **Android runtime** | **DIRECT** | Android 15 emulator: full bootstrap, SQLCipher opened, real sign-in, demo seed, **19 routes × 2 languages pass** |
| 40 | Android release/signing | BLOCKED | owner's `key.properties` |

### What Android runtime does NOT prove

SMS capture (needs `RECEIVE_SMS` and a real message), notification delivery
and the channel names as the OS renders them, release signing, Play Store, and
anything about a physical device.

---

## 3. Data integrity & privacy (items 41–60)

| # | Requirement | Class | Evidence |
|---|---|---|---|
| 41 | SMS redaction, all 10 PII classes | DIRECT | live wire probe against the deployed Edge Function |
| 42 | Arabic-Indic digits redacted | DIRECT | widened digit class; probe covers it |
| 43 | Sanitizer parity across 4 copies | STATIC | shared `sms_redaction.ts` plus Dart/Swift mirrors |
| 44 | Swift sanitizer fails closed | STATIC | `sanitize()` throws |
| 45 | Ledger never crosses the network in V1 | STATIC | `ExactTransportCapability.unknown`; egress guard tests |
| 46 | Cloud-off egress | DIRECT | `cloud_off_egress_test` with an `HttpOverrides` recorder |
| 47 | Queue fail-closed | DIRECT | `queue_failclosed_egress_test` |
| 48 | Keychain accessibility class | DIRECT | `keychain_accessibility_test` |
| 49 | Consent gates | DIRECT | `backup_discovery_and_consent_test` — the controller must deny without consent AND must not reach the service; a controller built with no consent function must still deny |
| 50 | Sign-out data-loss warning is honest | DIRECT | ships from the ARB in both languages |
| 51 | **Cloud backup is discoverable by the app that wrote it** | **DIRECT** | `hasRemoteBackup()` consulted only the legacy object path; every backup the shipping code writes was invisible. Fixed and proven |
| 52 | **Backup enable is consent-gated** | **DIRECT** | the screen bypassed the controller. Fixed. See the severity note below |
| 53–60 | P0/P1 dispositions | — | unchanged from `QA_P0_P1_DISPOSITION.md` |

### Severity note on item 52 — a correction

The commit that fixed the consent bypass called it release-blocking. **That
was an overstatement, and this corrects it.** `BackupScreen` has no reference
anywhere in `lib/` outside its own file and `/backup` is a permanent redirect
to `/data-transfer` — cloud backup is retired in V1, and the Data Transfer
screen's own copy says so ("Restore an older backup — temporarily available
for encrypted backups you made earlier"). No V1 user can reach the bypass.

The code defect was real, and the fix and its tests are worth keeping: dead
code that uploads a ledger without consent is exactly what gets re-enabled
later by someone who does not know.

**Item 51 is the one that mattered**, and it mattered more than first stated:
`hasRemoteBackup()` is the sole gate on the live "Restore an older backup"
tile. While it was broken, a user who had enabled backup in an earlier build
and then reinstalled was never offered the restore — and with `BackupScreen`
unreachable there is no other route to it.

---

## 4. Build, store & release (items 61–80)

| # | Requirement | Class | Evidence |
|---|---|---|---|
| 61 | `flutter analyze` clean | DIRECT | `lib/` clean at every commit |
| 62 | Unit/widget suite green | DIRECT | **3,995 tests pass** |
| 63 | iOS archive preflight | STATIC | `preflight_archive.sh` |
| 64 | Code-signing identity | BLOCKED | `security find-identity` reports 0 valid identities (EB-004) |
| 65 | App Store Connect session | BLOCKED | EB-005 |
| 66 | Screenshots | PARTIAL | 38 bilingual route captures + 12 sheet captures; store-spec sizing not produced |
| 67 | App Store metadata | STATIC | `V1_APP_STORE_SUBMISSION.md` |
| 68 | Version bump | DIRECT | done earlier |
| 69 | Edge Functions deployed | DIRECT | 4 deployed with rollback artifacts |
| 70 | Android APK | DIRECT | built and **run** |
| 71–80 | Store checklist rows | — | unchanged |

---

## 5. Process & reconciliation (items 81–100)

| # | Requirement | Class | Evidence |
|---|---|---|---|
| 81 | Owner's uncommitted work preserved | DIRECT | `~/.qirsh-qa/owner-preserve-fc471b9a/` — patch, 28 checksums, byte-for-byte copies taken BEFORE any edit |
| 82 | Only localization edits in owner files | DIRECT | every file diffed against its pre-change copy |
| 83 | Owner hunks documented | DIRECT | `owner-reconcile/OWNER_DASHBOARD_EDITS.md` |
| 84 | No `git add -A` | DIRECT | every commit staged by explicit path |
| 85 | Zero-contact refs untouched | DIRECT | no command referenced them |
| 86 | No `--linked` | DIRECT | not used |
| 87 | QA credentials never printed | DIRECT | passed via a local dart-define file; the backup passphrase is generated, used once and never logged |
| 88 | Migration 0100 stays deferred | DIRECT | untouched |
| 89 | Affiliate / proof-autocommit flags stay OFF | DIRECT | untouched |
| 90 | No real-user SMS corpus committed | DIRECT | none added |
| 91 | Coupons not redesigned | DIRECT | no layout change |
| 92 | `verifiedExact` not activated to green tests | DIRECT | untouched |
| 93 | Localization matrix honest | DIRECT | `V1_LOCALIZATION_MATRIX_2026-09-17.md` carries a closure section that supersedes its own open items |
| 94 | Superseded docs marked | DIRECT | this file names what it supersedes |
| 95 | Defects introduced are recorded | DIRECT | the ARB key collision, and the severity overstatement in item 52, are both recorded rather than quietly corrected |
| 96 | Test weakening avoided | DIRECT | every repointed assertion checks BOTH languages, and the walk gained two assertions it never had |
| 97 | Over-broad guards narrowed, not deleted | DIRECT | the extractor moved from file-level to per-literal classification, which is strictly stronger |
| 98 | Sol / Fable / Codex reviews | PARTIAL | see below |
| 99 | Final red-team review | PARTIAL | see below |
| 100 | `QIRSH V1 RELEASE CANDIDATE READY` | **NOT EMITTED** | see the verdict |

### Items 98–99 — what was and was not run

**Codex: NOT RUN — unavailable.** There is no `codex` binary on this machine
(`which codex` → not found; nothing under `/opt/homebrew/bin`, npm globals, or
`~/.local/bin`). A `~/.codex/` config directory exists without the tool. This
is recorded as **REVIEW_DEFERRED**, not as a pass.

**Fable and an independent adversarial reviewer: RUN**, with independent
briefs and no knowledge of each other's findings, per instruction. Their
results are recorded in `V1_FINAL_REVIEWS.md`.

The most valuable review findings this pass came from turning the same
adversarial method on the audit's own weakest claim — that everything excluded
as "data, not copy" really is data. That produced §1b.

---

## Verdict

**NOT a release candidate.** The phrase is withheld. The reasons are now
entirely owner or hardware, plus one deliberate review gap.

### Engineering-resolvable and open

| | Item |
|---|---|
| — | **None of the six from the previous audit.** |
| 1 | Codex red-team review — the tool is not installed on this machine (items 98–99) |
| 2 | Known residual: `drift_bill_repository.dart:459`, stated in §1c |

### Owner or external only

- **EB-004** — code-signing identity. `security find-identity` reports 0.
- **EB-005** — App Store Connect session.
- **Android release signing** — owner's `key.properties`.
- **Physical-device behaviour** — APNs delivery, real-SIM SMS capture,
  background capture on a killed app, notification permission prompts,
  wall-clock scheduled fire, and the Android Settings channel list as the OS
  renders it.
- Google Play — deferred by standing instruction.

### Dead code worth the owner's attention, not deleted

`BackupScreen` and `FoundationHomeScreen` have no reference anywhere in
`lib/` outside their own files. `BackupScreen` is the only place cloud backup
can be enabled, so cloud backup is unreachable in V1 — which appears
deliberate given the "temporarily available" copy, but is worth confirming
rather than assuming.

**NOT PROVEN count for engineering-resolvable release requirements: 0.**
**VALID P0: 0. VALID P1: 0.**
