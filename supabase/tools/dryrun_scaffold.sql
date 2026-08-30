-- ===========================================================================
-- LOCAL DRY-RUN SCAFFOLD — never applied to any hosted project
-- ===========================================================================
-- Purpose: stand up the Supabase-managed primitives that `supabase/migrations/`
-- assumes already exist, so the migration chain can be APPLIED and its ordering,
-- dependencies and syntax verified on a throwaway local Postgres.
--
-- This file is NOT a migration and must never be applied anywhere hosted. It is
-- a test fixture: on a real project every object below is created and owned by
-- the Supabase platform, and re-declaring them would be wrong.
--
-- Fidelity, and its limits — stated so results are not over-read:
--
--   * `auth.users` / `auth.identities` carry only the columns the migrations
--     reference. Platform triggers and constraints are absent.
--   * `auth.uid()` returns a session GUC so RLS policies COMPILE. They are not
--     exercised — a policy that compiles here can still be wrong in behaviour.
--   * `pg_cron` and `pg_net` are stubbed as no-op functions. Scheduling and
--     outbound HTTP therefore parse but do nothing; nothing here proves a cron
--     job runs or a webhook fires.
--   * `vault` is a plain table. Real Vault encrypts at rest.
--
-- What a green run DOES prove: every statement parses, every object exists
-- before it is referenced, the numeric order is a valid apply order, and
-- 0084-0091 apply cleanly on top of 0001-0083.
-- ===========================================================================

create schema if not exists auth;
create schema if not exists storage;
create schema if not exists extensions;
create schema if not exists vault;
create schema if not exists graphql_public;

create extension if not exists pgcrypto with schema extensions;

-- Supabase's three client roles. NOLOGIN: nothing connects as them here.
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then
    create role anon nologin noinherit;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    create role authenticated nologin noinherit;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'service_role') then
    create role service_role nologin noinherit bypassrls;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'supabase_admin') then
    create role supabase_admin nologin noinherit;
  end if;
end $$;

grant usage on schema public, auth, storage, extensions to anon, authenticated, service_role;

-- Hosted Supabase ships DEFAULT PRIVILEGES on `public` that grant the full
-- table privilege set to `anon` and `authenticated` on every newly created
-- table. Every migration that enables RLS neutralises them; a migration that
-- forgets to leaves the table reachable over PostgREST by anyone.
--
-- Without this line the container cannot express that failure mode at all, so
-- the harness reported a clean apply for `0087`, whose journal table shipped
-- RLS-disabled and anon-writable to production. That was found live, after the
-- fact, and fixed by `0092`. Reproducing the defaults here is what makes the
-- dry-run capable of catching the next one.
--
-- `service_role` is included because the hosted defaults grant it too. Omitting
-- it makes the container claim a REVOKE stripped service_role access when the
-- role simply never had any, which reads as a false regression -- note that
-- BYPASSRLS lets a role skip RLS policies but confers no table privilege of its
-- own, so a missing grant here is indistinguishable from a revoked one.
alter default privileges in schema public grant all on tables to anon, authenticated, service_role;
grant all on all tables in schema public to anon, authenticated, service_role;

-- ─── auth ──────────────────────────────────────────────────────────────────
create table if not exists auth.users (
  id                  uuid primary key default gen_random_uuid(),
  email               text,
  phone               text,
  raw_user_meta_data  jsonb default '{}'::jsonb,
  raw_app_meta_data   jsonb default '{}'::jsonb,
  created_at          timestamptz default now(),
  updated_at          timestamptz default now(),
  deleted_at          timestamptz,
  last_sign_in_at     timestamptz,
  banned_until        timestamptz,
  is_anonymous        boolean default false
);

create table if not exists auth.identities (
  id              uuid primary key default gen_random_uuid(),
  user_id         uuid references auth.users(id) on delete cascade,
  provider        text,
  provider_id     text,
  identity_data   jsonb default '{}'::jsonb,
  created_at      timestamptz default now(),
  updated_at      timestamptz default now()
);

-- The current user id, read from a session GUC so tests can impersonate.
create or replace function auth.uid() returns uuid language sql stable as $$
  select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid
$$;

create or replace function auth.role() returns text language sql stable as $$
  select coalesce(nullif(current_setting('request.jwt.claim.role', true), ''), 'anon')
$$;

create or replace function auth.jwt() returns jsonb language sql stable as $$
  select coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb, '{}'::jsonb)
$$;

create or replace function auth.email() returns text language sql stable as $$
  select nullif(current_setting('request.jwt.claim.email', true), '')
$$;

-- ─── storage ───────────────────────────────────────────────────────────────
-- Column set matches what the migrations actually touch; Supabase's real table
-- has more, but a stub that is MISSING a referenced column turns a scaffold gap
-- into what looks like a migration defect (0081 caught exactly that).
create table if not exists storage.buckets (
  id                  text primary key,
  name                text not null,
  public              boolean default false,
  owner               uuid,
  file_size_limit     bigint,
  allowed_mime_types  text[],
  avif_autodetection  boolean default false,
  created_at          timestamptz default now(),
  updated_at          timestamptz default now()
);

create table if not exists storage.objects (
  id          uuid primary key default gen_random_uuid(),
  bucket_id   text references storage.buckets(id),
  name        text,
  owner       uuid,
  owner_id    text,
  created_at  timestamptz default now(),
  updated_at  timestamptz default now(),
  metadata    jsonb
);

-- Splits an object path into its segments; policies index into this.
create or replace function storage.foldername(name text)
returns text[] language sql immutable as $$
  select string_to_array(name, '/')
$$;

create or replace function storage.filename(name text)
returns text language sql immutable as $$
  select (string_to_array(name, '/'))[array_length(string_to_array(name, '/'), 1)]
$$;

-- ─── extensions (digest / random bytes live here on Supabase) ──────────────
create or replace function extensions.digest(data text, type text)
returns bytea language sql immutable as $$
  select extensions.digest(convert_to(data, 'UTF8'), type)
$$;

-- ─── vault ─────────────────────────────────────────────────────────────────
create table if not exists vault.secrets (
  id           uuid primary key default gen_random_uuid(),
  name         text unique,
  secret       text,
  description  text,
  created_at   timestamptz default now()
);

create or replace view vault.decrypted_secrets as
  select id, name, secret as decrypted_secret, description, created_at
  from vault.secrets;

create or replace function vault.create_secret(
  new_secret text, new_name text default null, new_description text default ''
) returns uuid language plpgsql as $$
declare v_id uuid;
begin
  insert into vault.secrets(name, secret, description)
  values (new_name, new_secret, new_description)
  on conflict (name) do update set secret = excluded.secret
  returning id into v_id;
  return v_id;
end $$;

-- ─── pg_cron stub ──────────────────────────────────────────────────────────
-- Real pg_cron cannot be installed here. Scheduling parses and records a row;
-- nothing executes. A green run says nothing about whether a job would fire.
create schema if not exists cron;

create table if not exists cron.job (
  jobid    bigserial primary key,
  schedule text,
  command  text,
  jobname  text unique,
  active   boolean default true
);

create or replace function cron.schedule(job_name text, schedule text, command text)
returns bigint language plpgsql as $$
declare v bigint;
begin
  insert into cron.job(jobname, schedule, command) values (job_name, schedule, command)
  on conflict (jobname) do update set schedule = excluded.schedule, command = excluded.command
  returning jobid into v;
  return v;
end $$;

create or replace function cron.schedule(schedule text, command text)
returns bigint language plpgsql as $$
declare v bigint;
begin
  insert into cron.job(jobname, schedule, command)
  values (md5(schedule || command), schedule, command)
  on conflict (jobname) do update set schedule = excluded.schedule
  returning jobid into v;
  return v;
end $$;

create or replace function cron.unschedule(job_name text)
returns boolean language plpgsql as $$
begin
  delete from cron.job where jobname = job_name;
  return true;
end $$;

-- ─── pg_net stub ───────────────────────────────────────────────────────────
-- Records the call and returns a request id. No HTTP leaves this container,
-- which is also why it runs with `--network none`.
create schema if not exists net;

create table if not exists net._http_log (
  id      bigserial primary key,
  url     text,
  body    jsonb,
  headers jsonb,
  called_at timestamptz default now()
);

create or replace function net.http_post(
  url text,
  body jsonb default '{}'::jsonb,
  params jsonb default '{}'::jsonb,
  headers jsonb default '{}'::jsonb,
  timeout_milliseconds int default 5000
) returns bigint language plpgsql as $$
declare v bigint;
begin
  insert into net._http_log(url, body, headers) values (url, body, headers) returning id into v;
  return v;
end $$;

-- `CREATE EXTENSION pg_cron / pg_net` must become no-ops: the schemas above
-- already provide the surface the migrations use, and the real extensions are
-- unavailable in a stock image.
-- ─── realtime publication ──────────────────────────────────────────────────
-- Supabase ships `supabase_realtime`; migrations ALTER it to add tables. Without
-- it, `alter publication ... add table` fails on a scaffold gap rather than on
-- anything real (0056 caught exactly that).
do $$
begin
  if not exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    create publication supabase_realtime;
  end if;
end $$;

create or replace function public._dryrun_noop() returns void language sql as $$ select $$;
