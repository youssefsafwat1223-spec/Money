-- ROLLBACK for 0090_budget_category_key_reconciliation.sql (F-029)
--
-- 0090 adds ONE read-only diagnostic view, `budget_category_key_violations`,
-- which surfaces budget rows whose `category_id` is a per-device local id
-- rather than a stable catalog key. It changes no data and no policy.
--
-- Rolling it back is therefore safe and uninteresting: you lose visibility of
-- the defect, not any protection against it.

drop view if exists public.budget_category_key_violations;
