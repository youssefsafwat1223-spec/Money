revoke all on function public.create_subscription_and_record_payment(
  text, text, text, numeric, text, text, text, timestamptz, timestamptz, uuid,
  text, boolean, boolean, integer, text, text, integer, integer, numeric,
  numeric, text, numeric, numeric, timestamptz, timestamptz, timestamptz,
  integer, text
) from public, anon, authenticated;

drop function if exists public.create_subscription_and_record_payment(
  text, text, text, numeric, text, text, text, timestamptz, timestamptz, uuid,
  text, boolean, boolean, integer, text, text, integer, integer, numeric,
  numeric, text, numeric, numeric, timestamptz, timestamptz, timestamptz,
  integer, text
);

delete from public.feature_flags
where key = 'budget_progress_supabase_rpc';
