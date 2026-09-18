# V1 Localization Matrix — 2026-09-17

**This supersedes the verdict in `V1_LOCALIZATION_MATRIX.md`.**

## 0. REACHABILITY — closed 2026-09-18

Everything below this section measures how *well* the app speaks English. None
of it measured whether a user can **ask** it to, and the answer was no.

`user_settings.language` is created as `'ar'`. `SaveLanguageUseCase` — the only
code in `lib/` that writes that column — had **zero callers**:

```
grep -rn "saveLanguageUseCaseProvider" lib/ | grep -v app_providers   → nothing
grep -rn "SaveLanguageUseCase"        lib/ | grep -v usecases|providers → nothing
```

No control in Settings, no ARB copy for one, no onboarding step, no migration,
and nothing seeding from the device locale — `localeProvider` reads the settings
row and nothing else. **Every V1 user ran in Arabic, permanently.** The English
localization was complete and unreachable.

That also changes how to read the rest of this document. Every bilingual walk,
matrix and capture in this programme set the language by writing
`settings.language` directly — §1 below says so — which is the same non-shipping
path. The measurements are sound; the state they measured was one no user could
enter.

### What shipped

**Settings → Language**, offering **العربية** and **English** as endonyms, going
through `SaveLanguageUseCase` — the app's real write path, still the only one.
Arabic remains the default for new users; the row is still created `'ar'` and no
default-language policy changed.

`localeProvider` watches `userSettingsProvider`, so choosing re-renders copy,
direction, pickers and the material delegates without a restart.

### Evidence

| Check | Where |
|---|---|
| The control exists, offers both languages, and goes through the real write path | `test/features/settings/language_selector_test.dart` |
| What Settings writes is what `localeProvider` reads | same file, last test |
| A language chosen in Settings survives process termination and relaunch, same install, both directions | `integration_test/language_restart_persistence_test.dart` + `tool/language_restart_proof.sh` |
| The cold-start unlock prompt follows the persisted language | `test/core/security/app_lock_prompt_language_test.dart` (fails against the pre-fix gate) and the `verify` phase of the device proof |

Device evidence, numbers and the residual gaps: `V1_LANGUAGE_PERSISTENCE_INVESTIGATION.md`.

---

## 0. The recommendation that is withdrawn

The previous matrix recommended shipping V1 **Arabic-only** and not claiming
English support. The owner has rejected that reading of the product contract:

> The product contract is still: Arabic (Modern Standard Arabic) + English.
> Do NOT declare localization closed and do NOT downgrade Qirsh V1 to
> Arabic-only.

That is the owner's call to make, and it is the right one — the app is not
Arabic-only by design, it was Arabic-only by omission. **English remains an
OPEN V1 requirement.** Nothing below should be read as closing it.

---

## 1. Runtime evidence — the only measure that counts

`integration_test/bilingual_walk_test.dart` drives every V1 route on the
Simulator in `ar`, switches `settings.language` to `en` (the value
`localeProvider` actually reads), and drives them again, counting Arabic-script
strings that survive the switch.

| Measure | 2026-09-16 | 2026-09-17 |
|---|---|---|
| Routes walked, each language | 19 | 19 |
| `Directionality` assertions | 38 / 38 | 38 / 38 |
| **Routes still rendering Arabic under `en`** | **15 / 19** | **8 / 19** |
| Arabic strings surviving, all routes | 422+ | **103** |
| Arabic strings surviving, **excluding the dashboard** | 334+ | **17** |

Final walk, after the last closures: **8 of 19**. `/achievements`, `/privacy`,
`/backup`, `/data-transfer`, `/paste`, `/settings`, `/profile`, `/reports`
(copy), `/transactions` and `/plans` render **no** unintended Arabic in English.

Per route:

| Route | Before | After | Note |
|---|---|---|---|
| `/` | 88 | **86** | owner-dirty, deliberately untouched — see §4 |
| `/settings` | 82 | **0** | |
| `/profile` | 82 | **0** | same screen as `/settings` |
| `/budgets` | 38 | **2** | both are account names (user data) |
| `/reports` | 33 | **1** | a merchant name (user data) |
| `/achievements` | 27 | **9 → 0** | badge names; closed after this walk |
| `/subscriptions` | 20 | **5** | account + merchant names (user data) |
| `/goals` | 18 | **2** | goal names (user data) |
| `/cards` | 18 | **1** | account name (user data) |
| `/accounts` | 16 | **4** | account names (user data) |
| `/privacy` | 12 | **0** | |
| `/backup` | 9 | **0** | |
| `/data-transfer` | 9 | **0** | |
| `/announcements` | 7 | **2 → 0** | onboarding journey copy; closed after this walk |
| `/paste` | 5 | **1 → 0** | field hint; closed after this walk |

### The 17 remaining survivors, every one accounted for

Outside the dashboard, **no unintended Arabic UI copy remains**. All 17 are
one of two things:

- **15 are user data**, correctly Arabic: account names (`الحساب الجاري`,
  `محفظة النقد`, `الحساب الرئيسي`), goal names (`رحلة الصيف`, `آيفون جديد`),
  merchant names (`ستاربكس`, `كريم`, `نون`) and the avatar initials derived
  from them. Translating these would be a defect, not a fix — this is the
  owner's point 5, intentional Arabic content preserved.
- **2 are a historical notification.** The `welcome` onboarding journey was
  delivered on this simulator *before* the fix, in Arabic, and the inbox row
  stores the copy that was actually sent. `hasSentJourney('welcome')` correctly
  prevents a resend. A fresh install running in English receives the English
  copy. Freezing a notification's text at send time is right: rewriting history
  to a language the user was not using when it arrived would be the bug.

The route-level English surface is therefore **closed**, with the dashboard the
sole exception and the reason stated in §4.

---

## 2. Key counts

| | 2026-09-15 | now |
|---|---|---|
| ARB keys, `ar` / `en` | 338 / 338 | **930 / 930** |
| Key sets identical | yes | **yes** (asserted) |
| Screens with zero hardcoded user copy | 12 | **20** |

Fully migrated this pass: settings/profile, transactions, budgets,
subscriptions, reports, goals, cards, accounts, privacy, data-transfer/backup,
achievements, announcements, manual paste, transaction details, account form,
bill form (MSA pass).

---

## 3. Defects found by doing this — not translation gaps

These were *bugs*, exposed because rendering in English made them visible.

1. **Currency names were Arabic in every locale.** `Currency.arabicLabel` was
   hardwired into 68 call sites, so every amount in the English build read
   «ريال». Now `Currency.label(context, code)`, mirroring the context-taking
   shape `Formatters` already used. 49 sites swept; the rest are owner-dirty
   (§4). The English label is the ISO code deliberately: «ريال» is ambiguous
   across SAR/QAR/OMR/YER in a way `SAR` is not.

2. **Announcements and campaigns discarded their English columns.**
   `RemoteAnnouncement` and `RemoteGrowthCampaign` both carry `title_en`,
   `body_en` and `action_label_en`; the sync pulls them and the DAO stores
   them. The screen read only the Arabic ones. Not a missing translation —
   content already on the device that was never shown.

3. **The country/currency catalog did the same.** `RemoteCountry` and
   `RemoteCurrency` carry `name_en`; the settings pickers read `nameAr`
   unconditionally.

4. **Weekday labels on the spending chart had a private duplicate list.**
   `Formatters` had `_enWeekdays` all along; `spending_charts.dart` carried its
   own Arabic-only copy, so the English list could never be reached.

5. **A dialog contradicted itself for any non-SAR user.** In transaction
   details, the "add the home-currency value" dialog's TITLE was hardcoded
   «القيمة بالريال» while the field label one line below named the
   transaction's actual currency.

6. **Four hand-rolled Arabic number-agreement helpers** (`_monthsLabel`,
   `_goalDeadlineLabel`, `_dueInLabel`, `_captureGapLabel`) were top-level and
   context-free. They are ICU plurals now, with the `=1/=2/few/many` forms
   Arabic needs. The English build could never have read correctly while
   agreement lived in a Dart if-chain.

7. **The sign-out data-loss warning was Arabic-only** — the highest-stakes
   sentence in the app. An English user was told nothing about what signing out
   destroys. Same for the account-deletion warning and both consent toggles.

### A defect this work INTRODUCED, found and fixed

Reusing an ARB key whose Arabic differed from the literal being replaced
silently rewrote shipped copy — «الحساب» became «حساب» in two screens, and an
imperative «افتح» became the noun «فتح». Found by auditing every mapping
against the ARB after the fact. `tool/l10n_migrate.py` now **refuses** to reuse
a key that does not already mean the same thing, so the class is closed rather
than just the instances.

---

## 4. What is deliberately NOT done, and why

**The dashboard (`/`, 86 Arabic strings) is untouched.** Five dashboard files
carry uncommitted owner work. Per the owner's instruction —

> You modified four owner-dirty dashboard files for MSA copy. Do not lose or
> overwrite the owner's existing work.

— the currency sweep and the copy migration both skip them. This is the single
largest remaining item and it is blocked on reconciliation, not on effort. The
exact skipped call sites are listed in
`docs/v1-release/owner-reconcile/OWNER_DASHBOARD_EDITS.md`.

**Excluded from every count, and correctly so:** `lib/engine/**` (bank names,
SMS parser patterns, merchant-matching keywords — DATA, where translating a
keyword breaks the matching it exists to perform), `design_gallery` (a
developer surface), and the Arabic halves of bilingual pairs
(`Currency.arabicLabel`, `Formatters._arWeekdays`, `report_l10n._ar`,
`AchievementCatalog.nameAr`).

---

## 5. Remaining scope, measured not estimated

**106 files, 1,176 simple + 138 interpolated strings.** Ranked:

| Strings | File | Reachable from |
|---|---|---|
| 79 + 10 | `dashboard/dashboard_screen.dart` | `/` — **blocked, owner-dirty** |
| 66 | `subscriptions/bill_form_sheet.dart` | add/edit bill |
| 56 + 5 | `domain/usecases/add_transaction_usecase.dart` | error paths |
| 49 + 14 | `subscriptions/bill_details_sheet.dart` | tap a bill |
| 44 | `capture/services/local_notification_service.dart` | notifications |
| 43 + 10 | `capture/services/capture_notification_content.dart` | notifications |
| 42 | `accounts/account_form_sheet.dart` | add/edit account |
| 36 + 4 | `plans/plans_screen.dart` | `/plans` |
| 34 + 2 | `settings/planning_currency_repair_screen.dart` | repair flow |
| 31 | `reporting/ui/report_config_page.dart` | report builder |

The top-level routes are essentially done; what remains is concentrated in
**sheets, forms and notification content**, which the route walk does not
reach. Closing them needs the modal harvest, not another route walk.

### Notification copy — a platform constraint worth stating

`local_notification_service.dart` registers Android notification **channels**,
whose names Android keeps for the lifetime of the install. A channel name
cannot be re-localized after creation without a new channel ID (the existing
`capture_light_v2` suffix is evidence the codebase has already hit this).
Per-notification title/body localize freely — the onboarding journey now does,
reading `settings.language` the same way `localeProvider` does — but channel
names will need a deliberate decision, not a mechanical sweep.

---

## 6. Verdict

English localization is **OPEN**, and is a genuine unfinished V1 requirement.

What changed is its shape: it was 15 of 19 routes rendering Arabic wholesale;
it is now concentrated in the dashboard (blocked on owner reconciliation) and
in sheets/forms/notifications (unblocked, mechanical, and covered by working
tooling). The app must not be described as Arabic-only, and the App Store
listing must not claim complete English support yet either.


---

# Final state — end of the 2026-09-17 pass

Measured on the Simulator after the dashboard was closed with the owner's
authorisation, and after the service-layer error paths were localized.

| Measure | Start of the pass | End |
|---|---|---|
| Routes rendering Arabic under `en` | 15 / 19 | **8 / 19** |
| Arabic strings on `/` | 88 | **13** |
| Arabic strings, all routes | 422+ | **30** |
| Sheets rendering Arabic under `en` | never measured | **1 / 6** |
| ARB keys per language (sets identical) | 338 | **1,488** |
| Untranslated copy remaining | 1,757 + 235 | **198 + 46** |

## Every remaining runtime survivor, named

**Dashboard (13)** — all user data, correctly Arabic:
`الحساب الجاري · demo-seed · SAR` (account), `رحلة الصيف · demo-seed` (goal),
merchants `ساسكو` `الدانوب` `نون` `التميمي`, and the six avatar initials
derived from those names.

**Other routes (17)** — account names, goal names, merchant names, and two
strings from one onboarding notification that was delivered in Arabic before
the fix and whose text is stored as it was sent.

**Sheets (1)** — `ش`, an avatar initial.

**There is no unintended Arabic UI copy on any walked route or openable sheet.**

## What the 198 + 46 actually is

Not route copy. It is spread thin across ~55 files that the walks do not reach:
secondary dialogs, developer-facing surfaces, and error branches that need a
specific failure to render. The systemic clusters are closed:

- import/export failures → `DataPortabilityError` + ARB (39 codes)
- repository failures → `repoErrorMessage(context, e)` (25 call sites)
- backup states → moved to the widget (16 states)
- notifications → all three paths bilingual

## Still open, and honestly so

1. **The remaining 198 + 46.** Thin, scattered, unmeasured at runtime because
   the walks cannot reach them. Not closed.
2. **Android notification channel names.** Android keeps a channel's name for
   the lifetime of the install; re-localizing needs a new channel ID. A product
   decision, not a sweep.
3. **The `/` route is only clean because the dashboard was migrated with the
   owner's explicit authorisation.** Every hunk is recorded in
   `owner-reconcile/OWNER_DASHBOARD_EDITS.md`.

English is no longer the blocker it was. It is also not finished, and this
document does not say otherwise.

---

# Closure — 2026-09-17, later the same day

The three items left open above are closed. This section supersedes them.

## 1. The 198 + 46 is now 0 + 0 — and the zero means something

The previous count was inflated by three things it should never have counted,
and the fix is in the counting tool, not only in the code.

`tool/l10n_extract.py` used to skip whole FILES. That cannot see a new
untranslated string added to a file that is mostly fine — and
`encrypted_backup_service.dart` has 40 coded throws, so a 41st without a code
has to be reported. It now classifies **per literal**: a string whose own
statement carries the other half of its pair (`code:`, a `lang == 'en'`
branch, `if (en)`) is bilingual, not missing. 63 strings are counted that way,
each with the marker that proved it.

What is still excluded is excluded **by name, with a reason in the tool**:

| Class | Why | Examples |
|---|---|---|
| data, not copy | translating it breaks the thing it does | SMS parser keywords, CSV column aliases, CSV type keywords (`مصروف`/`مدين`), Arabic-Indic **digit tables** (`٠١٢٣٤٥٦٧٨٩`), regex character classes |
| default names written to the DB | each becomes a row the user can rename — it is their data from the moment it exists, and the ARB would overwrite a name they chose | `database_seed`, `planning_pull_service`, `drift_bill_repository` |
| debug-only | not reachable in a release build | `/design` (behind `if (kDebugMode)` in the router), `FoundationHomeScreen` (no reference outside its own file) |
| brand | deliberately Arabic in every language | `قرش` in the PDF renderer |

For `repo_exceptions.dart` a file-level exclusion would have been the weak
kind, so it ships with `repo_error_messages_test`: that asserts the domain
switch and the UI switch **agree**, in both languages. It fails when the two
DRIFT — which a grep for Arabic never could.

### What was actually left, and is now done

* The restore-confirmation dialog, the restore privacy note, the plan card's
  "from / over budget by / left", and the currency-repair confirmation had ARB
  keys added in an earlier pass and **never applied**. They were counted as
  done and were not. This is the failure mode the per-literal counting exists
  to prevent.
* **The biometric prompt.** That sheet is drawn by iOS/Android, not Flutter,
  so the string must be handed over already localized — there is no
  BuildContext inside a platform dialog.
* **`ImportIssue` got a code**, the same way `DataPortabilityException` and
  `BackupException` did. Six issues, rendered at the Data Transfer screen.
* **The transaction row's screen-reader label.** It was Arabic in every
  locale, which is worse than a visible untranslated string: a blind English
  user hears the row read out in a language they may not speak, and nothing on
  screen shows it is wrong.
* The bottom-nav tab labels, which were Arabic literals in a `static const`
  list reaching the screen reader under `en`.
* **The bootstrap app had no localizations at all.** `StartupApp` builds its
  own `MaterialApp` with no delegates, so the loading screen, the timeout and
  the database-recovery view were necessarily hardcoded Arabic, with forced
  RTL on top. It resolves against the DEVICE locale now — the saved language
  lives in the database, which is exactly what has not opened yet.

## 2. Android notification channels — decided and implemented

No longer a deferred product decision. See
`V1_ANDROID_NOTIFICATION_CHANNELS.md`. Existing ids keep their Arabic names
and are the Arabic channels; English gets `<id>_en`. Delete-and-recreate was
considered and rejected: it discards importance, sound and **whether the user
muted the channel**, and every existing install is Arabic.

Action button labels were never subject to the constraint — Android reads them
from each post — and are localized.

## 3. Runtime evidence, both platforms

| | iOS Simulator | Android 15 emulator |
|---|---|---|
| Routes walked | 19 × 2 languages | 19 × 2 languages |
| Routes with Arabic under `en` | 8/19 | 8/19 |
| Arabic on `/` | 13 | 13 |
| Direction asserted | every route | every route |
| Sheets | 6/6 open, 1 survivor | — |

The two platforms agree exactly. Getting there required one real fix to the
harness: `categoryCatalogProvider` rebuilds on a language switch and the tree
keeps the PREVIOUS catalog until that future resolves, so the first route
walked read the stale one. Android reported five Arabic category names on `/`
while `/transactions`, walked later off the same catalog, reported none. The
walk waits for the catalog to carry the active language before measuring.

Every survivor is user data: account names, goal names, merchant names, avatar
initials, and two strings from one onboarding notification delivered in Arabic
before the fix, whose stored text is deliberately not rewritten — it is a
record of what was actually shown.

One survivor was a real defect and is fixed for new installs: the first
account created during setup was named `الحساب الرئيسي` unconditionally. It is
DATA, so it is now named in the language the user is setting up in, rather
than rendered through the ARB.

## Final counts

| | |
|---|---|
| ARB keys per language | **1,614**, sets asserted identical |
| Arabic left in the English ARB | **0** |
| Untranslated user-facing strings | **0** |
| Strings counted as bilingual in place | 63 |
| Files excluded as data / bilingual / debug-only | 58 / 24 / 2 |
| Tests | **3,990 pass** |
| `flutter analyze lib` | clean |
