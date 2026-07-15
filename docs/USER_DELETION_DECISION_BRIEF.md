# Mali — User Deletion & Retention: Product Decision Brief

**Status:** APPROVED AND IMPLEMENTED. The recommended default below (30-day grace period, cancellable,
hard deletion, explicit Storage cleanup) was approved and is now live. See "Implementation" at the
bottom of this document for what was built and how to operate it.

## Why this decision is needed now

Confirmed by direct database query this session: there is **no foreign key from any `user_id` column
to `auth.users`**, and **no code anywhere** in the app, admin panel, or Edge Functions acts on the
existing-but-unused `profiles.delete_scheduled_at` column. If a user is deleted from `auth.users` by
any means today, every row they own across every financial table remains forever — orphaned,
unreachable through the app, but still present in the database. Mali currently has no way to fulfill a
user's request to delete their data. This is a real gap, not a hypothetical one, independent of when a
"delete my account" button is actually built into the app.

## The six decisions

### 1. Immediate hard deletion vs. grace-period deletion
- **Immediate:** data is gone the instant the user confirms. Simplest, most private, no support
  recourse for an accidental tap or a disputed request.
- **Grace period (recommended):** the request is recorded immediately (session ends right away,
  account stops being usable), but the actual data purge runs on a delay — e.g. 30 days — during which
  the request can be cancelled. Protects against accidental deletion and gives a window to resolve
  support disputes, at the cost of data sitting around slightly longer than "immediate" would.

### 2. Grace period length
Proposed default: **30 days**. Needs your confirmation — shorter is more private, longer is more
forgiving of mistakes; there may also be a jurisdiction-specific legal maximum that should override
this default if one applies to Mali's user base.

### 3. Cancellation during the grace period
Recommended: **yes** — a simple "cancel deletion" action, available any time before the purge runs,
that clears the pending-deletion flag and restores normal access. Needs your confirmation on whether
this is offered at all, and if so, how (in-app only, or also via a support channel).

### 4. Hard deletion vs. anonymization
- **Anonymization** (scrub PII, keep rows for analytics): **not recommended** as the default for Mali.
  In a personal-finance app, the amounts, merchants, and dates *are* the sensitive data — anonymizing
  a name/email while leaving spending patterns intact doesn't meaningfully reduce the privacy exposure,
  and there's no clear analytics use case identified that would justify keeping the rows.
- **Hard deletion (recommended):** every row across every `user_*` table, the Storage backup blob, and
  the `auth.users` row itself are permanently removed once the grace period elapses. Cleaner, more
  defensible, matches user expectation of "delete means delete."

### 5. Backup/storage cleanup
Whichever retention model is chosen, the user's encrypted backup blob in Supabase Storage
(`backups.blob_path`) must be explicitly removed via a Storage API call — deleting the database row
that references it does **not** delete the underlying object. This is a required part of any
implementation, not optional.

### 6. Account recovery during the grace period
If option 1 is "grace period," recovery is just "cancel the pending deletion" (see #3) — no separate
mechanism needed. If option 1 is "immediate," there is no recovery path at all once confirmed, which
should be made very explicit in the confirmation UI copy if that's the chosen model.

## Recommended default (pending your approval)

Grace-period deletion, 30 days, cancellable, ending in hard deletion (not anonymization), with
explicit Storage cleanup as part of the same worker. Session/access ends immediately on request even
though the data purge is deferred, so a "pending deletion" account can't keep being used during the
window.

## What happens once this is approved

The database-side scaffolding (a `purge_user_data(user_id)` function performing the ordered
child-to-parent deletes, plus a scheduled worker that also calls the Storage API and the Auth Admin
API) is straightforward to build once the parameters above are fixed — it does not need to be
re-designed, only the exact grace-period number and cancellation UX need to be confirmed. The
user-facing "request deletion" entry point is a separate, so-far-unscoped piece of UI work — **it is
not yet confirmed whether one exists anywhere in the app today**; if it doesn't, building it is
additional scope beyond the backend worker and should be estimated separately once noticed.

## Exactly what approval is required to proceed

A single written confirmation (this section, filled in and returned) of:
- [ ] Grace period vs. immediate — which one
- [ ] If grace period: exact number of days
- [ ] Cancellation offered — yes/no, and how
- [ ] Hard delete vs. anonymize — which one
- [ ] Any known legal/jurisdictional requirement that overrides the defaults above
- [ ] Confirmation that a "request deletion" UI does not yet exist (or a pointer to where it does, if
      it does) — so the follow-up scope is accurate

No destructive code will be written or scheduled until this is returned.

## Implementation

Three Postgres functions (`supabase/migrations/0042_account_deletion_policy.sql`, rollback in
`supabase/rollback/0042_account_deletion_policy_rollback.sql`):

- `request_account_deletion()` — `security invoker`, `authenticated`-only. Sets
  `profiles.delete_scheduled_at = now() + 30 days` for the calling user. Idempotent: a second call
  while already scheduled returns the existing date rather than pushing it forward.
- `cancel_account_deletion()` — `security invoker`, `authenticated`-only. Clears
  `delete_scheduled_at` for the calling user. Safe no-op if nothing is scheduled.
- `purge_user_data(p_user_id uuid)` — `security invoker`, `service_role`-only (revoked from
  `public`/`anon`/`authenticated`). Deletes every row the user owns, child tables before parents, then
  the `profiles` row itself.

Client: `app/lib/core/auth/account_deletion_service.dart` wraps the three RPCs;
`app/lib/features/settings/privacy_screen.dart` is the entry point (danger zone → "حذف الحساب وكل
بياناتي"). Confirming schedules deletion, signs the device out of Supabase, and wipes local data.
Cancelling is available from the same screen for the duration of the grace period via a pending-deletion
card.

Worker: `supabase/functions/purge-scheduled-deletions/index.ts`. For every `profiles` row whose
`delete_scheduled_at` has elapsed: reads the backup blob path, calls `purge_user_data`, removes the
Storage blob (`backups` bucket), then deletes the `auth.users` row via the Auth Admin API.

**Not wired to an automatic schedule yet.** Invoking it requires a bearer token equal to the
`PURGE_WORKER_SECRET` Edge Function secret (set via `supabase secrets set`, not committed to git; the
function itself has `verify_jwt = false` in `config.toml` since its caller is an ops worker, not a
Supabase-authenticated user). Deliberately not wired to `pg_cron` yet — doing so means embedding that
secret into a cron job's SQL text, which is a separate operational decision, not something to make
silently. Until that decision is made, someone with access to the secret needs to invoke this function
on a schedule (e.g. daily) by an external means (a cron host, a manual run, CI, etc.).

Verified live end-to-end: a throwaway user with a seeded account, a real Storage blob, and an overdue
`delete_scheduled_at` was fully purged by one worker invocation — profile, account, and backup rows
gone, the Storage object gone, and the `auth.users` row gone.
