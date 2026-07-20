-- Found via a live user report: budget-over notifications kept re-firing on
-- every app open with a frozen amount. Root cause traced to
-- `user_budgets` having no uniqueness constraint on (user_id, local_id) —
-- every client repository's `save()` already has a `local_id`-based
-- resolve-existing-row step plus an `on 23505 -> re-fetch by local_id`
-- recovery path (see supabase_budget_repository.dart, _support.dart), but
-- with no DB-level constraint to ever raise 23505, a resolution failure
-- (which can happen, e.g., when the in-memory entity being re-saved carries
-- the local id rather than the server id) silently INSERTs a brand-new row
-- instead of updating the existing one. For a periodically-resaved entity
-- (budgets re-save themselves on every daily/weekly/monthly period
-- rollover — see budget_progress_usecase.dart's _rollBudgetIfNeeded), this
-- produces one duplicate active row per rollover, each starting fresh with
-- alert_100_sent/alert_80_sent = false, so the "budget exceeded" alert
-- re-fires forever even though the real, single logical budget only
-- crossed the threshold once. Confirmed live: 3 user_budgets rows, same
-- local_id, 3 different server ids, all is_active = true.
--
-- This migration (1) deduplicates the one live occurrence found, keeping
-- the most-recently-updated row per (user_id, local_id) and soft-deleting
-- the rest, then (2) adds the missing partial unique index everywhere the
-- same local_id + resolve + 23505-recovery pattern already exists in
-- client code, so a resolution failure degrades to "found the existing
-- row and updated it" instead of silently duplicating data. Tables using a
-- different idempotency mechanism (user_transactions: fingerprint-based;
-- user_smart_inbox / user_plan_transaction_links: no local_id column) are
-- intentionally not touched here.

-- ── 1. Deduplicate the confirmed live occurrence in user_budgets ──────────
with ranked as (
  select
    id,
    row_number() over (
      partition by user_id, local_id
      order by updated_at desc, created_at desc
    ) as rn
  from user_budgets
  where deleted_at is null and local_id is not null
)
update user_budgets
set deleted_at = now()
where id in (select id from ranked where rn > 1);

-- ── 2. Partial unique indexes (local_id can be null for legacy/local-only
--    rows that never synced, so uniqueness only applies once populated) ──
create unique index if not exists user_budgets_user_local_id_key
  on user_budgets (user_id, local_id) where local_id is not null;

create unique index if not exists user_accounts_user_local_id_key
  on user_accounts (user_id, local_id) where local_id is not null;

create unique index if not exists user_goals_user_local_id_key
  on user_goals (user_id, local_id) where local_id is not null;

create unique index if not exists user_bill_payments_user_local_id_key
  on user_bill_payments (user_id, local_id) where local_id is not null;

create unique index if not exists user_plans_user_local_id_key
  on user_plans (user_id, local_id) where local_id is not null;

create unique index if not exists user_subscriptions_user_local_id_key
  on user_subscriptions (user_id, local_id) where local_id is not null;
