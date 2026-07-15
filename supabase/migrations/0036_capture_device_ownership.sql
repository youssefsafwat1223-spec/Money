-- Permanently stamps relay ownership at capture time. The mutable device link
-- is no longer used to infer ownership of already-created rows.

alter table public.processed_captures
  add column if not exists claimed_user_id uuid null;

create index if not exists idx_processed_captures_install_claim_created
  on public.processed_captures(install_id_hash, claimed_user_id, created_at);
