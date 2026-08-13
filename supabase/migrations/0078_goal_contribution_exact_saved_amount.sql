-- 0078_goal_contribution_exact_saved_amount.sql — MALI-026 (Phase-9B forward-activation remediation).
--
-- Additive, backward-compatible RPC contract fix. NOT DEPLOYED in this checkpoint.
--
-- WHY. The canonical goal-contribution PUSH branch in PlanningChildSyncService reads
-- the parent goal's NEW saved amount as an EXACT decimal STRING
-- (`goal.saved_amount_text`) so it can write the canonical `_minor` authority + the
-- REAL shadow without ever touching a binary double. But `add_goal_contribution`
-- (migration 0031) returns the goal via `to_jsonb(goal_row)`, which serializes
-- `saved_amount` as a JSON NUMBER and provides NO `saved_amount_text`. Under the
-- canonical cutover that read is null → the client fails closed
-- (MoneyTransportException) on every contribution. The RPC was never updated to the
-- exact-text response the client expects; this migration delivers it.
--
-- FIX (ADDITIVE). Recreate the function with the SAME signature, the SAME
-- auth/ownership checks, SECURITY INVOKER, search_path hardening, exactly-once
-- semantics, and transaction behavior. The ONLY change is the response shape: the
-- `goal` member now ALSO carries `saved_amount_text` = the PostgreSQL NUMERIC
-- rendered as exact text (`goal_row.saved_amount::text` — server-side NUMERIC→text,
-- never a float/double round-trip). The legacy `saved_amount` JSON number is
-- preserved unchanged (via `to_jsonb(goal_row)`), so old clients keep working
-- exactly as before.
--
-- CURRENCY AUTHORITY UNCHANGED. A contribution has no currency of its own; the
-- parent goal's currency remains the sole authority. This migration adds no currency
-- column to user_goal_contributions and no base/account/transaction fallback.
--
-- Forward-recovery: CREATE OR REPLACE is idempotent; the grants are re-asserted
-- identically to 0031 (no EXECUTE broadening).

create or replace function public.add_goal_contribution(
  p_goal_id uuid,
  p_client_request_id text,
  p_local_id text,
  p_amount numeric,
  p_created_at timestamptz,
  p_note text default null
) returns jsonb language plpgsql security invoker set search_path = public as $$
declare
  contribution_row public.user_goal_contributions%rowtype;
  goal_row public.user_goals%rowtype;
begin
  if auth.uid() is null then raise exception 'authentication required' using errcode = '42501'; end if;
  if p_amount <= 0 then raise exception 'amount must be positive' using errcode = '22023'; end if;
  select * into goal_row from public.user_goals
    where id = p_goal_id and user_id = auth.uid() and deleted_at is null for update;
  if goal_row.id is null then raise exception 'goal not found' using errcode = 'P0002'; end if;

  insert into public.user_goal_contributions(
    user_id, goal_id, local_id, client_request_id, amount, note, created_at
  ) values (
    auth.uid(), p_goal_id, p_local_id, p_client_request_id, p_amount, p_note,
    coalesce(p_created_at, now())
  ) on conflict (user_id, client_request_id) do nothing returning * into contribution_row;

  if contribution_row.id is null then
    select * into contribution_row from public.user_goal_contributions
      where user_id = auth.uid() and client_request_id = p_client_request_id;
  else
    update public.user_goals set saved_amount = saved_amount + p_amount
      where id = p_goal_id and user_id = auth.uid() returning * into goal_row;
  end if;
  select * into goal_row from public.user_goals
    where id = p_goal_id and user_id = auth.uid();

  -- ADDITIVE exact-money response: preserve every existing goal field (including the
  -- legacy `saved_amount` JSON number carried by to_jsonb) and ADD `saved_amount_text`
  -- = exact NUMERIC text. `||` merges the new key without dropping any existing one.
  return jsonb_build_object(
    'contribution', to_jsonb(contribution_row),
    'goal', to_jsonb(goal_row)
              || jsonb_build_object('saved_amount_text', goal_row.saved_amount::text)
  );
end;
$$;

-- EXECUTE authority re-asserted IDENTICALLY to 0031 (no broadening). CREATE OR
-- REPLACE preserves existing ACLs; re-asserting makes the intended authority explicit
-- and independently testable. service_role retains its Supabase default-privilege
-- EXECUTE (unchanged); no grant to anon/public is added.
revoke all on function public.add_goal_contribution(uuid, text, text, numeric, timestamptz, text) from public, anon;
grant execute on function public.add_goal_contribution(uuid, text, text, numeric, timestamptz, text) to authenticated;
