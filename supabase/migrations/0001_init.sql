-- USERS PROFILE (identity only — NO financial data)
create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  email text,
  auth_method text,
  country text default 'SA',
  created_at timestamptz default now(),
  delete_scheduled_at timestamptz
);
alter table public.profiles enable row level security;
create policy "own profile read"   on public.profiles for select using (auth.uid() = id);
create policy "own profile insert" on public.profiles for insert with check (auth.uid() = id);
create policy "own profile update" on public.profiles for update using (auth.uid() = id);

-- ENCRYPTED BACKUP METADATA (the blob lives in Storage; here only metadata, NO readable data)
create table public.backups (
  user_id uuid primary key references auth.users(id) on delete cascade,
  blob_path text not null,
  blob_version int not null default 1,
  size_bytes int,
  updated_at timestamptz default now()
);
alter table public.backups enable row level security;
create policy "own backup all" on public.backups
  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);

-- ANONYMOUS METRICS (no PII, no amounts/merchants; insert-only by authenticated users)
create table public.metrics (
  id bigint generated always as identity primary key,
  metric_key text not null,
  dimension text,
  day date not null default current_date,
  created_at timestamptz default now()
);
alter table public.metrics enable row level security;
create policy "metrics insert" on public.metrics for insert to authenticated with check (true);
-- no select policy -> clients cannot read metrics back (admin reads via service role only).

-- REMOTE PARSING RULES (read-only public config)
create table public.bank_rules (
  id bigint generated always as identity primary key,
  bank_key text not null,
  locale text not null default 'ar-SA',
  rules_json jsonb not null,
  version int not null default 1,
  is_active boolean not null default true,
  published_at timestamptz default now()
);
alter table public.bank_rules enable row level security;
create policy "rules read" on public.bank_rules for select using (is_active = true);

-- STORAGE RLS for bucket `backups`: each user may only access objects under their own uid folder.
-- (Bucket created manually in dashboard; these policies go on storage.objects.)
create policy "own backup objects read"   on storage.objects for select
  using (bucket_id = 'backups' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "own backup objects write"  on storage.objects for insert
  with check (bucket_id = 'backups' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "own backup objects update" on storage.objects for update
  using (bucket_id = 'backups' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "own backup objects delete" on storage.objects for delete
  using (bucket_id = 'backups' and (storage.foldername(name))[1] = auth.uid()::text);

-- Auto-create a profile row on signup
create function public.handle_new_user() returns trigger language plpgsql security definer as $$
begin
  insert into public.profiles (id, email) values (new.id, new.email)
  on conflict (id) do nothing;
  return new;
end; $$;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();
