# Accounts & Cards — Technical Plan (v3, approved hybrid)

Approved: real `cards` table (source of truth) + keep derived grouping for auto-detect/backfill; parser/transactions/sync preserved. **Phase A1 implemented now (local card layer + safe backfill + tests + inert sync hook); all UI deferred until A1 is verified.** No commits.

---

## Duplicate-field check (before adding anything)
- **`starting_balance` already exists** as `accounts.initial_balance` (REAL NULL). **Reuse it** — do not add a `starting_balance` column.
- `accounts.current_balance` (REAL NULL) exists but is unreliable → keep the column, **compute** the displayed current balance (`initial_balance + confirmed income − confirmed expenses`); never treat the stored value as authoritative.
- New account columns needed later (A4), none pre-existing: `credit_limit`, `available_credit`, `payment_due_day`, `bank_account_number`, `wallet_provider`, `exclude_from_totals`.
- Card fields (`nickname`, `last4`, `network`, `source`) — no existing home; the derived `CardSummary` is a read-model, not storage. New `cards` table required.

---

## Data model

### Drift `cards` table (raw-SQL DB; add to `_createSchema`, bump `_targetSchemaVersion` 23 → 24)
```sql
CREATE TABLE IF NOT EXISTS cards(
  id TEXT PRIMARY KEY,
  account_id TEXT NOT NULL,
  nickname TEXT NULL,
  last4 TEXT NOT NULL,              -- normalized: digits only, last 4
  network TEXT NOT NULL,           -- CardNetwork.name; 'unknown' allowed
  source TEXT NOT NULL DEFAULT 'manual' CHECK(source IN ('manual','auto')),
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  server_id TEXT NULL,
  synced_at TEXT NULL,
  server_updated_at TEXT NULL,
  sync_status TEXT NULL CHECK(sync_status IN ('local_only','synced','pending','conflict')),
  deleted_at TEXT NULL
);
CREATE INDEX IF NOT EXISTS idx_cards_account ON cards(account_id);
CREATE UNIQUE INDEX IF NOT EXISTS uidx_cards_account_last4_active
  ON cards(account_id, last4) WHERE deleted_at IS NULL;
```
- Mirrors the `accounts` sync-column shape exactly (server_id/synced_at/server_updated_at/sync_status/deleted_at).
- **Uniqueness** = `(account_id, last4)` among non-deleted rows → enforces "not `last4` globally" (point 4). Same last4 in two accounts is allowed.
- Idempotent (`IF NOT EXISTS`) so re-running migration/rollback is safe.
- **No `card_id` on transactions** (point 4). Transactions keep `account_id + card_last4`; the app resolves the Card via `(account_id, normalize(card_last4))`.

### `CardEntity`
`id, accountId, nickname?, last4, network (CardNetwork), source (CardSource.manual|auto), createdAt, updatedAt`. (Sync columns stay in the repo/row layer, not the domain entity — same as `AccountEntity`.)

### Supabase migration (delivered as a file; owner applies — NOT auto-run)
`supabase/migrations/00XX_user_cards.sql`:
```sql
create table if not exists user_cards (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  local_id text not null,
  server_account_id uuid null references user_accounts(id) on delete set null,
  nickname text null,
  last4 text not null,
  network text not null default 'unknown',
  source text not null default 'manual' check (source in ('manual','auto')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz null,
  unique (user_id, local_id)
);
create unique index if not exists uidx_user_cards_owner_acct_last4
  on user_cards(user_id, server_account_id, last4) where deleted_at is null;
alter table user_cards enable row level security;
create policy user_cards_owner on user_cards
  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);
```

---

## Sync mapping (wired but INERT in A1)
- Add `PlanningOutboxQueue.cardsEntityType = 'card'` + `enqueueCard(op, card)` + `_buildCardPayload` (`local_id, server_account_id(local), nickname, last4, network, source, created_at, updated_at`, `deleted_at` on delete).
- `DriftCardRepository` calls `enqueueCard` on create/update/move/delete — exactly like accounts.
- **Gate:** `_isSyncEnabled('card')` returns **false** until a `cards_supabase_primary` flag + `user_cards` table exist. So `enqueueCard` no-ops (returns false, inserts nothing) → **zero change to the live sync engine, zero card rows in the outbox.**
- **Deferred to sub-phase A1b (after the Supabase migration is applied):** add `'card'` to `planning_push_service` `_entityTable`/`_localTable`/`_toServerRow`/`_fromServerRow`, the pull service, and `_planningEntitySyncEnabled`. Not touched in A1 to avoid destabilizing account/budget/goal sync that can't be re-verified here.

---

## CardRepository API
```dart
abstract class CardRepository {
  Future<List<CardEntity>> getAll();                                  // non-deleted
  Future<List<CardEntity>> getByAccount(String accountId);
  Future<CardEntity?> getById(String id);
  Future<CardEntity?> findByAccountAndLast4(String accountId, String last4);
  Future<CardEntity> create(CardEntity card);                         // dedup (account,last4)
  Future<CardEntity> update(CardEntity card);                         // nickname/network/source
  Future<CardEntity> moveToAccount({required String cardId, required String newAccountId});
  Future<void> delete(String id);                                     // soft-delete
  Future<int> backfillFromTransactions();                             // idempotent, returns created count
}
```
- `normalizeLast4(raw)`: keep digits, take last 4; reject if <4 digits.
- `create`/`update` enforce the `(account_id, last4)` active-uniqueness (catch the unique-index violation → `ValidationRepoException`).

## Backfill & deduplication rules (safe, idempotent)
- Source: the existing `CardAccountGrouper` over `getCardAccountBreakdown()`.
- For each `grouping.byAccount[accountId]` card → if no active `cards` row for `(accountId, normalized last4)`, insert one with `source='auto'`, network = the summary's detected network.
- `grouping.unassigned` → **not** backfilled (no confident account; stays derived-Unassigned).
- Dedup: the active unique index + a pre-check make re-running a no-op. Manual rows already present are never overwritten.
- Runs once as a guarded step (like other `_backfill*` steps) and is also exposed as `backfillFromTransactions()` for tests.

## Delete / move behavior (explicitly)
- **Delete card** → soft-delete (`deleted_at`), enqueue delete. **Transactions are untouched**: their `account_id` and `card_last4` stay, so historical rows keep showing `••••1234` and remain in the account's history. The card simply disappears from the managed list. If a later SMS with that last4 arrives on the same account, auto-detect may recreate an `auto` card (documented, expected). *No transaction is ever deleted with a card.*
- **Move card** → change `account_id` (+ updated_at), enqueue update. **Historical transactions do not move** (their `account_id` is independent); only *future* transactions matching `(newAccount, last4)` resolve to the moved card. Surfaced in the move confirmation copy.

## Offline-first behavior
- All card CRUD writes local Drift first and returns immediately; `enqueueCard` (when enabled) records intent for later push. No network on the write path.
- Reads always from Drift. Card resolution `(account_id, last4)` is a local query.

## Conflict resolution
- Same model as accounts: `sync_status` + `server_updated_at`, last-write-wins by `updated_at` in the pull service (A1b). Active-unique index prevents duplicate `(account,last4)`; on a server/local collision the newer `updated_at` wins, the loser is soft-deleted/merged. (Not exercised in A1 since sync is inert.)

## Rollback strategy
- Additive only: new table + version bump. To roll back code, revert the Dart changes; the `cards` table can stay (unused, `IF NOT EXISTS`-safe) — no data loss to accounts/transactions.
- Backfill is idempotent and reversible (rows soft-deletable). No transaction data is mutated by any card operation, so there is nothing to un-migrate there.
- Note: the app forbids opening a DB whose `user_version` exceeds target, so a *downgrade* requires the table to already exist harmlessly — which it does.

## Tests per phase
- **A1 (now):** normalizeLast4 edge cases; create/getByAccount/getById/findByAccountAndLast4; `(account,last4)` dedup rejects duplicate, allows same last4 across accounts; update changes metadata not identity; move changes account; delete soft-deletes and leaves transactions intact; backfill creates expected auto cards, is idempotent, skips unassigned, never overwrites manual. Full `flutter analyze` + `flutter test`.
- A2 (SMS auto-link): known last4 links to existing card; new last4 on identified account creates auto card; unresolved account → Unassigned.
- A3 (card UI): add/edit/delete/move flows persist; auto card rename promotes to managed.
- A4 (account form): each type renders its fields; metadata + typed columns persist; advanced hidden by default.
- A5 (behavior): exclude_from_totals drops account from combined totals; account_number improves match.

---

## Phase order & gates
A1 (local entity/table/repo/backfill/tests + inert sync hook + Supabase migration file) → **verify** → A1b (server sync wiring, after migration applied) → A2 → A3 → A4 → A5. Each: analyze + full test, no commits.
