-- Real Card entity — server mirror for offline-first sync (S1).
-- Follows the EXACT same pattern as user_budgets / user_goals / user_plans:
-- the client is the source of truth for identity (local_id) and references the
-- owning account by local_account_id (text), NOT a server UUID FK. Sync is
-- push/pull via the shared planning sync engine; the UI always reads Drift.

create table if not exists user_cards (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  local_id text not null,
  local_account_id text not null,
  nickname text null,
  last4 text not null,
  network text not null default 'unknown',
  source text not null default 'manual' check (source in ('manual', 'auto')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz null,
  unique (user_id, local_id)
);

create index if not exists idx_user_cards_owner on user_cards(user_id);

-- One active card per (user, account, last4) — mirrors the client's
-- (account_id, last4) active-uniqueness. Same last4 in different accounts is OK.
create unique index if not exists uidx_user_cards_owner_acct_last4
  on user_cards(user_id, local_account_id, last4)
  where deleted_at is null;

-- Keep updated_at fresh on every write (used for pull ordering / LWW).
create or replace function set_user_cards_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end $$;

drop trigger if exists trg_user_cards_updated_at on user_cards;
create trigger trg_user_cards_updated_at
  before update on user_cards
  for each row execute function set_user_cards_updated_at();

alter table user_cards enable row level security;

drop policy if exists user_cards_owner on user_cards;
create policy user_cards_owner on user_cards
  for all
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);
