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
