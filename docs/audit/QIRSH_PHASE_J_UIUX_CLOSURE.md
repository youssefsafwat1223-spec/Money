# PHASE J — FINAL QA UI/UX CLOSURE

**Baseline HEAD at start:** `3f304240` — the correctness/security/privacy remediation
baseline. It must not regress, and does not: no financial contract, consent gate, sync
predicate or crypto path was altered by Phase J.

---

## 0. AUTHORITATIVE SOURCE RECOVERY

The complete QA UI/UX list was recovered from **`demo-docker/UI_UX_REDESIGN_BACKLOG.md`**
(454 lines, 37 unique IDs), cross-checked against every other Markdown artifact in the
repository — `DEMO_GUIDED_QA.md` (21 IDs), `UI_REDESIGN_IMPLEMENTATION_PLAN.md` (25),
`docs/audit/DEMO_FINDINGS.md` (7), `docs/plans/MASTER_REMEDIATION_PLAN.md` (15), `docs/plans/QIRSH_MASTER_PLAN_V2.md` (13).

**The backlog is a strict superset: no UX ID exists anywhere that it does not contain.**

> **Correction to the brief's framing.** The plan quotes "30+" and the backlog's own master
> index says "31 assigned, 31 recorded" — but that index predates UX-032…UX-037, which were
> appended later. The backlog's final line states **37**, and 37 distinct IDs are present.
> **37 is the authoritative count**, not 31 and not "30+".

**Two index entries are wrong about their own findings.** Working from the index rather than
the finding text would have closed the wrong thing twice:

| ID | index one-liner | what the finding actually says |
|---|---|---|
| UX-016 | "Quality/limit counters absent from the list view" | *"**No filter for «قيد المراجعة»**… the app asks the user to review pending items but provides no way to isolate them."* |
| UX-025 | "Goals *list* cards omit the deadline and daily rate **the detail sheet shows**" | the detail sheet does **not** show them — `deadline` reaches the exported PDF and orders the Home preview, and appears nowhere in the app's own goal UI |

**Scope decision — CR items are excluded.** `CR-001…CR-009` are product FEATURE requests
("REQUESTED / NOT IMPLEMENTED", "PRODUCT SEMANTICS REQUIRED"), not QA defects. Two are
referenced by UX findings (CR-006/CR-007 by UX-033; CR-002 by UX-012/UX-029) and are
addressed only to the extent those findings require. Listed in §7.

**R-8** (Money-typed display formatter) is a V2 root-cause remedy rather than a QA finding.
It is in scope because the brief names it and because UX-001 and UX-035 both depend on it.

**Preservation note:** `demo-docker/` is UNTRACKED, so the authoritative QA list exists only
in the working tree. Every finding is reproduced in this committed document, and every
closure is additionally pinned by a committed test, so Phase J's source of truth survives
the loss of that directory.

---

## 1. HEADLINE NUMBERS

| | count |
|---|---|
| Original findings recovered | **37** (UX-001…UX-037) |
| Root-cause remedies in scope | **2** (R-8, R-8a) |
| **CLOSED** | **39** |
| **NOT APPLICABLE** | 0 |
| **EXTERNAL** (blocked on something outside the repo) | **2 residuals** — see §5 |
| New findings discovered during Phase J | **10** |
| New findings fixed | **10** |
| Remaining actionable source/local work | **none** |

The two EXTERNAL items are *residuals of otherwise-closed findings*, not open findings:
the IBM Plex OFL licence file, and the device repro behind UX-035's visual half. Neither
blocks any source change; both are release-time artifacts.

---

## 2. VERIFICATION METHOD

Each finding was checked against **HEAD source**, not against memory and not against
"related code changed". The brief's rule — *"Do NOT mark a finding CLOSED merely because
related code changed"* — caught two false closures, both recorded above and both fixed.

Closures are pinned by tests in three styles, chosen by what the finding actually is:

- **Behavioural** where a value can be computed — `goal_pacing_test.dart` reproduces the
  QA's own two goals (3,150 and 1,540 per month); `ux_information_and_safety_test.dart`
  reproduces the 356 + 845 = 1,201 contradiction as the arithmetic the screen used to do.
- **Structural** where the finding is a property of a surface's source — "the balance is
  absent from this screen" is not a pixel question, and a golden test would fail on
  unrelated styling while still passing if the balance were removed.
- **Cross-checking**, where user-facing copy makes a claim about the code. UX-030's
  encryption claim is asserted against `PRAGMA cipher = 'sqlcipher'` and the fail-closed
  branch; UX-034's «الحساب زي ما هو» is asserted against `updateCard` writing `card_last4`
  and nothing else. If the code stops being true, the copy fails the build.

---

## 3. CLOSURE MATRIX

### A. Global design system

| ID | Finding | Status | Remediation & evidence |
|---|---|---|---|
| **UX-002** | Hardcoded black/white treatment (ROOT, ~10 sightings) | **CLOSED** | The QA's rule was *"one fix, not eight"*. All ten sightings resolved to a single token: `AppColors.light.ink` `#0F1115` → `AppBrandBlue.brand`. Dark `ink` deliberately left as the inverted light surface. `ux002_brand_treatment_test.dart` (8) computes WCAG contrast — AA **and** AAA both pass, so the brand colour is not a contrast concession — and asserts the semantic colours were not absorbed into the brand. |
| **UX-001** | Inconsistent decimal precision; one card contradicts itself | **CLOSED** | `_BudgetAmountTile` takes a `Money`, not a pre-formatted `String`. The header already showed fils; the cards now do too. Same rounding was applied to goals, where a goal one riyal short read as complete. |
| **R-8** | Money rendered through `double`; no Money-typed formatter | **CLOSED** | `money_format.dart` + `MoneyText`: integer maths, ASCII digits, `tabularFigures`, FSI/PDI bidi isolation. Applied to budgets, goals, plans, accounts, reports, the Home hero, the weekly chart and capture notifications. |
| **R-8a** | **NEW —** two currency-scale tables that had already drifted | **CLOSED** | `money_format.dart` had its own exponent map, missing `KMF`, defaulting to 2 where the canonical `currency_scale.dart` says 0. Display now derives from the canonical registry — one table, not two. |

### B. Home

| ID | Finding | Status | Remediation & evidence |
|---|---|---|---|
| UX-007 | Account selector never names the selected account | **CLOSED** | Chip reads `'${selected.name} · ${currency}'`. A correct implementation already existed in `account_range_controls.dart` and was never mounted; the test is anchored to the widget the dashboard actually builds. |
| UX-008 | App logo missing from the Home header | **CLOSED** | Gold coin mark in the gap between the greeting and «+» — the area the owner pointed at. Gold not `getCoin`: that picks by theme brightness and this surface is dark in both themes. `excludeFromSemantics` — branding must not precede content for a screen reader. |
| UX-009 | Floating bottom nav overlaps last rows | **CLOSED** (verified) | The sheet reserves 112px; the nav adds the real safe-area inset. Verified by reading both, not by grep count. |
| UX-010 | Sections vanish silently when empty | **CLOSED** — *was falsely pending* | The prior "4 empty-state hits" were the whole-screen empty state. Budgets, Goals and Subscriptions still vanished header-and-all per account. Each now keeps its header with one quiet line naming the account. An account with no data at all still gets the single full-screen empty state. |
| UX-011 | No pull-to-refresh | **CLOSED** (verified) | `RefreshIndicator` invoking the existing `dashboardDataProvider`, not a bespoke path. |
| UX-032 | Announcement banner crowds the pending-review card | **CLOSED** | Bottom margin moved **inside** `AnnouncementBanner`. It collapses to `SizedBox.shrink()` when empty, so a spacer at the call site would leave a permanent gap on the far more common no-announcement screen. Both layouts (single and horizontal-scroll) covered — the operator's rule was "at every announcement length". |

### C. Accounts & cards

| ID | Finding | Status | Remediation & evidence |
|---|---|---|---|
| **UX-013** | No screen shows an account balance | **CLOSED** | Per-account balance via `MoneyText`; negatives coloured as information, not error. `_CurrencyTotals` groups **by currency** — there is no FX layer, so a single cross-currency total would be a number that means nothing. |
| UX-014 | Long account names truncate in the detail title | **CLOSED** | Opt-in `AppHeader.titleMaxLines`, and `preferredSize` grows with it — allowing a wrap without room for it just clips lower down. One line stays right for a fixed screen name; two for a title that is user data. |
| UX-015 | Internal jargon «يدوية» shown as card source | **CLOSED** | «اتعرفت من رسائل البنك» / «أضفتها بنفسك». Kept rather than hidden: it tells the user whether future transactions attach by themselves. |
| **UX-034** | Cards page weak; card↔transaction management unclear | **CLOSED** (structural) | Account and card are now separate labelled rows, «بدون بطاقة» exists, and the binding constraint is satisfied *and asserted*: `updateCard` writes `card_last4` only, so changing a card cannot move the transaction — and the copy says so. Only cards on the transaction's own account are offered. A dismissed sheet uses a sentinel, so "backed out" is never read as "detach". |
| **UX-035** | Large values render unreadable | **CLOSED** (exactness) · residual EXTERNAL | Exactness half fixed and tested past 2^53. Legibility half: `hero_amount_size.dart` gives `FittedBox(scaleDown)` a floor. Device repro was never captured; the limitation is stated in the file rather than papered over. |

### D. Transactions

| ID | Finding | Status | Remediation & evidence |
|---|---|---|---|
| UX-016 | *(index says "quality/limit counters")* — no «قيد المراجعة» filter | **CLOSED** — *index was wrong* | The filter existed and was reachable only from the Home banner and a notification tap. A toggle chip, not a fifth kind chip: «مصروفات» + «قيد المراجعة» is a meaningful combination, and the provider ANDs `pendingOnly` with the kind filter. |
| **NEW-J1** | «تجاهل الكل» bulk-dismissed the whole duplicate queue, unconfirmed | **CLOSED** | Count on the button, confirmation stating what is and is not affected. It discards duplicate *flags*, not transactions — which is why it is acceptable at all, and why the dialog says so. |

### E. Planning

| ID | Finding | Status | Remediation & evidence |
|---|---|---|---|
| **UX-003** | Budget bottom sheet — full redesign | **CLOSED** (structural) | Already on `AppSheetScaffold`/`AppCard`/tokens; now exact money throughout, an action (it was entirely read-only), and the 20-row cap **disclosed** — the F-009 class the backlog names, where a 60-transaction period looked like a 20-transaction one. |
| UX-004 | Plans don't display linked accounts | **CLOSED** | Account names and cards on the card, and the widest scope named rather than left blank: MALI-048n makes an empty selection mean «كل المصروفات في الفترة». An unresolvable id is not printed raw; the label says «حسابات محددة», which stays honest because that id still widens the plan. |
| UX-005 | Plans screen off design-system | **CLOSED** (verified) | `AppCard`/`AppScreenScaffold` at HEAD, plus `MoneyText` and the overflow menu added here. |
| UX-006 | Closed plans in main list, no «منتهية» badge | **CLOSED** | Badge added. Whether they belong in a separate tab is the product call the QA left open; labelling them is not. |
| UX-023 | «إجمالي الصرف الشهري» excludes installments | **CLOSED** | Label fixed, calculation untouched — MALI-064n's exclusion is deliberate. The installment obligation is its own line, with the ACTIVE filter explicit at the call site because `monthlyEquivalentsTotalMoney` is deliberately filter-free (the footgun that produced F-027). |
| UX-024 | Account scoping invisible on Subscriptions | **CLOSED** | Header names the account, resolved through `billsScopeAccountProvider` — the same provider the filter uses, so label and data cannot drift. |
| **UX-025** | Goal cards omit deadline + required rate | **CLOSED** — *was mis-narrowed to LOW* | `goal_pacing.dart` derives the required monthly contribution in exact minor units, rounding **up** (understating would let a goal read on-track while missing its date) and counting a partial month as whole. Returns null rather than a fiction when there is no deadline, the goal is met, or the date has passed. |
| UX-026 | «السجل» tab opens budget history | **CLOSED** | Tab renamed «سجل الميزانيات» — the page already titled itself that once you were inside; the tab that got you there was the only thing that didn't say so. |
| **UX-027** | Delete is the only affordance on a Plans card | **CLOSED** | Overflow menu with تعديل leading, حذف one level in and still confirmed. Making an action less prominent must not make it less guarded. |
| **UX-036** | Plan currency hardcoded to «جنيه» | **CLOSED** | Hardcode was already gone; the **residual** was not: the form suffix read the base currency while `_save` wrote `existing.currency`, so editing an EGP plan on a SAR base labelled the field «ريال» while storing EGP. Both now read one source, and the mixed-currency rule is stated in the form. |

### F. Reports

| ID | Finding | Status | Remediation & evidence |
|---|---|---|---|
| **UX-022** | Refunds netted invisibly | **CLOSED** (all four sub-items) | (1) `إجمالي المصروفات · المرتجعات · الصافي`, derived from the two queried figures so the three on screen cannot disagree. (2) Netted rows carry their refund, so «نون · 1,700.00 · 2 عمليات» reconciles. (3) A negative day is labelled «مرتجع» instead of rendering an unexplained bar. (4) `COUNT(*)` **kept** — it was never wrong; a refund IS one of the rows the total is built from, and what was missing was the refund. The netting contract is untouched and asserted to be untouched. |

### G. Settings

| ID | Finding | Status | Remediation & evidence |
|---|---|---|---|
| UX-028 | «الحساب» header duplicated | **CLOSED** | «بيانات حسابك» / «الخروج وحذف البيانات» — both named for what they contain. |
| UX-029 | Settings has become the navigation hub (10 entries) | **CLOSED** | The finding's own instruction was *"Fixing UX-012 should reduce this list, not duplicate it."* UX-012 is fixed, so «الرؤى والتقارير» — a duplicate route to the now-labelled «التحليلات» tab — is removed. The rest have no tab of their own and legitimately live here; they are split into destinations vs configuration so ten flat rows stop reading as a second nav bar. |
| UX-030 | Strongest true privacy claim never made | **CLOSED** | Claim made and **verified against the code**: `PRAGMA cipher = 'sqlcipher'`, key in the platform keychain, and the open fails closed rather than continuing unencrypted. Deliberately stops short of end-to-end, which the product does not do. |

### H. Notifications

| ID | Finding | Status | Remediation & evidence |
|---|---|---|---|
| UX-031 | Message centre calls itself a history, shows no dates | **CLOSED** | Every row dated, and honestly: `sentAt` is a delivery, `validFrom` is when an item began being shown. One undifferentiated timestamp would have dated a server-side publication window as though it were a delivery. |
| **UX-037** | Budget/Shortcut notifications lack trustworthy context | **CLOSED** | The account was already resolved by the only caller and never reached the text, so a shopping warning arriving after an unrelated food purchase read as though the food had been filed under shopping. Alerts now name the budget's account and the crossed threshold. `accountLabel` is **required-and-nullable**, so a future caller must state that it does not know rather than silently dropping it. Capture notifications already withheld an unresolved category and still do. |

### I. Onboarding

| ID | Finding | Status | Remediation & evidence |
|---|---|---|---|
| **UX-033** | Onboarding requires a complete redesign | **CLOSED** (structural) · product decisions are CR items | The redesigned flow is present and routed: `/welcome` → `/onboarding/brand` → `/onboarding/auth` → `/onboarding/setup`, one activation step at a time, with step dots, «خطوة N من 3» and back navigation; copy is l10n-driven, so Arabic/RTL is not hardcoded. Consent is **not** bundled into an acceptance screen — cloud/AI are revocable toggles in Settings under MALI-001, which is what the finding required. What remains is CR-006 (consent semantics) and CR-007 (phone entry), which the backlog itself marks owner-decision. Inventing those is exactly the arbitrary redesign the brief forbids. |

### J. Admin dashboard

| ID | Finding | Status | Remediation & evidence |
|---|---|---|---|
| UX-017 | `message_pattern` not shown in the parsers list | **CLOSED** | It is the rule that extracts amount, merchant and date; `sender_pattern` only decides which messages are considered. The list showed the second and hid the first, so two rules for one bank were indistinguishable. Now its own column, searchable, full value on hover. |
| UX-018 | `all_expenses` sentinel listed as a real category | **CLOSED** | Labelled «ليست فئة إنفاق» rather than hidden — the row is real, it is what an all-expenses budget stores, and an operator who meets it in the data should meet it here. |
| UX-019 | Categories banner blames the wrong system | **CLOSED** | It credited `sms_parsers`, which has no category column — the stated reason not to edit a key was not the real one. The real dependents store the key as plain TEXT with no FK, so renaming does not fail, it orphans silently. That is both accurate and a sharper reason. |
| UX-020 | «0 من 0» reads as breakage | **CLOSED** | `resultCountLabel` returns nothing at zero, and the rule lives in `FilterBar` rather than in six call-site strings — six chances to forget it, and every future table a seventh. |
| UX-021 | Raw English engineering notes shown to operators | **CLOSED** | Operator-language descriptions per key, falling back to the stored text so a later flag cannot lose its description. Additionally, the seven flags MALI-034 retired now say that flipping them changes nothing — F-018 found active flags read by no code, and the panel gave no way to discover that. |

### K. Accessibility / RTL

| ID | Finding | Status | Remediation & evidence |
|---|---|---|---|
| UX-012 | Bottom-nav icons illegible — add text labels | **CLOSED** (verified) | Every destination carries a `label:` (المزيد · التحليلات · الرئيسية · الميزانيات · العمليات). This is load-bearing for UX-029: it is what makes the Settings duplicate removable. |
| **NEW-J3** | Icon-only buttons with no accessible label | **CLOSED** | Four sites (close, back, clear-search) given tooltips; the announcement dismiss buttons already had them. |

---

## 4. NEW FINDINGS DISCOVERED DURING PHASE J

All ten fixed. Five are corrections to the backlog itself.

| # | Finding | Class | Status |
|---|---|---|---|
| R-8a | Two currency-scale tables, already drifted (`KMF` missing) | correctness | CLOSED |
| J-A | UX-010 was marked CLOSED-PENDING-VERIFY on a grep; the sections still vanished | false closure | CLOSED |
| J-B | UX-016's index one-liner describes a different finding than its text | backlog error | CLOSED |
| J-C | UX-025 narrowed to LOW on the false premise that the detail sheet shows the deadline | backlog error | CLOSED |
| J-D | UX-036 residual: form suffix read base currency while save wrote the plan's | correctness | CLOSED |
| NEW-J1 | «تجاهل الكل» — unconfirmed bulk destructive action, no count, no undo | UX safety | CLOSED |
| NEW-J2 | Raw bidi code points in source (FSI/PDI) — compiler and reader saw different text | code health | CLOSED |
| NEW-J3 | Icon-only buttons with no accessible label | accessibility | CLOSED |
| NEW-J4 | Capture notifications ROUNDED 3-decimal currencies (KWD 12.345 → 12.35) | correctness | CLOSED |
| NEW-J5 | Reports `_money()` and the weekly chart still on the `double` path | correctness | CLOSED |

---

## 4b. CROSS-CUTTING AUDITS (§2, §8–§13)

These are audit passes rather than findings. Each was run; what it found is recorded, and
where it found nothing that is stated as a result rather than skipped.

| § | Pass | Result |
|---|---|---|
| §2 | Global size/density via tokens | **Already done, not redone.** `AppSpacing` carries the full semantic scale, and the compact system (`docs/MALI_COMPACT_UI_SYSTEM_PLAN.md`) already took ~25–35% of vertical whitespace out of chrome while keeping tap targets ≥44/48. No QA finding asks for a further change, so no blanket resize was performed — that would be the arbitrary redesign the brief forbids. `MoneyText` was designed against this constraint: the fraction renders at ~70% size, so full precision costs about two small characters and density is taken out of chrome rather than out of the user's money. |
| §8 | RTL/Arabic + LTR/English | Amounts are LTR runs inside RTL text — without isolation the bidi algorithm can paint a leading minus on the wrong end, turning `-355.50` into something that reads positive. `MoneyText` emits FSI…PDI and forces `TextDirection.ltr`; digits are ASCII always, because locale formatting renders `ar_EG` in Arabic-Indic and `ar_SA` in ASCII, which would show two number systems to the two core markets. Card numbers already carry explicit `textDirection: ltr`. Onboarding copy is l10n-driven. `money_text_test.dart` asserts identical rendering in LTR and RTL. |
| §9 | Responsiveness / overflow | The three new multi-figure rows (budget tiles, plan progress, merchant rows) use `Flexible` + ellipsis rather than fixed widths; `_BudgetAmountTile` gives the amount its own line precisely because three exact figures with fils no longer fit beside a currency word. The Home hero gained a legibility floor (UX-035). Reports' category legend already switches to two columns above 430px. |
| §10 | Accessibility | Contrast computed, not eyeballed: `ux002_brand_treatment_test.dart` asserts AA **and** AAA for `onInk`-over-`ink` in both themes. Four icon-only buttons lacking any accessible label were found and fixed (NEW-J3). Tap targets are ≥44/48 by token. The brand mark added on Home is `excludeFromSemantics` — branding must not be announced before content. |
| §11 | Component consistency | The pass produced UX-020's real fix: six tables each built their own `«{visible} من {total}»` string, so the empty-state rule had to be remembered six times. Moving it into `FilterBar` makes it a property of the component. Similarly `_BudgetAmountTile` now takes `Money`, so the rounding defect cannot be reintroduced by a caller. |
| §12 | Light/dark themes | UX-002 was fixed at the token, and the dark theme's `ink` was deliberately left as the inverted light surface — painting dark navy on a dark page would lose the contrast the light theme just gained. A sweep for hardcoded black/white found only deliberate uses: Apple's mandated Sign-in-with-Apple styling, `onSuccess`/`onWarning` contrast pairs, the documented true-black dark canvas, `Color.lerp` shade computations, and the full-bleed onboarding story surface. No UX-002-class attention surface remains. |
| §13 | Destructive-action UX | Every user-facing delete was traced to its confirmation: cards, bills, plans, budgets, transactions, account reset and account deletion are all guarded, and sign-out takes a pre-wipe inventory, attempts a bounded flush, re-checks (a timeout is not treated as success) and only then offers explicit discard (MALI-053n). The pass found one genuinely unguarded action — NEW-J1, «تجاهل الكل» — and one mis-prioritised affordance, UX-027. Both fixed. |

---

## 5. EXTERNAL / MANUAL RESIDUALS

Neither is an open finding; both are residuals of closed ones, and neither blocks any
source change.

1. **IBM Plex Sans Arabic OFL licence file.** The typography direction is settled and
   implemented — IBM Plex Sans Arabic was already primary; the stale comment claiming
   otherwise is what made it look unsettled. The official licence text is not in the repo
   and must not be fabricated or fetched blind. Release-packaging item.
2. **UX-035 device repro.** The exactness half is fixed and tested; the legibility half has
   a deterministic floor. The original sighting's exact value, locale, font scale and
   screenshot were never captured, so the fix cannot be verified against it. If the repro is
   later captured and shows a different cause, this is the wrong fix rather than an
   incomplete one — stated in `hero_amount_size.dart` rather than left implicit.

---

## 5b. FINAL GATE — clean HEAD, strict mode

**Final HEAD: `8a97a9ba759efb6d1f31f132ed7759b38789aa5c`**

```
REQUIRE_ALL_GATES=1 tools/ci_gates.sh
CI_GATES_JSON {"passed":12,"failed":0,"tool_missing":0,"caller_skipped":0,
               "artifact_pending":1,"strict":1,"node_skipped":"70",
               "deno_ignored":"2","manifest":"satisfied","lint_exceptions":7}
ALL RUN GATES PASSED
```

**First attempt green. No rerun, no normalisation.**

| gate | result |
|---|---|
| migration lint | ✓ |
| deno edge-function tests (all functions) | ✓ |
| deno lint | ✓ |
| flutter analyze | ✓ (0 issues) |
| flutter test — bulk | ✓ **2840 passed, 0 failed** (1 skipped) |
| flutter test — crypto (serialized, `--concurrency=1`) | ✓ **24 passed** |
| node contract tests | ✓ |
| skip/ignore manifest | ✓ satisfied |
| admin authorization tests | ✓ (113 — 102 pre-existing + 11 new UX-017…021) |
| l10n freshness | ✓ |
| MALI-034 architecture guard (6 checks) | ✓ |
| MALI-037 dependency policy | ✓ |

**The clean-HEAD claim, stated precisely.** The gate ran with
`REQUIRE_PRISTINE_TREE=1`, which asserts that **no tracked file differs from
HEAD** — so "the gate passed" and "HEAD passes" are the same statement, verified
by the gate rather than assumed. That was checked independently first:
`git diff --name-only HEAD` → 0, `git diff --cached --name-only` → 0. The six
untracked directories present (`demo-docker/`, `research/`, and four Markdown
files) are not tracked and cannot affect a tracked-file comparison; the separate
`head_completeness_test` additionally asserts that no committed test reads an
untracked file and no committed Deno file imports an uncommitted one, so an
untracked directory cannot be silently load-bearing either.

**A detached pristine worktree was attempted first and abandoned deliberately.**
`npm ci` into `~/.claude/jobs/` did not complete in a reasonable time (and a
byte-copy of the resolved tree was slower still), so the gate was run in the
main checkout **after proving its tracked tree is byte-identical to HEAD**.
That is the same guarantee — `REQUIRE_PRISTINE_TREE=1` is precisely the check the
worktree was there to make true by construction — reached by verification
instead. Recorded rather than glossed, because "green from a pristine checkout"
and "green from a tree proven identical to HEAD" are worth distinguishing.

**The one artifact-pending gate is not a pass.** iOS packaging inventory needs a
built `Runner.app`; it is classified `artifact_pending`, never `PASS`, and is
deferred to a mandatory post-build step. The static Info.plist / privacy-manifest
source contract does run, in the flutter test stage.

---

## 6. PRODUCTION SAFETY

Nothing was pushed, deployed, or sent to production or evidence staging. No remote
migration was applied, no capability activated, no production flag changed. All work is
source, local tests and local static analysis.

---

## 7. CR ITEMS — related, out of scope

`CR-001` Home section order · `CR-002` reference app (visual only) · `CR-003` clarification
required · `CR-004` report history/limits · `CR-005` date of birth · `CR-006` onboarding
consent semantics · `CR-007` phone entry redesign · `CR-008` production AI capability ·
`CR-009` Shortcut capture quality.

Product requests, not QA defects. CR-006/CR-007 are the owner-decision items feeding UX-033.
