-- Ensure encrypted backup storage exists.
insert into storage.buckets (id, name, public)
values ('backups', 'backups', false)
on conflict (id) do nothing;

drop policy if exists "own backup objects read" on storage.objects;
drop policy if exists "own backup objects write" on storage.objects;
drop policy if exists "own backup objects update" on storage.objects;
drop policy if exists "own backup objects delete" on storage.objects;

create policy "own backup objects read" on storage.objects for select
  using (
    bucket_id = 'backups'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

create policy "own backup objects write" on storage.objects for insert
  with check (
    bucket_id = 'backups'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

create policy "own backup objects update" on storage.objects for update
  using (
    bucket_id = 'backups'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

create policy "own backup objects delete" on storage.objects for delete
  using (
    bucket_id = 'backups'
    and (storage.foldername(name))[1] = auth.uid()::text
  );
