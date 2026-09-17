# V1 UI Visual Acceptance — 2026-09-17

A strict visual-fidelity pass against the UI Atlas and the HTML prototype.
Supersedes §5 of `V1_UI_ACCEPTANCE_MATRIX.md`, which accepted visual fidelity
on 13 route captures and explicitly did **not** claim sheets or dialogs had
been opened on a device.

## What counts as acceptance here

**Only a rendered screen that was looked at.** Per the owner's rule, none of
the following was counted:

* source inspection;
* widget tests;
* route reachability;
* a screenshot that was produced but not viewed.

Every surface below was captured on the iOS Simulator through
`flutter drive` + `test_driver/integration_test.dart`, then **opened and
examined**. Where a judgement was about colour, it was **measured** — the PNG
was decoded and the WCAG contrast ratio computed — rather than eyeballed.

Device: iPhone 17 Pro Max, iOS 26.5, 1320×2868.
Evidence: `~/.qirsh-qa/visual-2026-09-17/` — `ACCEPTED-FINAL/` (accepted
state), `VERIFY/` (post-fix re-measurement), `crop/` (contrast crops), and the
earlier `routes/ routes2/ sheets/ sheets2/ details/ details2/ settings-ovl/`
generations that show each defect before its fix.

---

## 1. Counts

| | |
|---|---|
| **Unique shipping screens inspected** | **29** — 19 parameterless routes + 9 parameterised + 1 tab-only |
| **Unique shipping sheets inspected** | **15** — 12 from the sheet walk + 3 settings overlays |
| **Unique shipping dialogs inspected** | **1** — `DLG-DESTRUCTIVE-CONFIRM`, the one design behind 12 call sites |
| **Total unique surfaces inspected** | **45** |
| Captured in **both** Arabic and English | all 45 |
| **MATCH** | **41** |
| **ACCEPTABLE INTENTIONAL DELTA** | **4** |
| **MISMATCH — FIX REQUIRED** | **0 remaining** (11 found, all fixed) |
| **NOT APPLICABLE** | **3** |
| Not inspected, stated below | 12 |

---

## 2. Screens — 29 inspected

### Parameterless routes (19)

| Surface | Atlas ID | AR | EN | Verdict |
|---|---|---|---|---|
| `/` Dashboard | `HOME-DASHBOARD` | ✔ | ✔ | MATCH (after 2 fixes) |
| `/reports` | `REPORTS-REPORTS` | ✔ | ✔ | MATCH |
| `/accounts` | `ACCOUNTS-ACCOUNTS` | ✔ | ✔ | MATCH (after 2 fixes) |
| `/budgets` | `BUDGETS-BUDGETS` | ✔ | ✔ | MATCH |
| `/goals` | `GOALS-GOALS` | ✔ | ✔ | MATCH |
| `/cards` | `CARDS-MYCARDS` | ✔ | ✔ | MATCH (after 1 fix) |
| `/subscriptions` | `SUBS-SUBSCRIPTIONS` | ✔ | ✔ | MATCH |
| `/settings` · `/profile` | `SETTINGS-SETTINGS` | ✔ | ✔ | MATCH (after 1 fix) |
| `/help` | RC-5 Layer B | ✔ | ✔ | MATCH |
| `/privacy` | `SETTINGS-PRIVACY` | ✔ | ✔ | MATCH |
| `/backup/restore` | `ONBOARDING-RESTOREPROMPT` | ✔ | ✔ | MATCH |
| `/data-transfer` | `SETTINGS-DATATRANSFER` | ✔ | ✔ | MATCH |
| `/coupons` | `COUPONS-COUPONS` | ✔ | ✔ | MATCH (empty state; not redesigned) |
| `/savings` | `COUPONS-SAVINGS` | ✔ | ✔ | MATCH (empty state) |
| `/referrals` | `REFERRALS-REFERRALS` | ✔ | ✔ | MATCH (flag-off state) |
| `/achievements` | `GAMIFICATION-ACHIEVEMENTS` | ✔ | ✔ | MATCH (after 1 fix) |
| `/announcements` | `ANNOUNCE-ANNOUNCEMENTS` | ✔ | ✔ | INTENTIONAL DELTA — see §5.1 |
| `/paste` | `CAPTURE-MANUALPASTE` | ✔ | ✔ | MATCH |
| `/help` chevrons, `/budgets` promo chevron | `DirectionalChevron` | ✔ | ✔ | MATCH — mirrors correctly |

### Parameterised routes and the tab-only screen (10)

These had **never been captured, walked or direction-checked** before today.
`bilingual_walk_test` covers only routes that take no parameter, and
`TransactionsScreen` has no route at all — it is shell tab 1.

| Surface | Atlas ID | AR | EN | Verdict |
|---|---|---|---|---|
| Transactions (tab 1) | `TRANSACTIONS-TRANSACTIONS` | ✔ | ✔ | MATCH — first capture ever |
| `/transaction/:id` | `TRANSACTIONS-TRANSACTIONDETAILS` | ✔ | ✔ | MATCH |
| `/account/:id` | `ACCOUNTS-ACCOUNTDETAIL` | ✔ | ✔ | MATCH (after 2 fixes) |
| `/card/:last4` | `CARDS-CARDDETAILS` | ✔ | ✔ | MATCH |
| `/goals/:id` | `GOALS-GOALDETAILS` | ✔ | ✔ | MATCH (after 1 fix) |
| `/goals/new` | `GOALS-GOALFORM` | ✔ | ✔ | MATCH (after 1 fix) |
| `/budgets/new` | `BUDGETS-BUDGETFORM` | ✔ | ✔ | MATCH (after 1 fix) |
| `/budgets/:id/edit` | `BUDGETS-BUDGETFORM` | ✔ | ✔ | MATCH |
| `/capture/sms-permission` | `CAPTURE-SMSPERMISSION` | ✔ | ✔ | MATCH (after 1 fix) |
| `/settings/planning-currency-repair` | `SETTINGS-PLANNINGCURRENCYREPAIR` | ✔ | ✔ | MATCH (after 2 fixes) |

---

## 3. Sheets — 15 unique designs inspected

Repeated call-sites are **not** counted separately, per the owner's
instruction. `OVL-TX-MANUAL` has six call sites and one design; it is one row.

| Surface | Atlas ID | Call sites | AR | EN | Verdict |
|---|---|---|---|---|---|
| Add a transaction manually | `OVL-TX-MANUAL` | 6 | ✔ | ✔ | MATCH |
| Review captured transaction | `OVL-TX-CONFIRM` | 3 | ✔ | ✔ | MATCH |
| Change the category | `OVL-TX-CATEGORY` | 2 | ✔ | ✔ | MATCH — all 26 categories in English |
| Add a transaction (entry picker) | `OVL-CAPTURE-ENTRY` | 2 | ✔ | ✔ | MATCH |
| Paste a bank message | `OVL-PASTE` | 2 | ✔ | ✔ | MATCH |
| New goal | `OVL-GOAL-FORM` | — | ✔ | ✔ | MATCH (after 1 fix) |
| Add subscription | `OVL-BILL-FORM` | 11 | ✔ | ✔ | MATCH |
| New plan | `OVL-PLAN-FORM` | 5 | ✔ | ✔ | MATCH |
| Split your income | `OVL-BUDGET-ALLOCATE` | 1 | ✔ | ✔ | MATCH |
| Planning conflicts | `OVL-PLANNING-CONFLICTS` | 1 | ✔ | ✔ | MATCH — empty state only, §6 |
| Setup Apple Shortcut | `OVL-IOS-SHORTCUT` | — | ✔ | ✔ | MATCH |
| Create a financial report | `OVL-REPORT-CONFIG` | 1 | ✔ | ✔ | MATCH |
| Categories manager | `OVL-SETTINGS-CATEGORIES` | 2 | ✔ | ✔ | MATCH (after 1 fix) |
| Country picker | `OVL-SETTINGS-PICKER` | 1 | ✔ | ✔ | MATCH (after 1 fix) |
| Base-currency picker | `OVL-SETTINGS-PICKER` | 1 | ✔ | ✔ | MATCH (after 1 fix) |

The three settings overlays are private functions behind an `onTap`; they are
opened by **tapping the row**, the way a user reaches them. Four of the
thirty-one forced-RTL wrappers lived in exactly those builders, and nothing in
the suite had ever opened them.

---

## 4. Dialogs — 1 unique design inspected

| Surface | Atlas ID | Call sites | AR | EN | Verdict |
|---|---|---|---|---|---|
| Destructive confirmation | `DLG-DESTRUCTIVE-CONFIRM` | **12** | ✔ | ✔ | INTENTIONAL DELTA — §5.2 |

Opened from goal details by tapping Delete, and dismissed without confirming.
One design, twelve nouns — delete budget / transaction / card / goal / plan /
account / bill / payment / category, erase all data, cancel account deletion.
Accepting the frame once accepts the design; the twelve are copy variants.

---

## 5. Acceptable intentional deltas — 4

### 5.1 Stored notification text stays in its delivery language

`/announcements` renders the Arabic title and body of a notification that was
**delivered in Arabic** before English shipped. The chrome around it is
English. Rewriting a delivered notification to match a current preference
would be a lie about what the user was shown.

### 5.2 The destructive-confirm dialog leads with Delete

`Cancel` is a text link; `Delete` is a filled primary button. The copy states
the consequence plainly ("The goal and all its contributions will be
permanently deleted"), and the user has already chosen Delete once to reach
the dialog. Existing intentional design; **not changed** per the charter. Worth
the owner's attention rather than an agent's edit.

### 5.3 The bottom navigation bar does not mirror

`app_shell.dart` forces the nav `Row` to LTR so the curated order — More,
Analytics, **Home**, Budgets, Transactions — keeps Home physically centred in
both languages. Verified identical in the Arabic and English captures. A
deliberate product decision about muscle memory, recorded so it is a decision
rather than an oversight.

### 5.4 The categories manager shows each category's stable key

Rows read «مطاعم» / `restaurants`. The key disambiguates a renamed category.
Consistent in both languages; existing design.

---

## 6. Not inspected, and why — 12

Stated rather than absorbed into a percentage.

| Surface | Why not |
|---|---|
| `/welcome`, `/onboarding/brand`, `/onboarding/auth`, `/onboarding/setup` (4) | Require an **unauthenticated** session. The harness signs in to seed the ledger, so these redirect. Signing out to reach them wipes the local ledger every other runtime test reads. `destructive_phase_test` reaches them by owning its teardown. |
| `StartupLoadingScreen`, `AppBootLoader`, `ForceUpdateScreen`, `AppLockGate`, `_DatabaseRecoveryView` (5) | Conditional roots that need a specific failure, lock or version state. Covered by widget tests — which is **not** visual acceptance and is not counted as such. |
| `ReportPreviewScreen` (1) | Needs a generated report; the generation path is ad-gated. |
| `PlansScreen` (1) | Pushed, not routed, and has no opener that takes only a context. |
| `MerchantOffersScreen` (1) | Needs a merchant id and `enable_coupons`, which ships OFF. |

Also unexercised, and not the same as uninspected:

* **`OVL-BILL-DETAIL`** opens only when the account has an enabled bill. The QA
  ledger seeds two *detected* subscriptions that are not enabled, so there is
  no row. Reported by the walk as "no data to render" rather than as a failure
  — a fabricated bill would render a shape the app never produces.
* **`OVL-ACCOUNT-FORM`** and **`OVL-CARD-FORM`** take a `WidgetRef`, which this
  walk has no honest way to synthesise. Covered by widget tests.
* **`OVL-PLANNING-CONFLICTS`** was inspected in its **empty** state; the QA
  ledger has no conflicts, so the populated state — and the
  `conflictBudgetLabel` fix in it — is not visually confirmed.
* The remaining 12 dialog designs in the Atlas beyond
  `DLG-DESTRUCTIVE-CONFIRM`.

---

## 7. NOT APPLICABLE — 3

| Surface | Reason |
|---|---|
| `DesignGalleryScreen` (`/design`) | Behind `if (kDebugMode)`; not in a release build |
| `BackupScreen` | **KEEP DISABLED — V1 RELEASE REASON**; no navigation entry point |
| `FoundationHomeScreen` | Legacy; zero references anywhere in `lib/` |

---

## 8. The eleven mismatches, all fixed

Every one was invisible to the existing suite, and every one was found by
looking at a rendered screen.

| # | Surface | Defect | Fixed by |
|---|---|---|---|
| 1 | 19 files, 31 sites | `Directionality(textDirection: TextDirection.rtl)` forced RTL regardless of locale — English screens rendered mirrored, with the goal form showing its hint as ".The suggested amount appears once you pick a date" | inherit `Directionality.of(context)`; `no_forced_direction_test` |
| 2 | Dashboard | the daily-spend chart carried `const _initials = ['ن','ث','ر',…]`, so the English axis read Arabic | `Formatters.weekdayInitial`; `weekday_initial_test` |
| 3 | Accounts | "Bank · SAR (SAR)" — the currency printed twice in English | `Currency.labelWithCode` collapses on equality |
| 4 | Currency repair, picker | "SAR — SAR" — the same defect, opposite order | `Currency.codeWithLabel` |
| 5 | Goal details ×2, account detail | `Currency.arabicLabel` called from a widget — "Saved 12,750 of 15,000 ريال" | `Currency.label(context, …)`; `no_direct_arabic_label_test` |
| 6 | Account detail | «أضفتها بنفسك» — the card-source line, untranslated | ARB; UX-015 repointed bilingually |
| 7 | My cards | "Link an existing tran…" truncated where Arabic fits | shortened the English copy |
| 8 | Achievements | «Current level» at **1.45:1** on the header melt | moved onto `AppCard` → **5.14:1** |
| 9 | Accounts | the currency-totals pill at **1.50:1** | opaque surface instead of a 10% tint |
| 10 | Settings | «Your account details» at **1.10:1** | `onMelt` on the first group → **4.61:1** |
| 11 | 4 files | the all-expenses pseudo-category had **four** English names | one source on `BudgetEntity`; `all_expenses_naming_test` |

### Two harness defects the pass also exposed

* **The direction assertion measured the wrong node.** It read
  `Directionality.of()` at the route's first `Scaffold`; all 31 forced-RTL
  wrappers sat below it. True where it looked, false three widgets down. It
  now reads every node — and only flags **RTL under English**, because LTR
  islands (a card number, an email address, a coupon code, the nav row) are
  correct in both languages.
* **A stale locale reads as untranslated copy.** Three separate walks measured
  the first surface after a language switch before the switch reached the
  widgets: the route walk on `/`, the sheet walk on `goal-form` (7 false
  strings), the detail walk on `transaction-details` (**21** false strings).
  All three now wait for the tree to carry the language, and the sheet walk
  reports a stale overlay as a failure to *measure* rather than as a survivor
  — the two need different fixes and must not be reported as the same thing.

### One correction to an earlier claim

The six Arabic single characters this programme reported on `/` as "avatar
initials" were the **weekday labels** in the dashboard chart. They were
explained away as user data without being looked at. Real avatar initials do
exist and appear in the subscriptions and card-details captures; these were
not them.

---

## 9. Verdict

**UI fidelity is closed for every surface that was inspected**, in both
languages, with zero mismatches outstanding and four deltas recorded as
deliberate.

It is **not** closed for the 12 surfaces in §6. Four of those are the
first-run onboarding flow, which is the first thing an App Store reviewer
sees. Reaching it requires signing out, which destroys the seeded ledger the
rest of the runtime evidence depends on — so it is a sequencing problem, not
an impossible one, and it is the one thing worth doing before submission that
this pass did not do.
