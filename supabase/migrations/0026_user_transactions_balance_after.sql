-- Phase 2: additive balance_after column for latestBalanceAfter() support.
-- Populated by the on-device Dart SMS parser (lib/engine/parser/), which
-- already extracts a post-transaction balance where the bank SMS states one.
-- The process-ios-sms edge function's own parser does not extract a balance
-- today, so no edge-function change accompanies this migration.

alter table public.user_transactions
  add column if not exists balance_after numeric null;
