-- 0069_sender_mapping_sync_durability.sql
--
-- MALI-072n / MALI-008 — make sender-bank-mapping sync durable + offline-first:
-- stable keyset pagination, tombstone deletion propagation, and a
-- server-authoritative `updated_at` ordering token. All additive + backward
-- compatible; safe while revision-CAS (0068) remains OFF.
--
-- Before this, the client downloaded the ENTIRE mapping set every sync (an
-- unbounded full-snapshot replacement) and had NO way to propagate a deletion —
-- a mapping deleted on one device silently resurrected on every other device.
--
-- Rollback / forward-recovery: dropping `deleted_at` + the trigger + the keyset
-- index restores the pre-0069 shape; existing rows are unaffected (deleted_at
-- defaults NULL = active).

-- Tombstone column (NULL = active row).
ALTER TABLE public.sender_bank_mappings
  ADD COLUMN IF NOT EXISTS deleted_at TIMESTAMPTZ;

-- Stable keyset cursor index: order by (user_id, updated_at, id) so equal
-- timestamps are broken deterministically by id and no row is skipped.
CREATE INDEX IF NOT EXISTS idx_sender_bank_mappings_keyset
  ON public.sender_bank_mappings(user_id, updated_at, id);

-- Server-authoritative `updated_at`: the ordering token must be monotonic
-- ACROSS devices, not tied to each client's clock (a client clock behind the
-- cursor could otherwise write a row the keyset would skip). The BEFORE UPDATE
-- trigger stamps NOW() on every mutation; INSERT keeps the column DEFAULT NOW().
-- `set_updated_at()` is the existing SECURITY INVOKER helper (migration 0014).
DROP TRIGGER IF EXISTS trg_sender_bank_mappings_updated_at
  ON public.sender_bank_mappings;
CREATE TRIGGER trg_sender_bank_mappings_updated_at
  BEFORE UPDATE ON public.sender_bank_mappings
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- RLS: the owner policies from migration 0008 (user_id = auth.uid()) already
-- scope every column, including the new `deleted_at`. No policy change needed —
-- a client can only ever read/tombstone its own mappings.
