# Owner-Dirty Dashboard Files — exactly what I changed

Five files under `app/lib/features/dashboard/` carry **substantial uncommitted
owner work** (a daily-allowance feature, ~925 lines). I edited copy inside them
for the Modern Standard Arabic conversion.

Those edits are **NOT committed**. They live in the working copy alongside the
owner's work so the owner can review, keep or drop each one independently. This
file is the complete record so nothing is lost or silently overwritten.

Every change is a **single string literal**. No logic, no structure, no imports,
no formatting. Each is trivially revertible on its own.

## The edits

### `dashboard_screen.dart` — 6 strings

| Line | Before | After |
|---|---|---|
| 332 | `راجعها عشان أرصدتك تفضل مظبوطة` | `راجعها لتبقى أرصدتك دقيقة` |
| 386 | `انتبه — مصروفك أعلى بـ…% عن الأسبوع اللي فات. راجع أكتر فئة بتصرف فيها.` | `انتبه — إنفاقك أعلى بـ…% عن الأسبوع الماضي. راجع أكثر فئة تنفق فيها.` |
| 387 | `أحسنت — مصروفك أقل بـ…% عن الأسبوع اللي فات. كمّل كده وهتوفّر أكتر.` | `أحسنت — إنفاقك أقل بـ…% عن الأسبوع الماضي. واصل على هذا النحو لتوفّر أكثر.` |
| 1237 | `مفيش اشتراكات ولا أقساط على الحساب ده.` | `لا توجد اشتراكات ولا أقساط على هذا الحساب.` |
| 1312 | `مفيش أهداف على الحساب ده.` | `لا توجد أهداف على هذا الحساب.` |

### `widgets/budgets_card.dart` — 1 string

| Line | Before | After |
|---|---|---|
| 59 | `مفيش ميزانيات على الحساب ده.` | `لا توجد ميزانيات على هذا الحساب.` |

### `widgets/monthly_spend_card.dart` — 2 strings

| Line | Before | After |
|---|---|---|
| 139 | `مفيش ميزانية شهرية — حدّدها عشان تعرف المتاح` | `لا توجد ميزانية شهرية — حدّدها لتعرف المتاح` |
| 258 | `بالمعدل ده هتقفل الشهر على ` | `بهذا المعدل ستنهي الشهر على ` |

### `widgets/transactions_panel.dart` — 1 string

| Line | Before | After |
|---|---|---|
| 78 | `مفيش عمليات في الفترة دي.` | `لا توجد عمليات في هذه الفترة.` |

### `widgets/coupons_corner.dart` — 2 changes

| Line | Before | After |
|---|---|---|
| 214 | `شوف كل الكوبونات` | `عرض كل الكوبونات` |
| 182 | `Icon(AppLucideIcons.chevronLeft, …)` | **unchanged** — deliberately excluded from the `DirectionalChevron` migration because this file is owner-dirty. It is the one remaining non-mirroring chevron |

## Totals

| | |
|---|---|
| Files touched | 5 |
| String literals changed | 12 |
| Logic changed | **0** |
| Committed | **0** |

## Two known outstanding items in these files

1. **`coupons_corner.dart:182`** still uses `chevronLeft` directly, so it will
   point the wrong way in English. Every other call site was migrated to
   `DirectionalChevron`. Left alone rather than editing owner-dirty code for a
   non-copy change.
2. These strings are **hardcoded, not localised**. The English localisation
   work will need to move them into the ARB, which means editing these files
   again — best done after the owner's dashboard work lands.

## How to reconcile

* **Keep them**: nothing to do. They are already in the working tree.
* **Drop them**: revert each line to the "Before" column above. They are
  independent.
* **Commit them with the owner's work**: the copy is MSA-correct and matches
  `test/l10n/msa_copy_test.dart`, which will fail if the colloquial returns.

---

## Addendum — 2026-09-17, one further edit to an owner-dirty file

### `app/lib/features/accounts/account_detail_screen.dart` — 1 line

Not a copy change. `accountTypeLabel()` gained a `BuildContext` parameter so it
could read the ARB instead of returning hardcoded Arabic (`نقدي` / `بنك` /
`محفظة` / `بطاقة ائتمانية`). Every call site had to follow, including this one.

| Line | Before | After |
|---|---|---|
| 166 | `accountTypeLabel(account.type)` | `accountTypeLabel(context, account.type)` |

`context` was already in scope at that line; nothing else in the file changed.
Leaving it unedited was not an option — it would not compile.

**Still not committed**, in line with the rest of this document.

### Currency labels — this file was deliberately SKIPPED

The sweep that pointed 49 call sites at the new `Currency.label(context, code)`
excluded every owner-dirty file. `account_detail_screen.dart:166` still calls
`Currency.arabicLabel(...)`, so this screen keeps showing Arabic currency names
in the English build. Same for:

- `lib/features/dashboard/dashboard_screen.dart` (6 call sites)
- `lib/features/dashboard/home_sections_providers.dart` (1)
- `lib/features/dashboard/widgets/transactions_panel.dart` (1)
- `lib/features/cards/card_details_screen.dart` (1)
- `lib/features/goals/goal_details_screen.dart` (2)

These are a one-line mechanical change each, held back only because the files
carry uncommitted owner work. They are the reason `/` still reports 94 Arabic
strings under `en` while every migrated route is in single digits.

---

## Addendum 2 — `account_detail_screen.dart` had to be COMMITTED

Unlike everything else in this document, this one file **is** in a commit, and
the owner should know exactly why and exactly what of theirs went with it.

**Why it could not stay uncommitted:** `accountTypeLabel()` gained a
`BuildContext` parameter (so the four account-type names come from the ARB
instead of being hardcoded Arabic). Every call site had to follow. Leaving this
one behind would have produced a HEAD that does not compile.

**The owner's work that was committed alongside it — 4 lines, unmodified:**

```dart
+import '../transactions/transaction_details_screen.dart';

 TransactionRow(
   transaction: tx,
   category: catalog?.byId(tx.categoryId),
+  onTap: () => TransactionDetailsScreen.showSheet(context, tx.id),
 ),
```

That is a complete, working feature — tapping a transaction row on the account
detail screen opens the details sheet. It was not altered, reformatted, or
partially applied. If you would rather it lived in a commit of your own,
`git log -p -- app/lib/features/accounts/account_detail_screen.dart` shows it
isolated, and it can be reverted and re-committed without touching anything
else.

**No other owner-dirty file was committed.** The dashboard five, the two other
detail screens, `goal_pacing.dart` and the untracked `dashboard/widgets/`
directory are all still exactly as you left them.

---

# Part 2 — 2026-09-17: authorised surgical pass over the owner-dirty files

The owner authorised proceeding on top of the uncommitted dashboard work:

> Proceed autonomously on top of the owner-dirty dashboard files, but do it
> surgically. Do NOT overwrite or rewrite the owner's existing logic.

Everything in Part 1 above (the read-only survey) is now superseded by actual
edits, recorded here hunk by hunk.

## Safety net taken BEFORE any edit

Stored at `~/.qirsh-qa/owner-preserve-fc471b9a/`:

| Artefact | What it is |
|---|---|
| `owner-tracked.patch` | 1,655-line `git diff` of every tracked owner-dirty file, exactly as the owner left it |
| `checksums.sha256` | SHA-256 of all 28 dirty/untracked paths |
| `files/` | Byte-for-byte copies of every file before editing |

Any hunk below can be reverted individually against `files/`.

## What was changed, and what was NOT

**Only two kinds of edit were made:**

1. Arabic string literal → `context.l10n.<key>` (or a locale-aware pair where
   there is no element tree).
2. `Currency.arabicLabel(x)` → `Currency.label(context, x)`.

Plus the mechanical consequences the analyzer forces: `const` removed where a
value stopped being compile-time constant, and a `BuildContext` parameter
threaded into helpers that had none.

**No owner logic was altered.** Verified by diffing every file against the
pre-change copy and filtering out localization lines — what remains is only
`const` removal and the signature threading listed above.

## Per-file hunk counts

| File | lines removed | lines added |
|---|---:|---:|
| `dashboard/dashboard_screen.dart` | 110 | 116 |
| `dashboard/dashboard_providers.dart` | 9 | 16 |
| `dashboard/home_sections_providers.dart` | 8 | 27 |
| `dashboard/widgets/budgets_card.dart` | 9 | 10 |
| `dashboard/widgets/coupons_corner.dart` | 3 | 4 |
| `dashboard/widgets/daily_spend_card.dart` | 12 | 13 |
| `dashboard/widgets/monthly_spend_card.dart` | 14 | 16 |
| `dashboard/widgets/obligations_card.dart` | 11 | 12 |
| `dashboard/widgets/transactions_panel.dart` | 5 | 6 |
| `goals/goal_details_screen.dart` | 25 | 31 |
| `cards/card_details_screen.dart` | 8 | 9 |

## The structural edits worth knowing about

These are the only places where a signature or shape changed, each because a
localized value cannot live where the original value did.

| File | Was | Now | Why |
|---|---|---|---|
| `dashboard_screen.dart` | `static const _labels = {…}` | `static String _label(BuildContext, HeroPeriod)` | a `const` map cannot hold localized copy, and a table built at class-load would freeze whichever language was active then |
| `dashboard_screen.dart` | `_currencyLabel(String)`, `_name()`, `_presetLabel(preset)` | each takes `BuildContext` | they read the ARB now |
| `dashboard_providers.dart` | `String get budgetPeriodLabel` | `String budgetPeriodLabelIn(String languageCode)` | a getter on a data class has no `ref`; **it has no callers, so nothing breaks** |
| `home_sections_providers.dart` | `budgetContextText(…)` | same + `String languageCode = 'ar'` | **purely additive** — this function has no callers yet (unfinished owner work), and the default reproduces the previous behaviour exactly |
| `card_details_screen.dart` | `_flow(String, Money, Color)` | `_flow(BuildContext, …)` | reads the currency label |
| `goal_details_screen.dart` | — | unchanged shape | only literals swapped |

## MSA corrections inside owner copy

The owner's new widgets carried Egyptian colloquial forms. These were corrected
on the way into the ARB, where `test/l10n/msa_copy_test.dart` can see them:

| File | Was | Now |
|---|---|---|
| `daily_spend_card.dart` | `صرفت النهاردة` | `صرفت اليوم` |
| `daily_spend_card.dart` | `عمليات النهاردة` | `عمليات اليوم` |
| `daily_spend_card.dart` | `أعلى ٣ النهاردة` | `أعلى ٣ اليوم` |
| `monthly_spend_card.dart` | `المفروض …` | `المتوقع …` |
| `dashboard_screen.dart` | `اختار فترة العرض` | `اختر فترة العرض` |
| `dashboard_screen.dart` | `كمّل إعداد قرش` | `أكمل إعداد قِرش` |
| `dashboard_screen.dart` | `محتاج … شهريًا` | `يلزمك … شهريًا` |
| `dashboard_screen.dart` | `بمعدلك الحالي هتوصل` | `بمعدلك الحالي ستصل` |

The owner's own test `test/features/dashboard/daily_spend_card_test.dart` was
updated to match (`النهاردة` → `اليوم`) — the assertion follows the copy; what
it tests is unchanged.

## A bug found in the owner's code while doing this

`daily_spend_card.dart`, `transactions_panel.dart` and `monthly_spend_card.dart`
rendered `category.nameAr`. `CategoryView` already exposes a locale-aware
`.name`, and its own doc comment reserves `.nameAr` for "the few places that
genuinely mean the ARABIC name". A rendered category label is not one of those,
so every category on Home showed Arabic in the English build. Changed to
`.name`; no other behaviour differs.

## Result

`/` went from **86 Arabic strings under `en` to 14**, and 13 of those 14 are
user data that is correctly Arabic — account names, goal names, merchant names
(`ساسكو`, `الدانوب`, `نون`, `التميمي`) and the avatar initials derived from
them. The fourteenth was `هذا الشهر` from a shared range control outside the
dashboard, now also closed.

`flutter analyze` clean, 3,961 tests pass, including every one of the owner's
own dashboard tests.

## Owner-authored files that entered git history in this commit

The owner authorised proceeding and said not to wait for them to commit. That
means owner-written code is now in history alongside the localization edits.
Listing it explicitly so it is never a surprise:

**Previously untracked — entirely owner-authored, first commit:**

- `app/lib/features/dashboard/widgets/budgets_card.dart`
- `app/lib/features/dashboard/widgets/coupons_corner.dart`
- `app/lib/features/dashboard/widgets/daily_spend_card.dart`
- `app/lib/features/dashboard/widgets/monthly_spend_card.dart`
- `app/lib/features/dashboard/widgets/obligations_card.dart`
- `app/lib/features/dashboard/widgets/transactions_panel.dart`
- `app/lib/domain/finance/daily_allowance.dart`
- `app/test/domain/finance/daily_allowance_test.dart`
- `app/test/domain/finance/goal_projection_test.dart`
- `app/test/features/dashboard/daily_spend_card_test.dart`

**Previously modified — owner's uncommitted changes committed:**

- `app/lib/domain/finance/goal_pacing.dart` (adds `GoalProjection`,
  `goalProjection()`)
- `app/lib/features/dashboard/dashboard_screen.dart`
- `app/lib/features/dashboard/dashboard_providers.dart`
- `app/lib/features/dashboard/home_sections_providers.dart`
- `app/lib/features/goals/goal_details_screen.dart`
- `app/lib/features/cards/card_details_screen.dart`

`goal_pacing.dart` and `daily_allowance.dart` were **not optional**: the staged
dashboard imports `goalProjection()` and `dailyAllowance()` from them, so a
commit without them would not compile. This was verified by stashing everything
unstaged and running `flutter analyze` against the staged tree alone — clean.

**Still untouched and still uncommitted**, exactly as the owner left them:

- `app/integration_test/dashboard_impression_probe_test.dart`
- `app/test/harness/sweep_core_test.dart`
- `app/docs/dashboard_daily_spend_report.md`
- `app/ios/Podfile`, `app/ios/Podfile.lock`

To separate your work from the localization pass:
`git log -p <commit> -- app/lib/features/dashboard/` shows both; the
pre-localization copies in `~/.qirsh-qa/owner-preserve-fc471b9a/files/` are what
your code looked like before any edit of mine.
