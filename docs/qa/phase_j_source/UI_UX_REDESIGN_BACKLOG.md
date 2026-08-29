<!-- PROVENANCE: copied from `demo-docker/UI_UX_REDESIGN_BACKLOG.md`, which is an untracked local
     demo/working directory. THE authoritative Phase J QA backlog — 37 UX findings. `docs/audit/QIRSH_PHASE_J_UIUX_CLOSURE.md` closes against THIS list.
     Tracked here so the authoritative artifact survives loss of that
     directory. The original is left in place; this copy is the one of
     record. -->

# UI/UX REDESIGN BACKLOG — Qirsh

Consolidated from guided QA. **Nothing here is implemented.** One coordinated redesign pass
happens after QA completes — no fragmented UI edits during testing.

Status legend: `OPEN` = recorded, not started.

---

## 1. Global design-system issues

### UX-002 — Hardcoded black/white treatment · **OPEN** · priority: HIGH
User decision (Option B): the hardcoded black/white visual treatment is not wanted. Replace it
with the actual **Mali/Qirsh product visual identity and brand colours**.

- **App-wide rule**, not a single-screen fix.
- First instances: the black promo banner «وزّع دخلك على المظاريف» and the black selected tab
  chip «الميزانيات» on the Budgets screen.
- **Collection rule:** every further sighting is recorded under UX-002 — no duplicate findings.
- **Constraints:** do NOT blindly make everything blue. Preserve visual hierarchy, contrast,
  accessibility, light/dark behaviour, and semantic states (success / warning / danger).

### UX-008 — App logo missing from the Home header · **OPEN** · priority: MEDIUM
User request: «عايز أحط الأيقونة بتاعة التطبيق من فوق كده خالص… زي باقي التطبيقات». Place the Qirsh
brand mark / app icon in the empty area at the top of the Home header — left of the greeting
«مرحباً ليلى الحربي» and right of the «+» button — so the app presents its identity the way other
apps do.

### UX-001 — Inconsistent decimal precision · **OPEN** · priority: LOW
Budget cards round to whole riyals (1,644 for 1,644.30 · 356 for 355.50) while the header on the
same screen shows fils (2,379.80). Underlying values are exact; this is display-only.
Decide one rule and apply it consistently.

---

## 2. Screen-specific redesigns

### UX-013 — Accounts screen shows no balances · **OPEN** · priority: **HIGH**
«الحسابات والمحافظ» lists only name + type + currency. Balances exist and are correct
(18,450.75 / −1,240.50 / 365.00 / 712.25) but are never rendered. Because Home shows *expenses*
rather than a balance, **no screen currently answers "how much money do I have?"** — the first
question any client asks. Add per-account balance, a clear treatment for negative balances
(credit cards), and consider a total across accounts.

### UX-005 — Plans screen does not match the app · **OPEN** · priority: MEDIUM
User: «شكل الصفحة عايزه يطابق design الـapp». The Plans screen should visually belong to the same
design system as the rest of the app. Preserve all data and behaviour.

### UX-007 — Home account selector does not name the selected account · **OPEN** · priority: MEDIUM
The Home chip reads «حساب ريال» whichever account is active — it did not change when switching
الراجحي → مدى. Every headline figure on Home is scoped to that account and swings significantly
between accounts (2,120.00 vs 2,736.05), so the user cannot tell what the numbers refer to.
Show the actual account name (and icon). **Information gap, not styling.**

### UX-004 — Plans: linked accounts not displayed · **OPEN** · priority: MEDIUM
Each plan is bound to accounts in the data (ميزانية رمضان → مدى + الراجحي · مصاريف المدرسة →
الراجحي) but the UI surfaces none of them. **Information gap, not styling** — the user cannot tell
which accounts a plan covers. Note the inconsistency: the Subscriptions screen *does* show the
owning account.

---

## 3. Bottom sheets / dialogs

### UX-003 — Budget bottom sheet: full redesign · **OPEN** · priority: HIGH
Not a colour-only fix. Complete visual/UX redesign required: layout, hierarchy, spacing,
typography, cards/sections, actions, progress presentation, colours, overall interaction feel.
Must belong to the same design system as the rest of the app.
**Preserve all existing functionality, calculations, actions and data behaviour.**

---

## 4. Navigation / interactions

### UX-010 — Home sections vanish silently when empty for the selected account · **OPEN** · priority: MEDIUM
Switching accounts makes entire Home sections disappear with no header and no empty state
(«الأهداف» vanishes on مدى; «الميزانية» vanishes on الراجحي). Reads as breakage rather than
"nothing here for this account". Add an explicit empty state or retain the header with a hint.
**Pairs with UX-007** — naming the active account would make the disappearance self-explanatory.

### UX-012 — Bottom-navigation icons are not legible · **OPEN** · priority: MEDIUM
User: «الأيقونات مش واضحة». Routing is correct, but the glyphs do not communicate their
destinations. Consider clearer metaphors and/or **text labels under each icon** — the client's own
reference app («وفير») labels every tab (الرئيسية / تنبيهات / عروض / حسابي). Ties into CR-002.

### UX-011 — No pull-to-refresh on Home · **OPEN** · priority: MEDIUM
Data refreshes on resume/cold start, but there is no swipe-down gesture to force a sync. Expected
on a financial dashboard, and during a live demo there is no way to trigger a visible refresh on
command. Should invoke the existing sync path, not a bespoke one.

### UX-009 — Floating bottom nav overlaps list content · **OPEN** · priority: MEDIUM
The floating bottom navigation bar sits on top of scrollable content: the مواصلات budget row on
Home was partially hidden behind it (limit digits covered). Add bottom padding / respect the safe
inset so the final rows are fully readable.

---

## 5. Light / dark theme

Covered by **UX-002** — the hardcoded black/white treatment is the primary theme defect found so
far. Any additional theme-specific issues get their own entry here.

---

## 6. Arabic / RTL

_(none recorded yet — Arabic rendering and RTL layout have looked correct through Phases 0–2)_

---

## 7. Accessibility / readability

### UX-014 — Long account names truncate in the detail title · **OPEN** · priority: LOW
«الراجحي — الحساب ال...» is cut off while «مدى — البطاقة الرئيسية» fits. Needs wrapping, smaller
type, marquee, or a short display name.

### UX-015 — Internal jargon shown to users · **OPEN** · priority: LOW
The Cards section prints «يدوية» as a card's source. Internal terminology leaking into the UI —
hide it or use plain customer language.

_(further accessibility work pending — to be assessed explicitly in a later pass: contrast ratios, tap-target
sizes, dynamic type, VoiceOver labels)_

---

## Product decisions pending (not design work)

### UX-006 — Closed plans shown in the main list · **OPEN**
The closed plan (مصاريف المدرسة) appears in the main Plans list next to the active one. Intended,
or should closed plans move to a separate tab / filter / archive? Needs a product call, not a
redesign decision.

---

## 8. Reports

### UX-022 — Refunds are invisible in Reports · **OPEN** · priority: **HIGH**
User request: «اللي مش بيظهر الـrefund — أنا عايزه يظهر في الـreport».

**The maths is correct; the presentation hides it.** `financial_semantics.dart` defines one
documented contract — `net expense = Σ(payment) + Σ(withdrawal) − Σ(refund)` — implemented as

```sql
CASE WHEN type = 'refund' THEN -amount_minor ELSE amount_minor END
```

Reports consumes it through `expenseTotalBetween` / `categoryBreakdown` / `merchantBreakdown` /
`dailyExpenseTotals`. Refunds therefore subtract silently, everywhere, with no line of their own.
`ReportSection` carries only `{total, prevTotal, topCategories, topMerchants, dailySpend, anomaly}`
— there is no refund or gross-expense field to render.

**Concrete case — الراجحي / هذا الشهر:**

| row | type | category | amount |
|---|---|---|---|
| مستشفى الدكتور سليمان | expense | health | 420.00 |
| نون | expense | shopping | 1,899.00 |
| **نون «استرجاع طلب»** | **refund** | shopping | **199.00** |

What the screen shows, and why it reads as wrong:

| surface | displayed | why it confuses |
|---|---|---|
| total | **2,120.00** | 2,319 − 199; nothing explains the 199 |
| category تسوق | **1,700.00** | matches no transaction |
| merchant نون | **1,700.00 · 2 عمليات** | neither row is 1,700; the implied average is meaningless |
| daily, 19 Aug | **−199.00** | a negative spending day with no label |

**Requested behaviour:** make the refund visible without changing the contract.

1. A refunds line in the summary — `إجمالي المصروفات 2,319.00 · المرتجعات −199.00 · الصافي 2,120.00`.
   `financial_semantics.dart:54` already anticipates this ("counts as gross money IN on a labelled
   gross-flow surface"); the surface was never built.
2. Mark netted rows — a badge on تسوق / نون indicating a refund is included, with its value.
3. Label negative days in the daily chart as refunds rather than rendering an unexplained negative bar.
4. Reconsider `COUNT(*)` in `merchantBreakdown`: counting a refund as a transaction alongside a
   netted total produces an incoherent pair.

**Constraint:** do NOT change `net expense = payments + withdrawals − refunds`. The contract is
correct and centrally documented; this is a rendering gap only.

**Note for F-010:** F-010 was recorded as a mobile-side refund double-count. Reports demonstrably
uses the correct netting contract, so F-010's original repro should be re-run against
`financial_semantics.dart` before any fix is designed — the defect may be narrower than recorded,
or may live on a surface that bypasses the contract.

### UX-022 status confirmation (2026-08-26)
**OPEN — redesign backlog. No remediation during guided QA.**

Reports currently net refunds silently into expenses. The user wants refunds surfaced explicitly as
a visible concept / line item **while preserving the existing net-expense mathematics**
(`net expense = payments + withdrawals − refunds`, `financial_semantics.dart`).

Verified this session: the Reports total for الراجحي / هذا الشهر displays **2,120.00** — the
netting is applied correctly and matches Home. The gap is presentational only. Full analysis,
the concrete الراجحي case and the four proposed surfaces are in the UX-022 entry above.

## 9. Subscriptions & bills

### UX-023 — «إجمالي الصرف الشهري» excludes installments · **OPEN** · priority: MEDIUM
With الراجحي selected, the header reads **399.00** while the two counters directly beneath it read
«1 اشتراكات نشطة · 1 أقساط جارية». The real monthly commitment on that account is
**399.00 + 458.25 = 857.25**.

The exclusion is deliberate and documented — `subscriptions_screen.dart:62`:

```dart
// MALI-064n: projected monthly recurring obligation (frequency-
// normalized, active subscriptions only) — the ONE canonical metric.
final monthlyTotal = subscriptionMonthlyTotalMoney(subs, baseCur).toDouble();
```

Treating a finite installment differently from an open-ended subscription is defensible. The defect
is the **label and placement**: «إجمالي الصرف الشهري» claims to be a total, and it sits above
counters for both categories. «سنوياً المجموع 4,788.00» (`monthly * 12`) understates for the same
reason while an installment is running.

Fix by naming the metric («اشتراكات شهرية») and/or adding the installment obligation as its own
line — not by changing the calculation. **Same shape as UX-022:** correct mathematics, a label that
does not describe them.

### UX-024 — Account scoping is invisible on Subscriptions · **OPEN** · priority: MEDIUM
The screen is correctly scoped to the selected account (الراجحي → STC + iPhone; Netflix and نادي
فيتنس تايم on مدى are correctly absent), but nothing on the page says so. The tabs read
«الاشتراكات (1)» / «الأقساط (1)», which reads as *"you have one subscription"* rather than
*"one on this account"*. **Same family as UX-007** (Home does not name the active account).

### UX-002 — further sighting
The selected tab pill («الاشتراكات (1)» / «الأقساط (1)») uses the hardcoded black treatment.
Recorded under UX-002 per the collection rule; no separate entry.

### Positive precedent — the installment card
`iPhone — تقسيط` is the **strongest financial card in the app**: «5 من 12 قسط مدفوع» · «متبقي 7 قسط»
· a progress bar · «القيمة الكلية: 5,499.00» · «القسط القادم: بعد 7 يوم», with «إجمالي مديونية
الأقساط 3,207.75» above it. It answers *"where am I in this commitment?"* completely.

Cite it against **UX-013** (Accounts show no balance at all): the design capability plainly exists —
it was simply never applied to accounts.

## 10. Goals

### UX-025 — Goals have deadlines in the data but never show them · **OPEN** · priority: **HIGH**
Both goals carry a `deadline` that the UI never renders:

| goal | target | saved | remaining | **deadline (in DB)** | required / month |
|---|---|---|---|---|---|
| صندوق الطوارئ | 50,000.00 | 18,500.00 | 31,500.00 | **2027-06-25** | ≈ **3,150** |
| رحلة إسطنبول | 12,000.00 | 4,300.00 | 7,700.00 | **2027-01-25** | ≈ **1,540** |

The cards show only a percentage and «باقي X ريال للوصول». A savings goal without a date is a
number, not a plan — and the required monthly contribution, the one figure that makes a goal
actionable, is derivable from data already present and is never displayed.

The inconsistency is internal: the Subscriptions screen renders «بعد 3 يوم» and the installment card
renders «القسط القادم: بعد 7 يوم». Time-to-target is surfaced for obligations and withheld for goals.

Add the target date, the time remaining, and the required monthly rate. Optionally flag when the
current contribution pace will miss the deadline. **Information gap, not styling.**

### UX-002 — further sighting
The selected tab pill on the Goals screen («الأهداف») uses the hardcoded black treatment. Recorded
under UX-002 per the collection rule.

### Open question — Home shows one goal, the Goals screen shows two
Both goals belong to الراجحي, yet Q03-05 recorded Home displaying only صندوق الطوارئ while this
screen correctly lists both. Most likely Home caps its preview, which is reasonable — but it was
never verified, and a silent cap is the same class as **F-009** (account detail capped at 20 rows
with no indicator). To be confirmed before it is called either way.

### UX-001 — strengthened: rounding makes a budget card self-contradictory
The مطاعم card shows **1,200 / 356** with **«باقي 845»**. Actual spend is 355.50, so remaining is
844.50; both round up independently, and the card then states 356 + 845 = **1,201** against a limit
of **1,200** printed on the same card. بقالة happens to reconcile (1,644 + 856 = 2,500) only
because its fractional part rounds the other way. This is no longer only a precision-consistency
issue — one card contradicts itself in view.

### UX-026 — «السجل» tab shows budgets, not goal history · **OPEN** · priority: MEDIUM
Entering «الأهداف» and tapping «السجل» opens **«سجل الميزانيات»** — budget history. The screen hosts
three tabs (الأهداف · السجل · الميزانيات) where two are about budgets and the label «السجل» does not
say which domain it belongs to. Coming from a goals context, the tab reads as *goal history*.

Related: the **5 goal contributions** (صندوق الطوارئ ×3 = 18,500.00 · رحلة إسطنبول ×2 = 4,300.00)
have not been found on any surface yet. They exist in the data and feed the goal totals; whether the
app exposes them anywhere is still unverified.

---

# GAP FIX (2026-08-26) — three findings were spoken but never written

Audit of this file against the session found **UX-027, UX-028 and UX-029 had no written record**.
They were raised in conversation and lost. Recorded now.

### UX-027 — Delete is the only affordance on a Plans card · **OPEN** · priority: MEDIUM
On the Plans screen each card carries a single visible control: the 🗑 delete icon. There is no edit,
no close, no archive. **The most prominent action available is the most destructive one**, and it sits
on a card that also shows a closed plan (UX-006) a user may well want to tidy away — the only tool
offered for that is permanent deletion.

Same family as **F-017** (Admin confirms deleting a draft but not publishing a force-update): the
destructive action is the easiest one to reach.

### UX-028 — «الحساب» section header appears twice in Settings · **OPEN** · priority: LOW
Settings uses the heading «الحساب» twice: once near the top (رقم الموبايل · الدولة · العملة
الأساسية) and once at the bottom for the destructive group (ابدأ من جديد · تسجيل الخروج · حذف
الحساب وكل بياناتي). Two unrelated groups under an identical name.

### UX-029 — Settings has become the app's navigation hub · **OPEN** · priority: MEDIUM
«إدارة أموالك» holds **ten** entries — الحسابات والمحافظ · كل البطاقات · الاشتراكات والفواتير ·
الخطط · الرؤى والتقارير · الإنجازات والمستوى · التصنيفات · تعارضات المزامنة · تأكيد عملة الميزانيات
والأهداف · اختصار آبل.

Primary destinations (Reports, Accounts, Subscriptions, Plans) are reachable *through Settings*,
which is where users go for configuration, not for their money. This reads as compensation for
**UX-012** — the bottom-navigation icons are not legible, so a second, text-labelled route was built
alongside them. Ties into **CR-002**.

Fixing UX-012 should reduce this list, not duplicate it.

---

# MASTER INDEX — all UX findings, grouped and deduplicated

31 IDs assigned · 31 recorded · UX-002 is one root issue with many sightings, not many bugs.

## A. Global design system / theme
| ID | title | priority |
|---|---|---|
| **UX-002** | **Hardcoded black/white treatment — ROOT ISSUE** | **HIGH** |
| UX-001 | Inconsistent decimal precision (one budget card contradicts itself) | LOW |

**UX-002 observed occurrences** (one fix, not eight): Budgets promo banner «وزّع دخلك على المظاريف» ·
Budgets selected-tab chip · Subscriptions tab pills · Goals tab pill · Budgets-history tab pill ·
Settings theme selector («فاتح» — the theme picker itself is hardcoded) · Message-centre «فتح» button ·
Transactions filter chips («الكل», «العمليات») · Goal detail «أضف للهدف» · Subscriptions
«إضافة اشتراك».

## B. Home
| ID | title | priority |
|---|---|---|
| UX-007 | Account selector shows «حساب ريال», never the account name | MEDIUM |
| UX-008 | App logo missing from the Home header (asset exists — used on the privacy screen) | MEDIUM |
| UX-010 | Sections vanish silently when empty for the selected account | MEDIUM |
| UX-011 | No pull-to-refresh | MEDIUM |
| UX-009 | Floating bottom nav overlaps the last list rows | MEDIUM |

## C. Accounts
| ID | title | priority |
|---|---|---|
| **UX-013** | **No screen shows an account balance** | **HIGH** |
| UX-014 | Long account names truncate in the detail title | LOW |
| UX-015 | Internal jargon «يدوية» shown as a card's source | LOW |

## D. Transactions
| ID | title | priority |
|---|---|---|
| UX-016 | Quality/limit counters absent from the list view | MEDIUM |
| UX-017 | (Admin parsers) `message_pattern` not shown in the list | MEDIUM |

## E. Planning — budgets, goals, plans, subscriptions
| ID | title | priority |
|---|---|---|
| **UX-003** | **Budget bottom sheet — FULL REDESIGN, not a recolour** | **HIGH** |
| UX-004 | Plans do not display their linked accounts | MEDIUM |
| UX-005 | Plans screen does not match the app's design system | MEDIUM |
| UX-006 | Closed plans sit in the main list with no «منتهية» badge | product call |
| UX-023 | «إجمالي الصرف الشهري» excludes installments while the counters beneath include them | MEDIUM |
| UX-024 | Account scoping is invisible on Subscriptions | MEDIUM |
| UX-025 | Goals *list* cards omit the deadline and daily rate the detail sheet shows | LOW *(narrowed)* |
| UX-026 | «السجل» tab under «الأهداف» opens budget history | MEDIUM |
| **UX-027** | **Delete is the only affordance on a Plans card** | MEDIUM |

## F. Reports
| ID | title | priority |
|---|---|---|
| **UX-022** | **Refunds are netted invisibly — surface them as a line item** | **HIGH** |

## G. Settings
| ID | title | priority |
|---|---|---|
| UX-030 | The strongest true privacy claim (local SQLCipher encryption) is never made | MEDIUM |
| **UX-029** | **Settings has become the navigation hub** | MEDIUM |
| UX-028 | «الحساب» section header duplicated | LOW |

## H. Notifications / messages
| ID | title | priority |
|---|---|---|
| UX-031 | Message centre calls itself a history and shows no dates | MEDIUM |

## I. Admin dashboard
| ID | title | priority |
|---|---|---|
| UX-018 | `all_expenses` sentinel listed as a real category (the app filters it; Admin does not) | MEDIUM |
| UX-019 | Categories banner attributes the key dependency to the wrong system | LOW |
| UX-020 | «0 من 0» counter reads as breakage on empty pages | LOW |
| UX-021 | Raw English engineering notes shown to a business operator | LOW |

## J. Accessibility / RTL / Arabic
| ID | title | priority |
|---|---|---|
| UX-012 | Bottom-navigation icons are not legible — add text labels | MEDIUM |

Arabic rendering and RTL layout have been correct throughout; no defects found. Contrast ratios,
tap-target sizes, dynamic type and VoiceOver labels remain **unassessed** — a deliberate gap, not a
clean bill of health.

## Correction to the running count
Progress messages during the session quoted "36–39 UX findings". That was **inflated**: the true
figure is **31 assigned, 31 now recorded**. Three (UX-027/028/029) existed only in conversation until
this entry. The scorecard should use **31**.

## UX-032 — Announcement banner crowds/overlaps the pending-review card on Home · LOW
Observed 2026-08-27 during the Phase-3 propagation test (screenshot IMG_3834, 05:04). With an
active announcement, the Home banner («تجربة عرض — إعلان توضيحي») sits flush against — visually
bleeding into — the smart-inbox card below it («1 عملية في انتظار مراجعتك»). The two read as one
merged blob rather than two widgets. Operator's rule, adopted verbatim: **no widget may intrude
into another widget** — the announcement banner needs its own vertical rhythm (margin/padding)
consistent with the card list, at every announcement length (1-line and multi-line).
Count with this entry: **32**.

## UX-033 — Onboarding requires a complete redesign · HIGH

User requests a total onboarding redesign, not a colour-only pass. Rework information hierarchy,
progress, Arabic/RTL copy, permissions and consent timing, cloud/AI explanations, phone entry and
completion states as one coherent flow. Preserve existing auth/security behaviour; do not bundle
consent into an unreadable acceptance screen. Ties into CR-006 and CR-007.

## UX-034 — Cards page and card/transaction management are difficult · HIGH

The all-cards page is visually weak and the user finds linking, unlinking or removing a card from
a transaction difficult to understand. Redesign the page and transaction-card interaction with a
clear current card, parent account, reassignment, «بدون بطاقة» action and consequences. Preserve
transaction/account identity and never hide whether changing a card also changes its account.

## UX-035 — Large numeric values become visually unreadable («0 0 0») · HIGH · NEEDS REPRO

User reports that very large values on the cards UI collapse into a zero-like/unreadable visual
result. Capture the exact value, locale, screen, font scaling and screenshot in targeted QA before
implementation. The redesign must handle exact large values without truncating significant
digits or silently rounding to zero.

## UX-036 — Plan currency label is hardcoded to جنيه · HIGH

When selecting a plan backed by an account in another currency, the UI still displays «جنيه».
Currency presentation must come from the selected plan/account scope and use the correct ISO/locale
format. Mixed-currency plans need an explicit product rule rather than a guessed label.

## UX-037 — Budget and Shortcut notifications lack trustworthy context · HIGH

Notifications must identify the exact category/account/card and the threshold or action that
triggered them. A shopping-budget warning must not read as though an unrelated food transaction
belongs to shopping; Shortcut/capture notifications should show the resolved category when one is
actually known and should not fabricate it when confidence is insufficient.

Count with these entries: **37**.
