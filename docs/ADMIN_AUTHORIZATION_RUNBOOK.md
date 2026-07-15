# Admin Authorization Runbook

The admin app is fail-closed. A valid Supabase session is not enough: the
authenticated user's UUID must also exist in `public.admin_users`.

## Bootstrap

1. Identify the intended administrator in Supabase Auth and copy that user's
   UUID. Do not use an email address or any client-supplied role as authority.
2. Before deploying the protected admin app, run this through the Supabase SQL
   Editor or another service-role-only channel:

```sql
insert into public.admin_users (id, note)
values ('<AUTH_USER_UUID>', 'initial administrator')
on conflict (id) do nothing;
```

3. Sign in to the admin app and verify access to `/dashboard` and one protected
   API. A normal authenticated QA user must be redirected to `/not-authorized`.
4. Only then deploy the protected admin UI and `parser-test` function.

Never put a service-role key in the browser, Flutter app, or build logs.

## Grant And Revoke

Grant access only from the SQL Editor/service-role environment:

```sql
insert into public.admin_users (id, granted_by, note)
values ('<AUTH_USER_UUID>', '<GRANTING_ADMIN_UUID>', '<REASON>')
on conflict (id) do update
set granted_by = excluded.granted_by,
    granted_at = now(),
    note = excluded.note;
```

Revoke immediately:

```sql
delete from public.admin_users where id = '<AUTH_USER_UUID>';
```

Existing browser state cannot forge or retain access after revocation because
every protected request checks server-side membership.

## Emergency Lockout

To lock out every admin while investigating an incident:

```sql
delete from public.admin_users;
```

Restore one known administrator through the SQL Editor using the bootstrap
statement. Do not weaken RLS or add a temporary client-side bypass. Rolling back
the migration also fails closed because the authorization lookup cannot succeed.
