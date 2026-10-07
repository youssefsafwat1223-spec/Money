-- 0107_sync_cas_rpcs.sql — WP-2 (manifest 0108): insert-if-absent / CAS update /
-- CAS tombstone RPCs for the parent table families, per manifest §4.9.
--
-- NOT USED BY ANY CLIENT YET: the capability `revision_cas` stays false (0114).
-- Everything is additive; build-50 clients never call these.
--
-- FAMILIES (p_table, allowlisted by sync_family(); anything else raises 22023):
--   user_transactions (identity client_request_id), user_accounts, user_budgets,
--   user_goals, user_plans, user_subscriptions, user_cards, user_categories
--   (identity local_id). One generic implementation instead of 8x3 near-identical
--   functions; the table, every column and the identity column come only from the
--   allowlist (format %I), never from caller text.
-- NOT included: user_settings (field-patch LWW with consent excluded, §4.6/§14),
--   the append-only children (own idempotent RPCs), user_smart_inbox /
--   sender_bank_mappings (monotonic-state / natural-key protocols), gamification.
-- user_categories has no tombstone RPC (deletes go through
--   delete_user_category_safely, which re-parents dependants).
--
-- Common protocol (every RPC):
--   1. sync_lock_epoch() takes the caller's user_sync_state row lock FIRST and
--      returns the current epoch (derived from auth.uid(); no caller-chosen user).
--   2. p_expected_epoch <> epoch (or NULL) -> {outcome:'epoch_mismatch', epoch}.
--   3. The work, as the invoker: RLS applies and every statement filters
--      user_id = auth.uid(). Hence SECURITY INVOKER; only the lock helper is
--      SECURITY DEFINER (authenticated has no UPDATE grant on user_sync_state).
--   Result: jsonb {outcome, row}. Outcomes: inserted, adopted, ack, applied,
--   conflict, not_found, epoch_mismatch. Writes set last_op_id = p_op_id;
--   revision/updated_at/sync_seq come from the existing triggers (0068, 0105).
--
-- sync_insert_if_absent(p_table, p_expected_epoch, p_op_id, p_row):
--   a. Look up the row by (user_id, identity) INCLUDING tombstones. A deleted row
--      is {conflict, row}: the RPC NEVER clears deleted_at and never writes.
--   b. Same op (row.last_op_id = p_op_id): lost ACK -> {ack, row}.
--   c. Foreign op: compare the NORMALIZED client-owned fields present in p_row
--      (sync_normalize: text btrim + ''->null, currency upper-case, numerics
--      scale-insensitive, timestamps UTC truncated to ms). Equal -> {adopted,
--      server row}; different -> {conflict, server row}. user_transactions
--      compares amount, currency, transaction_type, direction, status,
--      occurred_at, merchant, description, category_id, server_account_id,
--      foreign_amount, foreign_currency and metadata.last4 (card_last4). Other
--      families compare every writable field except metadata. Never compared:
--      revision, created_at, updated_at, sync_seq, id, last_op_id, user_id and
--      server-managed columns (goals.saved_amount, budget/goal last_notified_*,
--      subscriptions.paid_count - insert-only here, and accounts.is_default -
--      a command RPC).
--   d. Absent: insert (user_id = auth.uid(), last_op_id = p_op_id) -> {inserted}.
--      A different unique index clashing (e.g. card user+account+last4) ->
--      {conflict, row:null, reason:'unique_violation'}.
-- sync_cas_update(p_table, p_expected_epoch, p_op_id, p_id, p_expected_revision, p_patch):
--   UPDATE .. WHERE id = p_id AND revision = p_expected_revision AND deleted_at IS
--   NULL -> {applied}. Zero rows: absent -> {not_found}; last_op_id = p_op_id ->
--   {ack}; else {conflict} (stale revision, or the row was tombstoned: remote
--   tombstone wins). Only allowlisted writable keys of p_patch are applied;
--   unknown/server-managed keys are ignored; an empty effective patch raises 22023.
-- sync_cas_tombstone(p_table, p_expected_epoch, p_op_id, p_id, p_expected_revision):
--   sets deleted_at = now() with the same CAS -> {applied}. Zero rows: already
--   deleted -> {ack}; absent -> {not_found}; else {conflict}.

BEGIN;

-- ── allowlist ──────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.sync_family(
  p_table text,
  OUT id_col text,
  OUT write_cols text[],
  OUT insert_cols text[],
  OUT cmp_cols text[],
  OUT can_delete boolean
)
LANGUAGE plpgsql
IMMUTABLE
SET search_path = public
AS $$
BEGIN
  insert_cols := '{}';
  can_delete := true;
  id_col := 'local_id';
  CASE p_table
    WHEN 'user_transactions' THEN
      id_col := 'client_request_id';
      write_cols := ARRAY['amount', 'currency', 'direction', 'transaction_type', 'source',
        'occurred_at', 'merchant', 'description', 'status', 'local_account_id',
        'server_account_id', 'category_id', 'user_category_id', 'confidence',
        'balance_after', 'foreign_amount', 'foreign_currency', 'metadata',
        'comparison_timestamp', 'comparison_timestamp_source'];
      cmp_cols := ARRAY['amount', 'currency', 'transaction_type', 'direction', 'status',
        'occurred_at', 'merchant', 'description', 'category_id', 'server_account_id',
        'foreign_amount', 'foreign_currency'];
    WHEN 'user_accounts' THEN
      write_cols := ARRAY['name', 'currency', 'type', 'initial_balance', 'current_balance',
        'sort_order', 'metadata', 'bank_account_number', 'credit_limit', 'available_credit',
        'payment_due_day', 'wallet_provider', 'exclude_from_totals'];
    WHEN 'user_budgets' THEN
      write_cols := ARRAY['local_account_id', 'server_account_id', 'category_id', 'amount',
        'period', 'start_date', 'is_active', 'show_on_header', 'metadata',
        'user_category_id', 'currency'];
    WHEN 'user_goals' THEN
      write_cols := ARRAY['local_account_id', 'server_account_id', 'name', 'target_amount',
        'deadline', 'vault_skin', 'status', 'auto_save_amount', 'auto_save_period',
        'auto_save_last_run', 'metadata', 'currency'];
      insert_cols := ARRAY['saved_amount'];
    WHEN 'user_plans' THEN
      write_cols := ARRAY['name', 'budget_amount', 'currency', 'start_date', 'end_date',
        'local_account_ids', 'card_last4s', 'status', 'icon', 'metadata', 'server_account_ids'];
    WHEN 'user_subscriptions' THEN
      write_cols := ARRAY['local_account_id', 'server_account_id', 'merchant_id', 'name',
        'amount', 'currency', 'type', 'frequency', 'next_due_date', 'reminder_on',
        'is_confirmed', 'custom_interval_days', 'note', 'status', 'total_installments',
        'manual_paid_amount', 'total_purchase_amount', 'lender_name', 'interest_rate',
        'metadata'];
      insert_cols := ARRAY['paid_count'];
    WHEN 'user_cards' THEN
      write_cols := ARRAY['local_account_id', 'nickname', 'last4', 'network', 'source',
        'color_theme', 'accent_hex'];
    WHEN 'user_categories' THEN
      write_cols := ARRAY['key', 'name_ar', 'icon', 'color', 'is_income', 'sort_order'];
      can_delete := false;
    ELSE
      RAISE EXCEPTION 'sync_unsupported_table' USING ERRCODE = '22023';
  END CASE;
  IF cmp_cols IS NULL THEN
    cmp_cols := array_remove(write_cols, 'metadata');
  END IF;
END;
$$;

-- ── comparison normalizer ──────────────────────────────────────────────────
-- p_rec is to_jsonb(<typed row>); p_cols are column names (plus the pseudo
-- column 'card_last4' = metadata->>'last4'). Returns one jsonb value per column.
CREATE OR REPLACE FUNCTION public.sync_normalize(p_table text, p_rec jsonb, p_cols text[])
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SET search_path = public
AS $$
DECLARE
  f text;
  v text;
  ty text;
  n jsonb;
  res jsonb := '{}'::jsonb;
BEGIN
  FOREACH f IN ARRAY p_cols LOOP
    IF f = 'card_last4' THEN
      v := p_rec -> 'metadata' ->> 'last4';
      ty := 'text';
    ELSE
      v := p_rec ->> f;
      SELECT a.atttypid::regtype::text INTO ty
      FROM pg_attribute a
      WHERE a.attrelid = format('public.%I', p_table)::regclass
        AND a.attname = f AND NOT a.attisdropped;
    END IF;
    IF v IS NULL THEN
      n := 'null'::jsonb;
    ELSIF ty = 'timestamp with time zone' THEN
      n := to_jsonb(to_char(date_trunc('milliseconds', v::timestamptz) AT TIME ZONE 'UTC',
                            'YYYY-MM-DD"T"HH24:MI:SS.MS'));
    ELSIF ty = 'numeric' THEN
      n := to_jsonb(trim_scale(v::numeric));
    ELSIF ty = 'text' THEN
      v := nullif(btrim(v), '');
      n := CASE WHEN v IS NULL THEN 'null'::jsonb
                WHEN f LIKE '%currency' THEN to_jsonb(upper(v))
                ELSE to_jsonb(v) END;
    ELSE
      n := to_jsonb(v);
    END IF;
    res := res || jsonb_build_object(f, n);
  END LOOP;
  RETURN res;
END;
$$;

-- ── lock + epoch (the only SECURITY DEFINER piece) ─────────────────────────
-- Locks and reads the CALLER's own state row (identity from auth.uid(), never a
-- parameter, so it cannot be used to lock another user). Creates the row if the
-- user somehow has none.
CREATE OR REPLACE FUNCTION public.sync_lock_epoch()
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_epoch uuid;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'authentication required' USING ERRCODE = '28000';
  END IF;
  INSERT INTO public.user_sync_state (user_id, epoch_reason)
  VALUES (v_uid, 'initial')
  ON CONFLICT (user_id) DO NOTHING;
  SELECT epoch INTO v_epoch FROM public.user_sync_state WHERE user_id = v_uid FOR UPDATE;
  RETURN v_epoch;
END;
$$;

REVOKE ALL ON FUNCTION public.sync_lock_epoch() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.sync_lock_epoch() TO authenticated;

-- ── insert-if-absent ───────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.sync_insert_if_absent(
  p_table text,
  p_expected_epoch uuid,
  p_op_id uuid,
  p_row jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public
AS $$
DECLARE
  v_cfg record;
  v_uid uuid := auth.uid();
  v_epoch uuid;
  v_key text;
  v_row jsonb;
  v_new jsonb;
  v_in jsonb;
  v_cmp text[];
  v_cols text[];
BEGIN
  SELECT * INTO v_cfg FROM public.sync_family(p_table);
  IF p_op_id IS NULL OR p_row IS NULL OR jsonb_typeof(p_row) <> 'object' THEN
    RAISE EXCEPTION 'sync_invalid_request' USING ERRCODE = '22023';
  END IF;
  v_key := nullif(p_row ->> v_cfg.id_col, '');
  IF v_key IS NULL THEN
    RAISE EXCEPTION 'sync_invalid_request' USING ERRCODE = '22023';
  END IF;

  v_epoch := public.sync_lock_epoch();
  IF p_expected_epoch IS DISTINCT FROM v_epoch THEN
    RETURN jsonb_build_object('outcome', 'epoch_mismatch', 'row', null::jsonb, 'epoch', v_epoch);
  END IF;

  EXECUTE format('SELECT to_jsonb(t.*) FROM public.%I t WHERE t.user_id = $1 AND t.%I = $2',
                 p_table, v_cfg.id_col)
    INTO v_row USING v_uid, v_key;

  IF v_row IS NOT NULL THEN
    -- 1. tombstone check first: never un-delete, never write.
    IF v_row ->> 'deleted_at' IS NOT NULL THEN
      RETURN jsonb_build_object('outcome', 'conflict', 'row', v_row);
    END IF;
    -- 2. same operation: lost ACK.
    IF (v_row ->> 'last_op_id')::uuid = p_op_id THEN
      RETURN jsonb_build_object('outcome', 'ack', 'row', v_row);
    END IF;
    -- 3. foreign operation: normalized client-owned fields.
    v_cmp := ARRAY(SELECT c FROM unnest(v_cfg.cmp_cols) c WHERE p_row ? c);
    IF p_table = 'user_transactions' AND p_row ? 'metadata' THEN
      v_cmp := array_append(v_cmp, 'card_last4');
    END IF;
    EXECUTE format('SELECT to_jsonb(r) FROM jsonb_populate_record(NULL::public.%I, $1) r', p_table)
      INTO v_in USING p_row;
    IF public.sync_normalize(p_table, v_in, v_cmp) = public.sync_normalize(p_table, v_row, v_cmp) THEN
      RETURN jsonb_build_object('outcome', 'adopted', 'row', v_row);
    END IF;
    RETURN jsonb_build_object('outcome', 'conflict', 'row', v_row);
  END IF;

  v_cols := ARRAY(
    SELECT k FROM jsonb_object_keys(p_row) k
    WHERE k = v_cfg.id_col OR k = ANY (v_cfg.write_cols || v_cfg.insert_cols));
  BEGIN
    EXECUTE format(
      'INSERT INTO public.%1$I AS t (user_id, last_op_id, %2$s) '
      || 'SELECT $2, $3, %3$s FROM jsonb_populate_record(NULL::public.%1$I, $1) r '
      || 'RETURNING to_jsonb(t.*)',
      p_table,
      (SELECT string_agg(format('%I', c), ', ') FROM unnest(v_cols) c),
      (SELECT string_agg(format('r.%I', c), ', ') FROM unnest(v_cols) c))
      INTO v_new USING p_row, v_uid, p_op_id;
  EXCEPTION WHEN unique_violation THEN
    RETURN jsonb_build_object('outcome', 'conflict', 'row', null::jsonb, 'reason', 'unique_violation');
  END;
  RETURN jsonb_build_object('outcome', 'inserted', 'row', v_new);
END;
$$;

-- ── CAS update ─────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.sync_cas_update(
  p_table text,
  p_expected_epoch uuid,
  p_op_id uuid,
  p_id uuid,
  p_expected_revision integer,
  p_patch jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public
AS $$
DECLARE
  v_cfg record;
  v_uid uuid := auth.uid();
  v_epoch uuid;
  v_set text;
  v_row jsonb;
BEGIN
  SELECT * INTO v_cfg FROM public.sync_family(p_table);
  IF p_op_id IS NULL OR p_id IS NULL OR p_expected_revision IS NULL
     OR p_patch IS NULL OR jsonb_typeof(p_patch) <> 'object' THEN
    RAISE EXCEPTION 'sync_invalid_request' USING ERRCODE = '22023';
  END IF;
  SELECT string_agg(format('%1$I = r.%1$I', k), ', ') INTO v_set
  FROM jsonb_object_keys(p_patch) k WHERE k = ANY (v_cfg.write_cols);
  IF v_set IS NULL THEN
    RAISE EXCEPTION 'sync_invalid_request' USING ERRCODE = '22023';
  END IF;

  v_epoch := public.sync_lock_epoch();
  IF p_expected_epoch IS DISTINCT FROM v_epoch THEN
    RETURN jsonb_build_object('outcome', 'epoch_mismatch', 'row', null::jsonb, 'epoch', v_epoch);
  END IF;

  EXECUTE format(
    'UPDATE public.%1$I AS t SET %2$s, last_op_id = $2 '
    || 'FROM jsonb_populate_record(NULL::public.%1$I, $1) r '
    || 'WHERE t.id = $3 AND t.user_id = $4 AND t.revision = $5 AND t.deleted_at IS NULL '
    || 'RETURNING to_jsonb(t.*)',
    p_table, v_set)
    INTO v_row USING p_patch, p_op_id, p_id, v_uid, p_expected_revision;
  IF v_row IS NOT NULL THEN
    RETURN jsonb_build_object('outcome', 'applied', 'row', v_row);
  END IF;

  EXECUTE format('SELECT to_jsonb(t.*) FROM public.%I t WHERE t.id = $1 AND t.user_id = $2', p_table)
    INTO v_row USING p_id, v_uid;
  IF v_row IS NULL THEN
    RETURN jsonb_build_object('outcome', 'not_found', 'row', null::jsonb);
  ELSIF (v_row ->> 'last_op_id')::uuid = p_op_id THEN
    RETURN jsonb_build_object('outcome', 'ack', 'row', v_row);
  END IF;
  RETURN jsonb_build_object('outcome', 'conflict', 'row', v_row);
END;
$$;

-- ── CAS tombstone ──────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.sync_cas_tombstone(
  p_table text,
  p_expected_epoch uuid,
  p_op_id uuid,
  p_id uuid,
  p_expected_revision integer
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public
AS $$
DECLARE
  v_cfg record;
  v_uid uuid := auth.uid();
  v_epoch uuid;
  v_row jsonb;
BEGIN
  SELECT * INTO v_cfg FROM public.sync_family(p_table);
  IF NOT v_cfg.can_delete THEN
    RAISE EXCEPTION 'sync_unsupported_table' USING ERRCODE = '22023';
  END IF;
  IF p_op_id IS NULL OR p_id IS NULL OR p_expected_revision IS NULL THEN
    RAISE EXCEPTION 'sync_invalid_request' USING ERRCODE = '22023';
  END IF;

  v_epoch := public.sync_lock_epoch();
  IF p_expected_epoch IS DISTINCT FROM v_epoch THEN
    RETURN jsonb_build_object('outcome', 'epoch_mismatch', 'row', null::jsonb, 'epoch', v_epoch);
  END IF;

  EXECUTE format(
    'UPDATE public.%I AS t SET deleted_at = now(), last_op_id = $1 '
    || 'WHERE t.id = $2 AND t.user_id = $3 AND t.revision = $4 AND t.deleted_at IS NULL '
    || 'RETURNING to_jsonb(t.*)', p_table)
    INTO v_row USING p_op_id, p_id, v_uid, p_expected_revision;
  IF v_row IS NOT NULL THEN
    RETURN jsonb_build_object('outcome', 'applied', 'row', v_row);
  END IF;

  EXECUTE format('SELECT to_jsonb(t.*) FROM public.%I t WHERE t.id = $1 AND t.user_id = $2', p_table)
    INTO v_row USING p_id, v_uid;
  IF v_row IS NULL THEN
    RETURN jsonb_build_object('outcome', 'not_found', 'row', null::jsonb);
  ELSIF v_row ->> 'deleted_at' IS NOT NULL THEN
    RETURN jsonb_build_object('outcome', 'ack', 'row', v_row);
  END IF;
  RETURN jsonb_build_object('outcome', 'conflict', 'row', v_row);
END;
$$;

-- The two pure helpers run inside the invoker's RPCs, so authenticated needs EXECUTE.
REVOKE ALL ON FUNCTION public.sync_family(text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.sync_normalize(text, jsonb, text[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.sync_family(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.sync_normalize(text, jsonb, text[]) TO authenticated;
REVOKE ALL ON FUNCTION public.sync_insert_if_absent(text, uuid, uuid, jsonb) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.sync_cas_update(text, uuid, uuid, uuid, integer, jsonb) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.sync_cas_tombstone(text, uuid, uuid, uuid, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.sync_insert_if_absent(text, uuid, uuid, jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.sync_cas_update(text, uuid, uuid, uuid, integer, jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.sync_cas_tombstone(text, uuid, uuid, uuid, integer) TO authenticated;

COMMIT;
