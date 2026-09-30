-- WP5-Lite — feature-flag admin control plane: audited, optimistic, atomic writes.
--
-- THE DEFECT
-- The Admin flags page wrote `feature_flags` through the generic
-- `PATCH /api/admin-data` route: no validation (rollout 150, a boolean flag set
-- to "banana"), no audit, no stale-write detection, and `updated_at` was never
-- bumped because the table has no trigger.
--
-- THE FIX
--   1. `feature_flag_admin_audit` — append-only, one row per changed FIELD.
--   2. an updated_at trigger on feature_flags (reuses set_updated_at()). The "last
--      actor" is derived from the audit table; feature_flags gets NO actor column
--      because it has an anon SELECT policy (0003) and would expose admin uuids.
--   3. `admin_apply_feature_flag_changes()` — the ONLY sanctioned write path:
--      SECURITY DEFINER, service-role only, one transaction, row locks,
--      optimistic `expected_updated_at`, per-field validation, idempotent on
--      `operation_id`.
--
-- WHAT THE RPC KNOWS vs WHAT THE API KNOWS
-- The flag registry (admin/lib/flag-registry.ts) is the source of truth for which
-- keys are server-read / not wired / high risk. The API passes `server_read` per
-- change; this function enforces the consequence (server-read flags support only
-- all-or-nothing rollout, mirroring resolveUserBooleanFlag which FAILS CLOSED on
-- rollout < 100 or non-empty target_countries). The one piece of schema
-- knowledge that belongs here is the ai_sender_mapping_auto dependency on
-- sender_bank_mappings.accepted_by (migration 0101).
--
-- AUTHORIZATION SEAM
-- Every change passes through admin_can_change_flag(actor, key). It returns true
-- for any non-null actor today (membership of admin_users is enforced by the
-- Next.js route before the RPC is reached). A future per-role / per-key policy
-- replaces ONE function body; the flag model and the RPC do not change.
--
-- ACTIVATION CONDITION: deploy together with the Admin release that ships
-- /api/feature-flags. Ordering: AFTER 0101 (0100, 0101 are also deferred at the
-- tail). If 0100/0101 stay deferred, renumber this file (and its rollback) to the
-- next free active number before moving it.

BEGIN;

-- ─── 1. feature_flags: updated_at trigger ───────────────────────
DROP TRIGGER IF EXISTS trg_feature_flags_updated_at ON public.feature_flags;
CREATE TRIGGER trg_feature_flags_updated_at
  BEFORE UPDATE ON public.feature_flags
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- ─── 2. Append-only audit (one row per changed field) ────────────────────────
-- No FK to auth.users on purpose: ON DELETE SET NULL would UPDATE audit rows,
-- which the append-only trigger below forbids, and attribution must survive the
-- deletion of the admin account.
CREATE TABLE IF NOT EXISTS public.feature_flag_admin_audit (
  id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  operation_id   UUID NOT NULL,
  actor_admin_id UUID NULL,
  flag_key       TEXT NOT NULL,
  field          TEXT NOT NULL
    CHECK (field IN ('_created','is_active','value','rollout_percent','target_countries','description')),
  old_value      JSONB NULL,
  new_value      JSONB NULL,
  reason         TEXT NOT NULL,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT feature_flag_audit_reason_shape
    CHECK (char_length(reason) BETWEEN 4 AND 500
           AND reason !~ '[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]'),
  CONSTRAINT feature_flag_audit_once_per_op UNIQUE (operation_id, flag_key, field)
);

CREATE INDEX IF NOT EXISTS idx_feature_flag_audit_key
  ON public.feature_flag_admin_audit(flag_key, created_at DESC);

ALTER TABLE public.feature_flag_admin_audit ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.feature_flag_admin_audit FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.feature_flag_audit_append_only()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'feature_flag_admin_audit is append-only' USING ERRCODE = 'P0403';
END;
$$;

DROP TRIGGER IF EXISTS trg_feature_flag_audit_no_mutation ON public.feature_flag_admin_audit;
CREATE TRIGGER trg_feature_flag_audit_no_mutation
  BEFORE UPDATE OR DELETE ON public.feature_flag_admin_audit
  FOR EACH ROW EXECUTE FUNCTION public.feature_flag_audit_append_only();

DROP TRIGGER IF EXISTS trg_feature_flag_audit_no_truncate ON public.feature_flag_admin_audit;
CREATE TRIGGER trg_feature_flag_audit_no_truncate
  BEFORE TRUNCATE ON public.feature_flag_admin_audit
  FOR EACH STATEMENT EXECUTE FUNCTION public.feature_flag_audit_append_only();

-- ─── 3. The single authorization seam ────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.admin_can_change_flag(p_actor UUID, p_key TEXT)
RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT p_actor IS NOT NULL;
$$;

REVOKE ALL ON FUNCTION public.admin_can_change_flag(UUID, TEXT) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.admin_can_change_flag(UUID, TEXT) TO service_role;

-- ─── 4. The apply RPC ────────────────────────────────────────────────────────
-- p_changes: jsonb array of
--   { "key": text,
--     "create": bool            -- create an INACTIVE row (never implicit)
--     "value_type": text        -- create only
--     "expected_updated_at": text|null  -- required unless create
--     "server_read": bool       -- API marks keys read by resolveUserBooleanFlag
--     "set": { is_active, value, rollout_percent, target_countries, description } }
-- Errors (SQLSTATE -> meaning): P0422 validation/semantic/dependency,
-- P0409 stale or already-exists, P0404 missing row, P0403 not authorized.
CREATE OR REPLACE FUNCTION public.admin_apply_feature_flag_changes(
  p_actor        UUID,
  p_reason       TEXT,
  p_operation_id UUID,
  p_changes      JSONB
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  c          JSONB;
  v_key      TEXT;
  v_row      public.feature_flags%ROWTYPE;
  v_new      public.feature_flags%ROWTYPE;
  v_set      JSONB;
  v_create   BOOLEAN;
  v_server   BOOLEAN;
  v_found    BOOLEAN;
  f          TEXT;
  v_old_j    JSONB;
  v_new_j    JSONB;
  v_changed  BOOLEAN;
  v_total    INT := 0;
  v_elem     JSONB;
  v_cc       TEXT;
  v_expected TIMESTAMPTZ;
BEGIN
  IF p_actor IS NULL THEN
    RAISE EXCEPTION 'actor_required' USING ERRCODE = 'P0422';
  END IF;
  IF p_operation_id IS NULL THEN
    RAISE EXCEPTION 'operation_id_required' USING ERRCODE = 'P0422';
  END IF;
  IF p_reason IS NULL OR char_length(p_reason) NOT BETWEEN 4 AND 500
     OR p_reason ~ '[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]' THEN
    RAISE EXCEPTION 'reason_invalid' USING ERRCODE = 'P0422';
  END IF;
  IF p_changes IS NULL OR jsonb_typeof(p_changes) <> 'array'
     OR jsonb_array_length(p_changes) NOT BETWEEN 1 AND 50 THEN
    RAISE EXCEPTION 'changes_invalid' USING ERRCODE = 'P0422';
  END IF;

  -- Serialize concurrent calls carrying the same operation id, then replay.
  PERFORM pg_advisory_xact_lock(hashtextextended('ffa:' || p_operation_id::text, 0));
  IF EXISTS (SELECT 1 FROM public.feature_flag_admin_audit WHERE operation_id = p_operation_id) THEN
    RETURN jsonb_build_object(
      'replayed', true,
      'operation_id', p_operation_id,
      'audit', (SELECT COALESCE(jsonb_agg(jsonb_build_object(
                  'flag_key', a.flag_key, 'field', a.field,
                  'old_value', a.old_value, 'new_value', a.new_value,
                  'created_at', a.created_at) ORDER BY a.flag_key, a.field), '[]'::jsonb)
                FROM public.feature_flag_admin_audit a
                WHERE a.operation_id = p_operation_id));
  END IF;

  IF (SELECT count(DISTINCT e->>'key') FROM jsonb_array_elements(p_changes) e)
     <> jsonb_array_length(p_changes) THEN
    RAISE EXCEPTION 'duplicate_key_in_changes' USING ERRCODE = 'P0422';
  END IF;

  -- Deterministic lock order (by key) so two multi-flag operations cannot deadlock.
  FOR c IN SELECT e FROM jsonb_array_elements(p_changes) e ORDER BY e->>'key' LOOP
    IF jsonb_typeof(c) <> 'object' THEN
      RAISE EXCEPTION 'change_invalid' USING ERRCODE = 'P0422';
    END IF;
    v_key := c->>'key';
    IF v_key IS NULL OR v_key !~ '^[a-z][a-z0-9_]{1,63}$' THEN
      RAISE EXCEPTION 'key_invalid' USING ERRCODE = 'P0422';
    END IF;
    IF NOT public.admin_can_change_flag(p_actor, v_key) THEN
      RAISE EXCEPTION 'not_authorized: %', v_key USING ERRCODE = 'P0403';
    END IF;

    v_create := c->'create' = 'true'::jsonb;
    v_server := c->'server_read' = 'true'::jsonb;
    v_set := COALESCE(c->'set', '{}'::jsonb);
    IF jsonb_typeof(v_set) <> 'object' THEN
      RAISE EXCEPTION 'set_invalid: %', v_key USING ERRCODE = 'P0422';
    END IF;
    IF EXISTS (SELECT 1 FROM jsonb_object_keys(v_set) k
               WHERE k NOT IN ('is_active','value','rollout_percent','target_countries','description')) THEN
      RAISE EXCEPTION 'unknown_field: %', v_key USING ERRCODE = 'P0422';
    END IF;

    SELECT * INTO v_row FROM public.feature_flags WHERE key = v_key FOR UPDATE;
    v_found := FOUND;

    IF v_create THEN
      IF v_found THEN
        RAISE EXCEPTION 'flag_exists: %', v_key USING ERRCODE = 'P0409';
      END IF;
      v_new := ROW(gen_random_uuid(), v_key, c->>'value_type', NULL, NULL, 0, '[]'::jsonb, false, now());
      IF v_new.value_type IS NULL OR v_new.value_type NOT IN ('boolean','string','number','json') THEN
        RAISE EXCEPTION 'value_type_invalid: %', v_key USING ERRCODE = 'P0422';
      END IF;
      v_new.value := CASE WHEN v_new.value_type = 'boolean' THEN 'false' ELSE NULL END;
      v_row := NULL;  -- nothing to diff against
    ELSE
      IF NOT v_found THEN
        RAISE EXCEPTION 'flag_not_found: %', v_key USING ERRCODE = 'P0404';
      END IF;
      IF c->>'expected_updated_at' IS NULL THEN
        RAISE EXCEPTION 'expected_updated_at_required: %', v_key USING ERRCODE = 'P0422';
      END IF;
      BEGIN
        v_expected := (c->>'expected_updated_at')::timestamptz;
      EXCEPTION WHEN others THEN
        RAISE EXCEPTION 'expected_updated_at_invalid: %', v_key USING ERRCODE = 'P0422';
      END;
      IF v_row.updated_at IS DISTINCT FROM v_expected THEN
        RAISE EXCEPTION 'stale_flag: %', v_key USING ERRCODE = 'P0409';
      END IF;
      v_new := v_row;
    END IF;

    -- ── per-field validation + application ──
    IF v_set ? 'is_active' THEN
      IF jsonb_typeof(v_set->'is_active') <> 'boolean' THEN
        RAISE EXCEPTION 'is_active_invalid: %', v_key USING ERRCODE = 'P0422';
      END IF;
      v_new.is_active := (v_set->>'is_active')::boolean;
    END IF;
    IF v_set ? 'value' THEN
      IF jsonb_typeof(v_set->'value') <> 'string' THEN
        RAISE EXCEPTION 'value_invalid: %', v_key USING ERRCODE = 'P0422';
      END IF;
      v_new.value := v_set->>'value';
    END IF;
    IF v_set ? 'rollout_percent' THEN
      IF jsonb_typeof(v_set->'rollout_percent') <> 'number'
         OR (v_set->>'rollout_percent')::numeric <> trunc((v_set->>'rollout_percent')::numeric)
         OR (v_set->>'rollout_percent')::numeric NOT BETWEEN 0 AND 100 THEN
        RAISE EXCEPTION 'rollout_percent_invalid: %', v_key USING ERRCODE = 'P0422';
      END IF;
      v_new.rollout_percent := (v_set->>'rollout_percent')::numeric::int;
    END IF;
    IF v_set ? 'target_countries' THEN
      IF jsonb_typeof(v_set->'target_countries') <> 'array'
         OR jsonb_array_length(v_set->'target_countries') > 250 THEN
        RAISE EXCEPTION 'target_countries_invalid: %', v_key USING ERRCODE = 'P0422';
      END IF;
      FOR v_elem IN SELECT e FROM jsonb_array_elements(v_set->'target_countries') e LOOP
        IF jsonb_typeof(v_elem) <> 'string' OR (v_elem #>> '{}') !~ '^[A-Z]{2}$' THEN
          RAISE EXCEPTION 'target_country_invalid: %', v_key USING ERRCODE = 'P0422';
        END IF;
      END LOOP;
      IF (SELECT count(DISTINCT e) FROM jsonb_array_elements(v_set->'target_countries') e)
         <> jsonb_array_length(v_set->'target_countries') THEN
        RAISE EXCEPTION 'target_countries_duplicate: %', v_key USING ERRCODE = 'P0422';
      END IF;
      v_new.target_countries := v_set->'target_countries';
    END IF;
    IF v_set ? 'description' THEN
      IF jsonb_typeof(v_set->'description') NOT IN ('string','null')
         OR char_length(COALESCE(v_set->>'description','')) > 500 THEN
        RAISE EXCEPTION 'description_invalid: %', v_key USING ERRCODE = 'P0422';
      END IF;
      v_new.description := v_set->>'description';
    END IF;

    IF v_create AND v_new.is_active THEN
      RAISE EXCEPTION 'create_must_be_inactive: %', v_key USING ERRCODE = 'P0422';
    END IF;
    IF v_create AND (v_set ? 'rollout_percent' OR v_set ? 'target_countries') THEN
      RAISE EXCEPTION 'create_takes_defaults_only: %', v_key USING ERRCODE = 'P0422';
    END IF;

    -- value vs value_type (always evaluated on the resulting row)
    IF v_new.value IS NULL THEN
      RAISE EXCEPTION 'value_required: %', v_key USING ERRCODE = 'P0422';
    END IF;
    IF v_new.value_type = 'boolean' AND v_new.value NOT IN ('true','false') THEN
      RAISE EXCEPTION 'value_type_mismatch: % (boolean)', v_key USING ERRCODE = 'P0422';
    ELSIF v_new.value_type = 'number' AND v_new.value !~ '^-?[0-9]+(\.[0-9]+)?$' THEN
      RAISE EXCEPTION 'value_type_mismatch: % (number)', v_key USING ERRCODE = 'P0422';
    ELSIF v_new.value_type = 'json' THEN
      BEGIN
        PERFORM v_new.value::jsonb;
      EXCEPTION WHEN others THEN
        RAISE EXCEPTION 'value_type_mismatch: % (json)', v_key USING ERRCODE = 'P0422';
      END;
    ELSIF v_new.value_type = 'string' AND char_length(v_new.value) > 1000 THEN
      RAISE EXCEPTION 'value_too_long: %', v_key USING ERRCODE = 'P0422';
    END IF;

    -- Server-read flags: all-or-nothing only (resolveUserBooleanFlag fails closed).
    IF v_server THEN
      IF (v_set ? 'rollout_percent' AND v_new.rollout_percent BETWEEN 1 AND 99)
         OR (v_set ? 'target_countries' AND jsonb_array_length(v_new.target_countries) > 0) THEN
        RAISE EXCEPTION 'server_read_partial_rollout_unsupported: %', v_key USING ERRCODE = 'P0422';
      END IF;
      IF v_new.is_active AND (v_new.rollout_percent < 100
                              OR jsonb_array_length(v_new.target_countries) > 0) THEN
        RAISE EXCEPTION 'server_read_requires_full_rollout: %', v_key USING ERRCODE = 'P0422';
      END IF;
    END IF;

    -- enable_proof_autocommit is HARD-BLOCKED from being armed: the proof engine
    -- is not fed (proofResult stays null), so arming withholds / drops local
    -- captures. Turning it off or editing its description stays allowed. Lift
    -- this only when the proof engine is wired.
    IF v_key = 'enable_proof_autocommit' AND v_new.is_active
       AND lower(v_new.value) = 'true' AND v_new.rollout_percent > 0
       AND (v_set ? 'is_active' OR v_set ? 'value' OR v_set ? 'rollout_percent') THEN
      RAISE EXCEPTION 'unsafe_to_arm: %', v_key USING ERRCODE = 'P0422';
    END IF;

    -- Dependency: ai_sender_mapping_auto needs migration 0101's column.
    IF v_key = 'ai_sender_mapping_auto' AND v_new.is_active
       AND lower(v_new.value) = 'true'
       AND NOT EXISTS (
         SELECT 1 FROM pg_attribute
         WHERE attrelid = to_regclass('public.sender_bank_mappings')
           AND attname = 'accepted_by' AND attnum > 0 AND NOT attisdropped) THEN
      RAISE EXCEPTION 'dependency_missing: sender_bank_mappings.accepted_by (migration 0101)'
        USING ERRCODE = 'P0422';
    END IF;

    -- ── write + audit ──
    IF v_create THEN
      INSERT INTO public.feature_flags
        (id, key, value_type, value, description, rollout_percent, target_countries, is_active, updated_at)
      VALUES (v_new.id, v_new.key, v_new.value_type, v_new.value, v_new.description,
              v_new.rollout_percent, v_new.target_countries, v_new.is_active, now());
      INSERT INTO public.feature_flag_admin_audit
        (operation_id, actor_admin_id, flag_key, field, old_value, new_value, reason)
      VALUES (p_operation_id, p_actor, v_key, '_created', NULL,
              jsonb_build_object('value_type', v_new.value_type, 'value', v_new.value,
                                 'description', v_new.description, 'is_active', false,
                                 'rollout_percent', 0, 'target_countries', '[]'::jsonb),
              p_reason);
      v_total := v_total + 1;
    ELSE
      v_changed := false;
      FOREACH f IN ARRAY ARRAY['is_active','value','rollout_percent','target_countries','description'] LOOP
        IF v_set ? f THEN
          v_old_j := to_jsonb(v_row) -> f;
          v_new_j := to_jsonb(v_new) -> f;
          IF v_old_j IS DISTINCT FROM v_new_j THEN
            INSERT INTO public.feature_flag_admin_audit
              (operation_id, actor_admin_id, flag_key, field, old_value, new_value, reason)
            VALUES (p_operation_id, p_actor, v_key, f, v_old_j, v_new_j, p_reason);
            v_changed := true;
            v_total := v_total + 1;
          END IF;
        END IF;
      END LOOP;
      IF v_changed THEN
        UPDATE public.feature_flags
           SET is_active = v_new.is_active, value = v_new.value,
               rollout_percent = v_new.rollout_percent,
               target_countries = v_new.target_countries,
               description = v_new.description
         WHERE id = v_row.id;
      END IF;
    END IF;
  END LOOP;

  IF v_total = 0 THEN
    RAISE EXCEPTION 'no_effective_changes' USING ERRCODE = 'P0422';
  END IF;

  RETURN jsonb_build_object(
    'replayed', false,
    'operation_id', p_operation_id,
    'audit', (SELECT COALESCE(jsonb_agg(jsonb_build_object(
                'flag_key', a.flag_key, 'field', a.field,
                'old_value', a.old_value, 'new_value', a.new_value,
                'created_at', a.created_at) ORDER BY a.flag_key, a.field), '[]'::jsonb)
              FROM public.feature_flag_admin_audit a
              WHERE a.operation_id = p_operation_id));
END;
$$;

REVOKE ALL ON FUNCTION public.admin_apply_feature_flag_changes(UUID, TEXT, UUID, JSONB)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.admin_apply_feature_flag_changes(UUID, TEXT, UUID, JSONB)
  TO service_role;

COMMIT;
