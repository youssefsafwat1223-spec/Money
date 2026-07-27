# UX Audit — Accounts & Cards

**Scope:** Accounts & Cards experience in Mali/Qirsh.
**Constraint:** No code, schema, or business-logic changes. Inspection + product recommendations only.
**Reviewer stance:** Senior Product Designer + Senior Flutter Engineer, benchmarking against Revolut, Monzo, Apple Wallet, Wallet by BudgetBakers, Money Manager.

---

## PHASE 1 — How the current app actually works

### 1.1 Accounts architecture

- **Entity:** `AccountEntity` (`lib/domain/entities/account_entity.dart`): `id, name, currency, type, initialBalance?, currentBalance?, isDefault, sortOrder, createdAt, updatedAt`.
- **Type enum:** `AccountType { cash, bank, wallet, card }`.
- **Repository:** `AccountRepository` → `getAll / getById / getDefault / create / update / delete / setDefault`. There is a Drift implementation and a Supabase-primary implementation (multi-currency sync path).
- **Screen:** `AccountsScreen` (route `/accounts`), a standalone pushed screen (not a bottom-tab). Custom gradient header "الحسابات والمحافظ", a plain `ListView` of `_AccountCard`s, and an "إضافة حساب" outlined button at the bottom.
- **Add/Edit:** a single modal bottom sheet `_AccountForm` used for both create and edit. Fields: name (`TextField`), type (`ChoiceChip` row of all 4 types), currency (`DropdownButtonFormField`), "الحساب الافتراضي" (`SwitchListTile`). Edit mode adds a "حذف الحساب" text button (hidden for the default account). Last account cannot be deleted.
- **Balance:** `initialBalance` / `currentBalance` exist on the entity **but are never exposed or edited in any UI** and are written as `null` at every creation site (`dashboard_providers.dart:221`, `capture_sync_service.dart:395`). They exist only in the sync payload. Effectively dead fields from a user's point of view.

### 1.2 Cards architecture

- **There is no Card entity and no cards table.** A "card" is a **derived aggregate**: `getCardSummaries()` runs `SELECT card_last4, SUM(in), SUM(out), COUNT(*) ... FROM transactions WHERE card_last4 IS NOT NULL AND status='confirmed' GROUP BY card_last4` (`drift_transaction_repository.dart:672`).
- **`CardSummary`** (`domain/entities/card_summary.dart`) is a read-model: `last4, network, totalOut, totalIn, count`. The network is detected on the fly from a sample raw message.
- **Screen:** `MyCardsScreen` (opened imperatively via `MyCardsScreen.open(context)` → `MaterialPageRoute`, **not** through a GoRouter path). Renders each card as a gradient "physical card" tile showing `•••• last4`, network badge, داخل / خارج / الصافي, and two actions: "إضافة عملية" and "اربط عملية موجودة".
- **Card details:** `CardDetailsScreen` exists in **two forms** — a full `Scaffold` (wired to route `/card/:last4`) **and** a glass bottom sheet (`showSheet`). `MyCardsScreen` uses the sheet. The route version appears to have **no live entry point**.
- **`cards_carousel.dart` is dead code** — no references outside its own file.

### 1.3 Relationship between Accounts and Cards

This is the crux. On a transaction, `account_id` and `card_last4` are **two independent, unrelated axes**:

- `account_id` → FK-ish link to an `AccountEntity`. Set from the default account on manual add / capture.
- `card_last4` → free string parsed from the bank SMS (`parser_engine.dart` extracts via ~8 regexes), or passed when adding a transaction "to a card".
- **Nothing links a card to an account.** There is no `card.account_id`, no join, no grouping of cards under accounts. A transaction can have an account and a card, only an account, or (for SMS) a card and whatever the default account happens to be.
- Confusingly, `AccountType.card` is a **third, separate notion** of "card": a manually-created account whose type is "card." It has zero connection to the derived SMS cards in `MyCardsScreen`.

So the app currently exposes **two different mental models of "card" that never meet**: (a) an account you tag as type=card, and (b) an auto-detected last-4 bucket.

### 1.4 SMS linking flow

1. Bank SMS captured → `ParserEngine` extracts amount, type, merchant, and `last4` (best-effort regex).
2. Transaction saved with `cardLast4 = last4` and `accountId = default account` (card and account set independently).
3. `getCardSummaries()` later re-derives the card list by grouping confirmed transactions on `card_last4`.
4. Result: cards "appear automatically" (as the empty state promises) with no user action — but they are **not** attached to any account, and the same physical card seen under two different SMS formats (e.g. `**1234` vs `card 1234`) will always collapse to the same `last4` bucket, while a card the bank never prints last-4 for simply never appears.

### 1.5 Navigation

Entry points to **Accounts** (`/accounts`):
- Dashboard filter chip row — the account/currency switcher (`dashboard_screen.dart:1791`).
- Settings → "الحسابات والمحافظ".

Entry points to **Cards** (`MyCardsScreen`):
- Settings → "بطاقاتي".
- **A per-row "بطاقاتي" button on every account card** in `AccountsScreen` (`accounts_screen.dart:210`) — but it opens the **global, unscoped** cards list regardless of which account's button was tapped.

So Cards has two doors, one of which is misleadingly attached to an individual account but ignores that account.

### 1.6 Bottom sheets

- Account add/edit: `showModalBottomSheet`, `isScrollControlled`, drag handle, navy theme, keyboard-inset padding.
- Card details: `showModalBottomSheet` at **86% screen height** with a blurred glass backdrop.
- Attach-existing: `DraggableScrollableSheet` (0.7 → 0.95) listing **all** transactions to pick one to tag with the card.

### 1.7 Data model summary

| Concept | Storage | Identity | Editable by user? |
|---|---|---|---|
| Account | `accounts` table, `AccountEntity` | real `id` | name/type/currency/default — **not** balance |
| Card | none — derived `GROUP BY card_last4` | `last4` string | no card object to edit; only per-transaction tagging |
| Account↔Card | none | — | — |

### 1.8 Providers / repositories

- `accountsProvider`, `accountRepositoryProvider`, `dashboardAccountProvider` (selected account for dashboard scoping), `activeCurrenciesProvider`.
- `cardSummariesProvider` (watches `dbRevisionProvider` + session), `cardTransactionsProvider.family(last4)`, `allTransactionsForPickProvider`.
- `transactionRepositoryProvider.updateCard(...)` performs the attach/link write.

---

## PHASE 2 — UX review (user's perspective)

**Does the user understand the difference between Accounts and Cards?**
No. There are *three* things called or shaped like a "card": an account of type=card, the auto-derived last-4 card, and the credit-card-styled visual used for both. A normal user cannot articulate why "بطاقاتي" and "الحسابات" are different lists, or why a card isn't inside its account.

**Is the separation intuitive?**
No. In every benchmark app, a card *belongs to* an account/product. Here they're siblings living in different screens with no link, which contradicts the real-world model users carry in their heads.

**Does navigation create confusion?**
Yes. The per-account "بطاقاتي" button implies "this account's cards" but shows all cards. Two entry points, one route (`/card/:last4`) with no user-reachable path, and a `MaterialPageRoute` for `MyCardsScreen` that bypasses the app's router convention.

**Is anything duplicated?**
Yes: `CardDetailsScreen` exists as both a route `Scaffold` and a sheet; `cards_carousel.dart` is dead; `AccountType.card` duplicates the concept of "card" that the derived list already owns; the credit-card gradient visual is reused for both concepts, reinforcing the confusion.

**Is the editing flow too long?**
Account editing is reasonable (one sheet) but shows all four type chips and a currency dropdown up front even though most users have one currency and rarely change type. Card "editing" doesn't exist — you cannot rename a card, set an owner account, hide it, or merge duplicates.

**Is the bottom sheet too large?**
Card details at 86% height with a glass blur is heavy for what is essentially "a header + a transaction list." It's a screen wearing a sheet's clothes.

**Unnecessary screens / taps / scrolling?**
- Reaching a card takes: open Settings → بطاقاتي → tap card → sheet. Or dashboard → /accounts → per-row card button → list → card. Both are indirect.
- "اربط عملية موجودة" lists **every** transaction with no search/filter — heavy scrolling to find one.
- Account balance is invisible, so users can't answer "how much is in this account?" — arguably the #1 question an accounts screen should answer.

**Advanced settings shown too early / fields that should be hidden?**
- "الحساب الافتراضي" switch is prominent, but its consequence ("يُربط به الالتقاط التلقائي") is jargon to most users.
- All four account types are always visible; `wallet` vs `bank` vs `card` is a distinction most users won't reason about at creation time.

---

## PHASE 3 — Benchmark (why the leaders decided what they did)

- **Revolut / Monzo:** The account (the money) is primary; cards are **instruments attached to that account**, shown inside the account detail as a manageable object (freeze, rename, virtual/physical). Rationale: users think "my account, and the cards that spend from it." A card is never a peer of the account.
- **Apple Wallet:** Each card **is** the account surface — one object, front and center, tap to see its transactions. Rationale: for a card-centric product, collapsing "account" and "card" into one visual removes a layer. Notably Apple does **not** show a separate "accounts" list *and* a "cards" list.
- **Wallet by BudgetBakers / Money Manager:** Manual-first. "Accounts" are the top-level containers (cash, bank, card are just *types* of account) and there is **no separate cards list at all** — a card is simply an account with type=card. Rationale: for manual trackers, fewer containers = less cognitive load; the balance per account is the hero number.

**The pattern across all five:** there is exactly **one** primary container concept. Either card = account (Apple), or card ⊂ account (Revolut/Monzo), or card *is a type of* account (BudgetBakers/Money Manager). **None of them ship two parallel top-level lists** ("Accounts" and "Cards") that don't reference each other. Mali currently does — that's the single biggest divergence.

---

## PHASE 4 — Architecture review: should Cards stay a separate entity?

**Recommendation: keep the data model, change the exposure. Do NOT create a cards table. Do NOT delete `card_last4`.**

The derived-card model is actually good engineering for an SMS-first app: cards materialize for free from parsed transactions, with zero user setup. The problem is purely **presentation**: it's surfaced as a *peer* of accounts instead of *inside* accounts (or merged with them).

Three options, with trade-offs:

**Option A — Cards as a section inside Account detail (recommended).**
Keep everything as-is in the DB. Change navigation so cards appear as children of the account they belong to. Requires a way to associate a `last4` with an account. Cheapest correct association: when a captured/manual transaction has both `account_id` and `card_last4`, treat that as "this card is seen on this account," and group derived cards under the account(s) they co-occur with. No schema change — it's a `GROUP BY account_id, card_last4` instead of `GROUP BY card_last4`.
- *Pro:* Matches Revolut/Monzo mental model; no schema/logic change; kills the parallel-list confusion.
- *Con:* A card only knows its account once at least one transaction ties them; orphan cards (SMS with last-4 but ambiguous account) need an "unassigned" bucket.

**Option B — Merge the two "card" notions: drop the separate cards list, fold derived cards into the accounts list as read-only entries.**
Show derived cards as auto-detected accounts of type=card (visually distinct, "auto" badge), so there's one list.
- *Pro:* One container concept, closest to BudgetBakers/Money Manager; removes an entire screen.
- *Con:* Mixing user-created accounts with auto-derived buckets in one list can feel noisy if a user has many last-4 variants; needs good de-dupe/merge affordance.

**Option C — Keep separate, but fix the seams (minimum effort).**
Leave two lists; just remove the misleading per-account button, give Cards a real route, delete dead code, and cross-link (account detail → "cards seen on this account").
- *Pro:* Smallest change.
- *Con:* Still two top-level lists; doesn't resolve the core mental-model problem.

**Verdict:** Option A is the best product outcome with no database change. Option C is the safe incremental first step and is a strict subset of A.

---

## PHASE 5 — Recommendations by priority

### CRITICAL

**C1. Eliminate the two-parallel-lists mental model.**
- *Current:* "الحسابات" and "بطاقاتي" are separate top-level lists that never reference each other; a third "card" notion (`AccountType.card`) exists too.
- *Problem:* Users can't form a coherent model of where their money and cards live.
- *Why it's a UX problem:* Violates the single-container principle every benchmark follows; causes "which list do I look in?" hesitation on every visit.
- *Solution:* Adopt Option A — cards render **inside** the account they're seen on (group derived cards by `account_id, card_last4`); keep one top-level "Accounts" surface. No schema change.
- *Benefit:* One place to reason about money; matches real-world and competitor models.
- *Complexity:* Medium (regroup query + account-detail screen; presentation only).

**C2. The per-account "بطاقاتي" button opens the global card list.**
- *Current:* Every account row has a button that implies "this account's cards" but opens the unscoped global list (`accounts_screen.dart:210`).
- *Problem:* Directly lies about scope.
- *Why:* Breaks the user's spatial trust ("I tapped Account A's card icon and got everyone's cards").
- *Solution:* Remove the per-row button; put cards inside account detail (C1). If kept short-term, scope it to that account.
- *Benefit:* Navigation means what it says.
- *Complexity:* Low.

### HIGH

**H1. Account balance is invisible.**
- *Current:* `initialBalance`/`currentBalance` exist but no UI ever shows or edits them; always null.
- *Problem:* An accounts screen that can't answer "how much is in this account?" is missing its primary job.
- *Why:* Every benchmark makes per-account balance the hero number.
- *Solution:* Surface a balance per account (even if derived as opening balance + net flow), and let the user set an opening balance in the add/edit sheet (progressive — behind an "advanced" or optional field).
- *Benefit:* The screen becomes actually useful at a glance.
- *Complexity:* Medium (needs a balance source of truth decision; logic-adjacent — flag before building).

**H2. "اربط عملية موجودة" lists all transactions with no search.**
- *Current:* Full transaction list in a draggable sheet, sorted only by already-linked.
- *Problem:* Finding one transaction means scrolling everything.
- *Why:* High-friction for a routine correction.
- *Solution:* Add search + date filter, default to recent/unlinked; or better, do card assignment from the transaction detail (where the user already is).
- *Benefit:* Fewer taps, less scroll.
- *Complexity:* Low–Medium.

**H3. Card details is a 86%-height glass sheet doing a screen's job.**
- *Current:* Heavy blurred sheet + duplicate route `Scaffold` version unused.
- *Problem:* Visual weight and code duplication; inconsistent with router conventions.
- *Why:* Sheets are for quick, dismissible tasks; a card's full history is a destination.
- *Solution:* Make card detail a real routed screen (reuse the existing `/card/:last4` route), delete the sheet variant.
- *Benefit:* Consistency, back-stack correctness, less code.
- *Complexity:* Low.

### MEDIUM

**M1. Progressive disclosure in the account form.**
- *Current:* All 4 type chips + currency dropdown + default switch shown immediately.
- *Problem:* Most users have one currency and won't reason about wallet/bank/card.
- *Solution:* Default currency to the base currency and collapse it behind "خيارات متقدمة"; keep type but lead with the two common ones (cash, bank).
- *Benefit:* Faster, calmer create flow.
- *Complexity:* Low.

**M2. Clarify or drop `AccountType.card` vs derived cards.**
- *Current:* Two unrelated "card" concepts.
- *Problem:* Semantic collision.
- *Solution:* If Option A/B is adopted, reserve the credit-card visual for derived cards only, and rename `AccountType.card` in UI copy (e.g. "بطاقة مضافة يدويًا") or remove it from the picker.
- *Benefit:* One meaning per word.
- *Complexity:* Low (copy/UI), do not touch enum in DB.

**M3. "الحساب الافتراضي" explanation is jargon.**
- *Solution:* Replace "يُربط به الالتقاط التلقائي والإدخال السريع" with plain language ("العمليات الجديدة تتسجّل هنا تلقائيًا").
- *Complexity:* Trivial.

### LOW

**L1. Delete dead `cards_carousel.dart`.** (mention only — pre-existing, not from this audit's changes.)
**L2. `MyCardsScreen` uses `MaterialPageRoute` instead of the app router** — align with GoRouter for consistency and deep-linking.
**L3. Empty-state copy on cards promises "auto from SMS"** — good, but should also say cards can't be created manually so users don't hunt for an add button.

---

## PHASE 6 — Redesign direction (wireframes)

### Accounts screen (one container concept, balance-first)

```
┌───────────────────────────────────────┐
│  الحسابات                        [＋]   │
│  إجمالي الرصيد   ﷼ 12,430  👁          │
├───────────────────────────────────────┤
│ ⭐ بنك الراجحي            ﷼ 8,200      │
│    SAR · افتراضي                        │
│    ┌─────────────────────────────────┐ │
│    │ 💳 •••• 1234   Visa   خارج ﷼900 │ │  ← cards live INSIDE the account
│    │ 💳 •••• 5678   Mada   خارج ﷼120 │ │
│    └─────────────────────────────────┘ │
├───────────────────────────────────────┤
│   محفظة USD                 $ 540      │
│   USD                                   │
├───────────────────────────────────────┤
│   كاش                        ﷼ 300     │
│   SAR                                    │
└───────────────────────────────────────┘
```

### Account detail (card as child)

```
┌───────────────────────────────────────┐
│ ‹ بنك الراجحي                     ⋯    │
│  الرصيد   ﷼ 8,200                       │
│  داخل ﷼12,000   خارج ﷼3,800            │
├───────────────────────────────────────┤
│  البطاقات المكتشفة                       │
│  ┌───────────────┐ ┌───────────────┐   │
│  │ 💳 •••• 1234  │ │ 💳 •••• 5678  │   │  ← derived, tap → card screen
│  │ Visa          │ │ Mada          │   │
│  └───────────────┘ └───────────────┘   │
├───────────────────────────────────────┤
│  آخر العمليات …                         │
└───────────────────────────────────────┘
```

### Card screen (routed, not an 86% sheet)

```
┌───────────────────────────────────────┐
│ ‹ بطاقة •••• 1234                       │
│   ┌─────────────────────────────────┐  │
│   │  💳            Visa              │  │
│   │  ••••  ••••  ••••  1234          │  │
│   │  داخل ﷼0    خارج ﷼900           │  │
│   └─────────────────────────────────┘  │
│  [ إضافة عملية ]     [ عملياتها ]        │
│  ─ عمليات هذه البطاقة ───────────────   │
│  · ماكدونالدز        ﷼45               │
│  · نون               ﷼120              │
└───────────────────────────────────────┘
```

### Add / Edit Account (progressive)

```
Add:                          Edit:
┌─────────────────────────┐   ┌─────────────────────────┐
│ حساب جديد               │   │ تعديل حساب              │
│ [اسم الحساب__________]   │   │ [بنك الراجحي________]    │
│ النوع:  ● كاش  ○ بنك    │   │ النوع chips …           │
│ رصيد افتتاحي (اختياري)   │   │ رصيد افتتاحي ﷼5,000     │
│ ▸ خيارات متقدمة         │   │ العملة SAR              │
│   (العملة، افتراضي)      │   │ ⬤ الحساب الافتراضي      │
│ [ إضافة ]               │   │ [ حفظ ]   🗑 حذف        │
└─────────────────────────┘   └─────────────────────────┘
```

### Add / Edit Card

Cards are **auto-detected**, so there is no "add card" form. "Editing" a card = light metadata only (rename label, assign to an account if ambiguous, hide). Adding a *transaction* to a card stays, launched from the card screen.

```
┌─────────────────────────┐
│ بطاقة •••• 1234          │
│ اسم مختصر [_________]    │
│ الحساب:  بنك الراجحي ▾   │  ← resolves orphan cards
│ [ ] إخفاء من القائمة     │
│ [ حفظ ]                  │
└─────────────────────────┘
```

---

## One-line takeaway

The engineering (derived cards from SMS, no cards table) is sound and worth keeping. The **product** mistake is exposing cards and accounts as two unrelated top-level lists plus a third `AccountType.card` meaning. Collapse to a single container model — cards live inside the account they're seen on — surface per-account balance, and the whole area snaps into line with Revolut/Monzo/Apple/BudgetBakers without any database change.
