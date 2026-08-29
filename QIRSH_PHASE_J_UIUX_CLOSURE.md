# PHASE J — QA UI/UX CLOSURE MATRIX

**Baseline HEAD at start:** `3f304240` (Flutter 2742/0 · analyze clean · admin 101/0 ·
tsc 0 · SQL 228/0 · Deno 152/0 · pristine dirty=0).
**The correctness/security/privacy baseline must not regress.**

---

## 0. AUTHORITATIVE SOURCE RECOVERY

The complete QA UI/UX list was recovered from **`demo-docker/UI_UX_REDESIGN_BACKLOG.md`**
(454 lines, 37 unique IDs). Cross-checked against every other Markdown artifact in the
repository — `DEMO_GUIDED_QA.md` (21 IDs), `UI_REDESIGN_IMPLEMENTATION_PLAN.md` (25),
`DEMO_FINDINGS.md` (7), `MASTER_REMEDIATION_PLAN.md` (15), `QIRSH_MASTER_PLAN_V2.md` (13).

**The backlog is a strict superset: no UX ID exists anywhere that it does not contain.**

> **Correction to the brief's framing.** The plan quotes "30+" and the backlog's own master
> index says "31 assigned, 31 recorded" — but that index predates UX-032…UX-037, which were
> appended later. The backlog's final line states **37**, and 37 distinct IDs are present.
> **37 is the authoritative count**, not 31 and not "30+".

**Scope decision — CR items are excluded.** `CR-001…CR-009` are product FEATURE requests
("REQUESTED / NOT IMPLEMENTED", "PRODUCT SEMANTICS REQUIRED"), not QA defects. Two are
referenced by UX findings (CR-006/CR-007 by UX-033; CR-002 by UX-012/UX-029) and are
addressed only to the extent those findings require. Listed in §4 for completeness.

**R-8** (Money-typed display formatter) is a V2 root-cause remedy, not a QA finding. It is
in scope because the brief names it and because UX-001 and UX-035 both depend on it.

**Preservation note:** `demo-docker/` is UNTRACKED. The authoritative QA list therefore
exists only in the working tree. The full list is reproduced in this committed document so
Phase J's source of truth is version-controlled.

---

## 1. VERIFICATION METHOD

Each finding was checked against **current HEAD source**, not against memory and not against
"related code changed". Method per row is recorded in the matrix. Statuses used here:

| status | meaning |
|---|---|
| **OPEN** | verified still present at HEAD |
| **CLOSED-PENDING-VERIFY** | HEAD contains an implementation; behavioural/visual confirmation still required |
| **CLOSED** | fixed and verified in Phase J |
| **N/A** | not applicable, with evidence |
| **EXTERNAL** | genuinely impossible locally |

---

## 2. CLOSURE MATRIX — verified against HEAD `3f304240`

### A. Global design system

| ID | Finding | Surface | HEAD status | Evidence |
|---|---|---|---|---|
| **UX-002** | Hardcoded black/white treatment (ROOT, ~10 sightings) | app-wide | **OPEN** · HIGH | 39 files under `lib/features/` match `Colors.black`/`Colors.white`/`0xFF000000`/`0xFFFFFFFF` |
| **UX-001** | Inconsistent decimal precision; one budget card contradicts itself (356+845=1201 vs limit 1200) | Budgets | **OPEN** · LOW→raised | `budgets_screen.dart` has 5 × `toStringAsFixed(0)`/`round()` |
| **R-8** | Money rendered through `double`; no Money-typed formatter | app-wide | **OPEN** | 96 `.toDouble()` call sites across 28 files in `lib/features/` |
| **R-8a** | **NEW —** two independent currency-scale tables that have already drifted | domain | **OPEN** | `money_format.dart` omits `KMF`; canonical `currency_scale.dart` says 0 decimals, display defaults to 2 |

### B. Home

| ID | Finding | HEAD status | Evidence |
|---|---|---|---|
| UX-007 | Account selector never names the selected account | **OPEN** · MEDIUM | `dashboard_screen.dart`: 0 hits for `account.name`/`accountName` |
| UX-008 | App logo missing from Home header | **OPEN** · MEDIUM | `app_header.dart`: 0 hits for logo/asset |
| UX-009 | Floating bottom nav overlaps last rows | **CLOSED-PENDING-VERIFY** | `app_shell.dart`: 2 safe-area/inset hits |
| UX-010 | Sections vanish silently when empty | **CLOSED-PENDING-VERIFY** | `dashboard_screen.dart`: 4 empty-state hits |
| UX-011 | No pull-to-refresh | **CLOSED-PENDING-VERIFY** | `RefreshIndicator` present in `dashboard_screen.dart` |
| UX-032 | Announcement banner crowds the pending-review card | **OPEN** · LOW | `dashboard_screen.dart`: 0 announcement hits — needs locating |

### C. Accounts & cards

| ID | Finding | HEAD status | Evidence |
|---|---|---|---|
| **UX-013** | **No screen shows an account balance** | **OPEN** · HIGH | `accounts_screen.dart`: 0 hits for balance/Money/formatMoney |
| UX-014 | Long account names truncate in detail title | **CLOSED-PENDING-VERIFY** | `account_detail_screen.dart`: 3 maxLines/ellipsis hits |
| UX-015 | Internal jargon «يدوية» shown as card source | **OPEN** · LOW | `my_cards_screen.dart`: 4 hits |
| **UX-034** | Cards page weak; card↔transaction management unclear | **OPEN** · HIGH | 0 hits for «بدون بطاقة»/unlink |
| **UX-035** | Large values render unreadable | **OPEN** · HIGH · NEEDS REPRO | 5 `FittedBox`/`maxLines` hits exist; original repro never captured |

### D. Transactions

| ID | Finding | HEAD status | Evidence |
|---|---|---|---|
| UX-016 | Quality/limit counters absent from list view | **CLOSED-PENDING-VERIFY** | `transactions_screen.dart`: 6 quality/limit hits |

### E. Planning

| ID | Finding | HEAD status | Evidence |
|---|---|---|---|
| **UX-003** | Budget bottom sheet — full redesign | **OPEN** · HIGH | no `budget_detail_sheet.dart`; sheet lives elsewhere — locate |
| UX-004 | Plans don't display linked accounts | **OPEN** · MEDIUM | to verify |
| UX-005 | Plans screen off design-system | **CLOSED-PENDING-VERIFY** | `plans_screen.dart`: 5 AppCard/AppScreenScaffold hits |
| UX-006 | Closed plans in main list, no «منتهية» badge | **OPEN** · product call | 0 hits for منتهية/closed/archived |
| UX-023 | «إجمالي الصرف الشهري» excludes installments | **OPEN** · MEDIUM | 0 hits for the corrected label |
| UX-024 | Account scoping invisible on Subscriptions | **OPEN** · MEDIUM | 0 hits for account name on screen |
| UX-025 | Goal cards omit deadline + required rate | **OPEN** · HIGH-in-source | `goals_screen.dart`: 0 deadline hits |
| UX-026 | «السجل» under Goals opens budget history | **OPEN** · MEDIUM | 0 «سجل» hits — tab structure changed; re-verify |
| **UX-027** | Delete is the only affordance on a Plans card | **OPEN** · MEDIUM | 1 edit/archive hit only |
| **UX-036** | Plan currency hardcoded to «جنيه» | **CLOSED-PENDING-VERIFY** | `plan_form_sheet.dart`: 0 hardcoded جنيه |

### F. Reports

| ID | Finding | HEAD status | Evidence |
|---|---|---|---|
| **UX-022** | Refunds netted invisibly — surface as a line item | **OPEN** · HIGH | `reports_screen.dart`: 0 refund hits |

### G. Settings

| ID | Finding | HEAD status | Evidence |
|---|---|---|---|
| UX-028 | «الحساب» header duplicated | **OPEN** · LOW | 2 occurrences confirmed |
| UX-029 | Settings has become the navigation hub (10 entries) | **OPEN** · MEDIUM | «إدارة أموالك» present |
| UX-030 | Strongest true privacy claim (SQLCipher) never made | **OPEN** · MEDIUM | 0 encryption-claim hits |

### H. Notifications

| ID | Finding | HEAD status | Evidence |
|---|---|---|---|
| UX-031 | Message centre calls itself history, shows no dates | **OPEN** · MEDIUM | 1 date hit — partial |
| **UX-037** | Budget/Shortcut notifications lack trustworthy context | **OPEN** · HIGH | `notification_planner.dart`: 0 category hits |

### I. Onboarding

| ID | Finding | HEAD status | Evidence |
|---|---|---|---|
| **UX-033** | Onboarding requires complete redesign | **OPEN** · HIGH | no single onboarding screen; flow spans `story_screen`/`brand_screen`/others |

### J. Admin dashboard (separate surface)

| ID | Finding | HEAD status |
|---|---|---|
| UX-017 | `message_pattern` not shown in parsers list | to verify |
| UX-018 | `all_expenses` sentinel listed as a real category | to verify |
| UX-019 | Categories banner attributes dependency to wrong system | to verify |
| UX-020 | «0 من 0» counter reads as breakage | to verify |
| UX-021 | Raw English engineering notes shown to operators | to verify |

### K. Accessibility / RTL

| ID | Finding | HEAD status | Evidence |
|---|---|---|---|
| UX-012 | Bottom-nav icons illegible — add text labels | **CLOSED-PENDING-VERIFY** | `app_shell.dart` has `label:` on every destination |

> The backlog states Arabic/RTL rendering was correct throughout and that **contrast, tap
> targets, dynamic type and VoiceOver remain UNASSESSED — "a deliberate gap, not a clean bill
> of health"**. Phase J §10 requires assessing them; that work is additive, not a closure.

---

## 3. RUNNING COUNTS (start of Phase J)

| | count |
|---|---|
| Original findings recovered | **37** (UX-001…UX-037) |
| Plus root-cause remedy in scope | R-8 (+ R-8a, newly discovered) |
| Verified OPEN at HEAD | 22 |
| CLOSED-PENDING-VERIFY | 9 |
| To verify (admin surface + UX-004) | 6 |
| New findings discovered so far | 1 (R-8a currency-scale drift) |

---

## 4. CR ITEMS — related, out of scope

`CR-001` Home section order · `CR-002` reference app (visual only) · `CR-003` clarification
required · `CR-004` report history/limits · `CR-005` date of birth · `CR-006` onboarding
consent semantics · `CR-007` phone entry redesign · `CR-008` production AI capability ·
`CR-009` Shortcut capture quality.

Product requests, not QA defects. CR-006/CR-007 are owner-decision items feeding UX-033.
