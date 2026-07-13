-- Additive parity fields needed by the direct TransactionRepository.
-- Raw SMS text remains device-only and is deliberately not stored here.

alter table public.user_transactions
  add column if not exists status text not null default 'confirmed',
  add column if not exists foreign_amount numeric null,
  add column if not exists foreign_currency text null,
  add column if not exists comparison_timestamp timestamptz null,
  add column if not exists comparison_timestamp_source text not null default 'received_at';

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'chk_user_transactions_status'
      and conrelid = 'public.user_transactions'::regclass
  ) then
    alter table public.user_transactions
      add constraint chk_user_transactions_status
      check (status in ('confirmed', 'pending', 'ignored'));
  end if;

  if not exists (
    select 1 from pg_constraint
    where conname = 'chk_user_transactions_foreign_amount_positive'
      and conrelid = 'public.user_transactions'::regclass
  ) then
    alter table public.user_transactions
      add constraint chk_user_transactions_foreign_amount_positive
      check (foreign_amount is null or foreign_amount > 0);
  end if;

  if not exists (
    select 1 from pg_constraint
    where conname = 'chk_user_transactions_foreign_currency_format'
      and conrelid = 'public.user_transactions'::regclass
  ) then
    alter table public.user_transactions
      add constraint chk_user_transactions_foreign_currency_format
      check (foreign_currency is null or foreign_currency ~ '^[A-Z]{3}$');
  end if;

  if not exists (
    select 1 from pg_constraint
    where conname = 'chk_user_transactions_comparison_source'
      and conrelid = 'public.user_transactions'::regclass
  ) then
    alter table public.user_transactions
      add constraint chk_user_transactions_comparison_source
      check (comparison_timestamp_source in ('sms_body', 'received_at'));
  end if;
end $$;

create index if not exists idx_user_transactions_duplicate_exact
  on public.user_transactions(user_id, amount, currency, comparison_timestamp)
  where deleted_at is null;
