-- Extended account fields (Accounts & Cards A4): bank account number, credit
-- card fields, e-wallet provider, exclude-from-totals, and flexible metadata.
-- All additive + nullable/defaulted → backward compatible: existing rows get
-- NULL / false and keep working unchanged.

alter table user_accounts
  add column if not exists bank_account_number text;
alter table user_accounts
  add column if not exists credit_limit numeric;
alter table user_accounts
  add column if not exists available_credit numeric;
alter table user_accounts
  add column if not exists payment_due_day integer;
alter table user_accounts
  add column if not exists wallet_provider text;
alter table user_accounts
  add column if not exists exclude_from_totals boolean not null default false;
alter table user_accounts
  add column if not exists metadata jsonb;
