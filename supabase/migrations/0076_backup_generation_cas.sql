-- 0076_backup_generation_cas.sql — MALI-076n / MALI-014 (Phase-6 Batch-3 closure).
--
-- Server-ATOMIC backup-generation commit. The client-side expected-generation
-- check (0075 + the adapter) is not authoritative under two-device concurrency;
-- this RPC performs the pointer publication atomically in ONE PostgreSQL
-- transaction, deriving the owner from verified auth, locking the pointer row,
-- rejecting a stale expected generation, and recording the operation for
-- idempotent replay.
--
-- Additive + backward-compatible; NOT DEPLOYED. Safe after 0068–0075.
--
-- This is a BACKUP-SPECIFIC generation CAS. It does NOT touch the general
-- entity revision-CAS capability (`kServerRevisionCas` stays false).
--
-- Object hash: Supabase Storage does not expose a trusted server-side checksum
-- without reading the object bytes, so the encrypted-blob SHA-256 stays CLIENT +
-- download-time verified (plus the v3 AEAD authentication). The server DOES
-- authenticate object existence, owner-scoped path, and byte SIZE from
-- storage.objects — pointer publication itself is fully server-atomic.

ALTER TABLE public.backups
  ADD COLUMN IF NOT EXISTS previous_generation_id TEXT,
  ADD COLUMN IF NOT EXISTS previous_object_path   TEXT;

CREATE OR REPLACE FUNCTION public.commit_backup_generation(
  p_generation_id               TEXT,
  p_object_path                 TEXT,
  p_blob_version                INTEGER,
  p_size_bytes                  BIGINT,
  p_blob_sha256                 TEXT,
  p_operation_id                TEXT,
  p_expected_prev_generation_id TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_owner    UUID := auth.uid();
  v_existing public.backups%ROWTYPE;
  v_found    BOOLEAN := FALSE;
  v_size     BIGINT;
BEGIN
  -- 1. Owner derived from verified auth; never caller-supplied.
  IF v_owner IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'authentication_required');
  END IF;
  -- 2. The object path must live under the caller's own <uid>/ folder (matches
  --    the storage-object RLS); a caller can never commit another user's object.
  IF split_part(p_object_path, '/', 1) <> v_owner::text THEN
    RETURN jsonb_build_object('ok', false, 'error', 'ownership_mismatch');
  END IF;
  -- 3. Server-authoritative object existence + size (owner-scoped storage row).
  SELECT (o.metadata->>'size')::bigint INTO v_size
    FROM storage.objects o
    WHERE o.bucket_id = 'backups' AND o.name = p_object_path;
  IF v_size IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'remote_object_missing');
  END IF;
  IF v_size <> p_size_bytes THEN
    RETURN jsonb_build_object('ok', false, 'error', 'upload_verification_failed');
  END IF;

  -- 4. Lock the current pointer row for this owner (serialise concurrent commits).
  SELECT * INTO v_existing FROM backups WHERE user_id = v_owner FOR UPDATE;
  v_found := FOUND;

  -- 5. Idempotent replay of the WINNING operation (a lost response).
  IF v_found AND v_existing.generation_id = p_generation_id THEN
    IF v_existing.operation_id = p_operation_id THEN
      RETURN jsonb_build_object('ok', true, 'replay', true,
                                'generation_id', v_existing.generation_id);
    END IF;
    -- Same generation id from a DIFFERENT operation → conflict.
    RETURN jsonb_build_object('ok', false, 'error', 'operation_conflict');
  END IF;
  -- Same operation id but a different generation/hash → reject.
  IF v_found AND v_existing.operation_id = p_operation_id
     AND v_existing.generation_id IS DISTINCT FROM p_generation_id THEN
    RETURN jsonb_build_object('ok', false, 'error', 'operation_conflict');
  END IF;

  -- 6. Compare-and-set: the current committed generation must equal the caller's
  --    expected previous. Two devices from the same previous → one winner, the
  --    other a typed stale_generation.
  IF COALESCE(v_existing.generation_id, '')
       IS DISTINCT FROM COALESCE(p_expected_prev_generation_id, '') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'stale_generation');
  END IF;

  -- 7-9. Commit the metadata + move the pointer in this one transaction, keeping
  --      the just-superseded generation as the retained previous known-good.
  INSERT INTO backups (
    user_id, blob_path, blob_version, size_bytes, blob_sha256,
    generation_id, operation_id, status, committed_at, updated_at,
    previous_generation_id, previous_object_path
  ) VALUES (
    v_owner, p_object_path, p_blob_version, p_size_bytes, p_blob_sha256,
    p_generation_id, p_operation_id, 'committed', now(), now(),
    v_existing.generation_id, v_existing.blob_path
  )
  ON CONFLICT (user_id) DO UPDATE SET
    blob_path              = EXCLUDED.blob_path,
    blob_version           = EXCLUDED.blob_version,
    size_bytes             = EXCLUDED.size_bytes,
    blob_sha256            = EXCLUDED.blob_sha256,
    generation_id          = EXCLUDED.generation_id,
    operation_id           = EXCLUDED.operation_id,
    status                 = 'committed',
    committed_at           = now(),
    updated_at             = now(),
    previous_generation_id = backups.generation_id,
    previous_object_path   = backups.blob_path;

  RETURN jsonb_build_object('ok', true, 'generation_id', p_generation_id,
                            'previous_generation_id', v_existing.generation_id);
END;
$$;

REVOKE ALL ON FUNCTION public.commit_backup_generation(TEXT, TEXT, INTEGER, BIGINT, TEXT, TEXT, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.commit_backup_generation(TEXT, TEXT, INTEGER, BIGINT, TEXT, TEXT, TEXT) TO authenticated;
