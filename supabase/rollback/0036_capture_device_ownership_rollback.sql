drop index if exists public.idx_processed_captures_install_claim_created;
alter table public.processed_captures drop column if exists claimed_user_id;
