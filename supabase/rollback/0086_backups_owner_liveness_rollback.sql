-- ROLLBACK for 0086_backups_owner_liveness.sql (H-24 residual)
--
-- 0086 added a liveness predicate to the backups-bucket WRITE policies so a
-- deleted Auth user cannot keep writing backup objects, and introduced
-- `public.backups_owner_is_live()` to express it.
--
-- This restores the 0010_backups_bucket.sql form of the two write policies
-- VERBATIM, then drops the function. Order matters: the policies must stop
-- referencing the function before it can be dropped.
--
-- WHAT YOU LOSE: an Auth user deleted while holding a valid JWT can write to
-- their old backup prefix until that token expires. That is the H-24 residual.
--
-- SELECT and DELETE policies were untouched by 0086 and are untouched here.

begin;

-- 1. Restore the pre-0086 write policies (from 0010_backups_bucket.sql).
drop policy if exists "own backup objects write" on storage.objects;
create policy "own backup objects write" on storage.objects for insert
  with check (
    bucket_id = 'backups'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

drop policy if exists "own backup objects update" on storage.objects;
create policy "own backup objects update" on storage.objects for update
  using (
    bucket_id = 'backups'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

-- 2. Now nothing references it, so the function can go.
drop function if exists public.backups_owner_is_live();

commit;
