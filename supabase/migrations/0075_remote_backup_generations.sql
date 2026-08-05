-- 0075_remote_backup_generations.sql — MALI-076n / MALI-014 (Phase-6 Batch 3).
--
-- Remote-backup object-lifecycle safety: turn the single `backups` pointer row
-- into a self-describing, verifiable, CAS-updatable generation pointer so an
-- interrupted upload can never replace the last valid backup and a download can
-- be integrity-checked before decryption.
--
-- Additive and backward-compatible (new NULLABLE columns only; existing rows and
-- the existing owner RLS "own backup all" are untouched). Safe to apply after
-- 0068–0074 (no dependency on their objects). NOT DEPLOYED in this batch.
--
-- Ownership is already enforced: RLS `own backup all` binds the row to
-- auth.uid(), and the storage-object RLS (0001/0010) binds every object to the
-- user's `<uid>/…` folder — a caller-supplied owner id is never authoritative,
-- and a leaked object path alone grants no access. This migration adds NO PII:
-- no passphrase, key, nonce, plaintext, or financial content.

ALTER TABLE public.backups
  -- The committed generation id the pointer references (the current backup). The
  -- client commits a new generation with a compare-and-set on this value.
  ADD COLUMN IF NOT EXISTS generation_id    TEXT,
  -- SHA-256 of the ENCRYPTED blob — a transport/integrity check verified on
  -- download BEFORE decryption. It never replaces the v3 AEAD authentication.
  ADD COLUMN IF NOT EXISTS blob_sha256      TEXT,
  -- The durable client operation id that produced this generation (idempotency;
  -- a lost-response retry with the same id/generation is a no-op).
  ADD COLUMN IF NOT EXISTS operation_id     TEXT,
  -- Pointer status; 'committed' = a verified, restorable backup.
  ADD COLUMN IF NOT EXISTS status           TEXT NOT NULL DEFAULT 'committed',
  ADD COLUMN IF NOT EXISTS committed_at     TIMESTAMPTZ;

-- A hostile/oversized declared size must be rejected client-side before download
-- (the v3 parser + publisher enforce this); the column stays advisory.
COMMENT ON COLUMN public.backups.blob_sha256 IS
  'Integrity hash of the ENCRYPTED blob; transport check only, not AEAD auth.';
COMMENT ON COLUMN public.backups.generation_id IS
  'Committed generation id; client commits with compare-and-set on this value.';
