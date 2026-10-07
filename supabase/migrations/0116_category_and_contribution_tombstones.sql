-- 0116_category_and_contribution_tombstones.sql — D1 (user decision 5): the two
-- deletes that had no safe, idempotent server path.
--
-- ADDITIVE and NOT USED BY ANY CLIENT YET: the capability `revision_cas` stays
-- false (0114) and no function here changes an existing function or grant.
-- Both RPCs are tombstone-only (UPDATE ... deleted_at; never a hard DELETE, 0115
-- revoked it), SECURITY INVOKER (RLS applies; every statement also filters
-- user_id = auth.uid()), and take the caller's epoch lock FIRST via
-- sync_lock_epoch() (0107), so a stale replica gets {epoch_mismatch} and writes
-- nothing. Result vocabulary = 0107: applied / ack / conflict / not_found /
-- epoch_mismatch.
--
-- sync_cas_tombstone_category(p_expected_epoch, p_op_id, p_id, p_expected_revision)
--   user_categories is excluded from sync_cas_tombstone (0107) because deleting a
--   category must re-parent its dependants. This is the same CAS tombstone plus
--   that re-parenting, in ONE statement sequence (atomic):
--     UPDATE user_categories SET deleted_at = now(), last_op_id = p_op_id
--       WHERE id = p_id AND user_id = auth.uid() AND revision = p_expected_revision
--         AND deleted_at IS NULL                                      -> {applied}
--     then, only when applied, exactly what delete_user_category_safely (0044)
--     does: live transactions and budgets that point at the category get
--     user_category_id = NULL, category_id = 'other'.
--   Zero rows: absent -> {not_found}; already deleted -> {ack} (a replay or a
--   concurrent delete: the end state is reached; dependants were re-parented by
--   whichever call applied it, so a replay never touches them again); live at a
--   different revision -> {conflict, row}.
--   delete_user_category_safely (build-50 path) is untouched.
--
-- sync_tombstone_goal_contribution(p_expected_epoch, p_id)
--   Contributions are IMMUTABLE append-only children (0031): no revision, no
--   last_op_id, nothing to collide with, so there is no 'conflict' outcome. The
--   delete is idempotent on the row's own state:
--     live contribution -> deleted_at = now(); the parent goal's SERVER-MANAGED
--       saved_amount is reduced by the contribution's amount (the exact inverse of
--       add_goal_contribution 0078, which adds it; floor 0 so a goal whose saved
--       amount was lowered by an edit never goes negative) -> {applied}
--     already deleted   -> {ack}; saved_amount is NOT reduced again
--     absent / not owned -> {not_found} (indistinguishable on purpose)
--   The goal row is locked FOR UPDATE first (as add_goal_contribution does) so a
--   concurrent add and delete serialize. A tombstoned parent goal does not block
--   the delete. Result: {outcome, row: contribution, goal: goal incl.
--   saved_amount_text} (same exact-text key as add_goal_contribution; goal is null
--   for not_found / epoch_mismatch).

BEGIN;

CREATE OR REPLACE FUNCTION public.sync_cas_tombstone_category(
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
  v_uid uuid := auth.uid();
  v_epoch uuid;
  v_row jsonb;
BEGIN
  IF p_op_id IS NULL OR p_id IS NULL OR p_expected_revision IS NULL THEN
    RAISE EXCEPTION 'sync_invalid_request' USING ERRCODE = '22023';
  END IF;

  v_epoch := public.sync_lock_epoch();
  IF p_expected_epoch IS DISTINCT FROM v_epoch THEN
    RETURN jsonb_build_object('outcome', 'epoch_mismatch', 'row', null::jsonb, 'epoch', v_epoch);
  END IF;

  UPDATE public.user_categories AS t
     SET deleted_at = now(), last_op_id = p_op_id
   WHERE t.id = p_id AND t.user_id = v_uid AND t.revision = p_expected_revision
     AND t.deleted_at IS NULL
  RETURNING to_jsonb(t.*) INTO v_row;
  IF v_row IS NOT NULL THEN
    UPDATE public.user_transactions SET user_category_id = NULL, category_id = 'other'
     WHERE user_id = v_uid AND user_category_id = p_id AND deleted_at IS NULL;
    UPDATE public.user_budgets SET user_category_id = NULL, category_id = 'other'
     WHERE user_id = v_uid AND user_category_id = p_id AND deleted_at IS NULL;
    RETURN jsonb_build_object('outcome', 'applied', 'row', v_row);
  END IF;

  SELECT to_jsonb(t.*) INTO v_row FROM public.user_categories t
   WHERE t.id = p_id AND t.user_id = v_uid;
  IF v_row IS NULL THEN
    RETURN jsonb_build_object('outcome', 'not_found', 'row', null::jsonb);
  ELSIF v_row ->> 'deleted_at' IS NOT NULL THEN
    RETURN jsonb_build_object('outcome', 'ack', 'row', v_row);
  END IF;
  RETURN jsonb_build_object('outcome', 'conflict', 'row', v_row);
END;
$$;

CREATE OR REPLACE FUNCTION public.sync_tombstone_goal_contribution(
  p_expected_epoch uuid,
  p_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_epoch uuid;
  c public.user_goal_contributions%rowtype;
  g public.user_goals%rowtype;
BEGIN
  IF p_id IS NULL THEN
    RAISE EXCEPTION 'sync_invalid_request' USING ERRCODE = '22023';
  END IF;

  v_epoch := public.sync_lock_epoch();
  IF p_expected_epoch IS DISTINCT FROM v_epoch THEN
    RETURN jsonb_build_object('outcome', 'epoch_mismatch', 'row', null::jsonb,
                              'goal', null::jsonb, 'epoch', v_epoch);
  END IF;

  SELECT * INTO c FROM public.user_goal_contributions WHERE id = p_id AND user_id = v_uid;
  IF c.id IS NULL THEN
    RETURN jsonb_build_object('outcome', 'not_found', 'row', null::jsonb, 'goal', null::jsonb);
  END IF;

  SELECT * INTO g FROM public.user_goals WHERE id = c.goal_id AND user_id = v_uid FOR UPDATE;
  -- Re-read under the goal lock: a concurrent delete of the same contribution
  -- may have applied while we waited.
  SELECT * INTO c FROM public.user_goal_contributions WHERE id = p_id AND user_id = v_uid;

  IF c.deleted_at IS NOT NULL THEN
    RETURN jsonb_build_object('outcome', 'ack', 'row', to_jsonb(c),
      'goal', to_jsonb(g) || jsonb_build_object('saved_amount_text', g.saved_amount::text));
  END IF;

  UPDATE public.user_goal_contributions SET deleted_at = now()
   WHERE id = p_id AND user_id = v_uid RETURNING * INTO c;
  UPDATE public.user_goals SET saved_amount = greatest(saved_amount - c.amount, 0)
   WHERE id = c.goal_id AND user_id = v_uid RETURNING * INTO g;
  RETURN jsonb_build_object('outcome', 'applied', 'row', to_jsonb(c),
    'goal', to_jsonb(g) || jsonb_build_object('saved_amount_text', g.saved_amount::text));
END;
$$;

REVOKE ALL ON FUNCTION public.sync_cas_tombstone_category(uuid, uuid, uuid, integer) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.sync_tombstone_goal_contribution(uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.sync_cas_tombstone_category(uuid, uuid, uuid, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.sync_tombstone_goal_contribution(uuid, uuid) TO authenticated;

COMMIT;
