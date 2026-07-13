-- Review-only rollback. Export affected QA rows before executing because
-- dropping these columns can discard rollout data.

drop index if exists public.idx_user_transactions_duplicate_exact;
alter table public.user_transactions
  drop constraint if exists chk_user_transactions_comparison_source,
  drop constraint if exists chk_user_transactions_foreign_currency_format,
  drop constraint if exists chk_user_transactions_foreign_amount_positive,
  drop constraint if exists chk_user_transactions_status;

alter table public.user_transactions
  drop column if exists comparison_timestamp_source,
  drop column if exists comparison_timestamp,
  drop column if exists foreign_currency,
  drop column if exists foreign_amount,
  drop column if exists status;
