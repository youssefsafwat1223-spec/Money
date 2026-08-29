-- ===========================================================================
-- 0086 -- backups Storage write barrier for deleted Auth users (H-24 residual)
-- ===========================================================================
-- SOURCE-ONLY. NOT APPLIED TO ANY PROJECT. Production `vrombzdgwqjjiijbidqb`
-- and evidence staging `dpdukyozedajelflkeix` have had ZERO contact.
--
-- A Supabase access token remains cryptographically valid until its expiry even
-- after its auth.users row is deleted. The original backups policies checked
-- only auth.uid() against the first object-path segment, so that stale token
-- could create a new `<uid>/...` object after the deletion worker's terminal
-- sweep and dequeue. The queue row was then gone, leaving no future purge
-- handle for the orphan.
--
-- This forward migration makes Auth-row liveness part of Storage's INSERT and
-- UPDATE authorization. The helper is SECURITY DEFINER because authenticated
-- cannot read auth.users directly. Its search_path contains only pg_catalog and
-- every referenced non-catalog object is schema-qualified.
--
-- FOR KEY SHARE also closes the in-flight boundary: an upload that observes the
-- live Auth row holds a row lock until its Storage transaction ends, so Auth
-- deletion cannot commit/return ahead of that write. Once deletion has returned,
-- later checks find no row and fail even when the caller presents an otherwise
-- unexpired JWT. The deletion saga's post-Auth sweep can therefore be terminal.
-- ===========================================================================

create or replace function public.backups_owner_is_live()
returns boolean
language sql
volatile
security definer
set search_path = pg_catalog
as $$
  select exists (
    select 1
      from auth.users as u
     where u.id = (select auth.uid())
     for key share
  );
$$;

-- Functions are executable by PUBLIC by default. Remove every client grant
-- before granting only the role whose Storage write policies call the helper.
revoke all on function public.backups_owner_is_live() from public;
revoke all on function public.backups_owner_is_live() from anon;
revoke all on function public.backups_owner_is_live() from authenticated;
grant execute on function public.backups_owner_is_live() to authenticated;

-- Preserve the original bucket + first-path-segment ownership checks and add
-- liveness to every write check. SELECT and DELETE policies are untouched.
drop policy if exists "own backup objects write" on storage.objects;
create policy "own backup objects write" on storage.objects for insert
  to authenticated
  with check (
    bucket_id = 'backups'
    and (storage.foldername(name))[1] = auth.uid()::text
    and public.backups_owner_is_live()
  );

drop policy if exists "own backup objects update" on storage.objects;
create policy "own backup objects update" on storage.objects for update
  to authenticated
  using (
    bucket_id = 'backups'
    and (storage.foldername(name))[1] = auth.uid()::text
    and public.backups_owner_is_live()
  )
  with check (
    bucket_id = 'backups'
    and (storage.foldername(name))[1] = auth.uid()::text
    and public.backups_owner_is_live()
  );
