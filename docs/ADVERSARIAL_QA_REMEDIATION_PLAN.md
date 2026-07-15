# Mali — Adversarial QA Remediation Plan

Status legend: `READY TO IMPLEMENT` · `BLOCKED BY PRODUCT DECISION` · `BLOCKED BY ACCESS` · `REQUIRES LIVE MIGRATION APPROVAL` · `MANUAL QA REQUIRED`

This plan is the implementation-ready handoff for the 27 findings from the adversarial QA pass (source of truth: the QA report delivered in this session). Nothing in this document has been implemented, migrated, deployed, or committed. It is written so Codex can execute each finding without needing to re-derive root cause or re-discover the affected code.

Global constraints that apply to every finding below, restated once so individual entries don't repeat them:
- No client-side check may be the only enforcement for a security-sensitive behavior.
- No RLS policy may be weakened. No service-role key may enter the Flutter app.
- No Android SMS permission may be added. `processed_captures` and the Swift `PreviewParser` may not be removed.
- No global feature flag may be enabled by this work. Every new flag defaults `is_active = false`, `rollout_percent = 0`.
- Every live migration ships with a rollback file. Migrations are additive-first; destructive schema changes require an explicit separate approval step.
- Every race-condition fix ships with a deterministic concurrency test (not a timing-based flaky test).
- Every auth/security fix ships with negative tests: a normal authenticated non-admin user, and an unauthenticated caller, both denied.
- Any UI-only behavior is marked `MANUAL QA REQUIRED` in addition to whatever automated coverage exists, because this environment cannot drive a real iOS interactive session.
- Idempotency keys already in use (`client_request_id`, `payload_id`, `local_id`) are reused, never replaced with a new scheme.
- A financial write is only treated as authoritative after Supabase confirms it — local/Drift state is a cache, never the source of truth, for anything touched by this plan.

---

## 1. Executive Summary

27 findings, batched into 4 waves ordered by blast radius and reachability, not by discovery order. Batch 1 (8 findings) contains everything that is either a live security hole reachable by any of the 10,000 launch users today (admin panel), a path that silently corrupts or duplicates financial data with no user-visible signal, or a straight-line UX bug that skips a mandatory setup step for every new user hitting it. Batch 2 (7 findings) is data-correctness work that requires no urgent lockdown but will quietly produce wrong numbers or duplicate alerts if left alone. Batch 3 (6 findings) is performance/resilience work that degrades user experience under real-world load (years of history, flaky networks) but doesn't corrupt data. Batch 4 (6 findings) is privacy/UX polish — real, but nothing here causes data loss or financial miscalculation.

One finding (#8, user deletion/retention) cannot be fully closed by engineering alone — it needs a product/legal decision on retention period and hard-delete-vs-anonymize before the worker logic is finalized. A default-safe implementation path is specified so Codex isn't blocked on infrastructure work, but the policy parameters are flagged `BLOCKED BY PRODUCT DECISION`.

Three findings (#2, #3, #4) touch the capture pipeline and are the ones most likely to actually be firing in production right now for real users, given how ordinary the triggering conditions are (a flaky Shortcuts double-forward, a weak-signal SMS, a sign-out on a shared device) — these get the deepest implementation detail in this document, matching the required depth for Batch 1.

## 2. Dependency Graph

```
Batch 1 (release blockers) — mostly independent of each other, can ship in parallel PRs:

  #1 Admin authorization ──────────────────────────────────────► standalone (admin/ only)
  #2 Fingerprint race ─────────────────────────────────────────► standalone (process-ios-sms only)
  #3 Device unlink/rotation ───► needs new processed_captures column ──► blocks nothing else, but
                                                                          should land before #10
                                                                          (capture health) so health
                                                                          signals aren't polluted by
                                                                          cross-user relay noise
  #4 SMS durability ───────────────────────────────────────────► standalone (Swift only)
  #5 Onboarding bypass ────────────────────────────────────────► standalone (Flutter only)
  #6 Account create/delete UI safety ──────────────────────────► precedes #15 (atomic RPC hardens
                                                                    what #6 already mitigates client-side)
  #7 Bill-payment UX ──────────────────────────────────────────► precedes #20 (two-phase→one-RPC
                                                                    consistency upgrade)
  #8 User deletion/retention ──► BLOCKED BY PRODUCT DECISION for policy params; schema/worker
                                  scaffolding is independently implementable now

Batch 2 (data correctness):
  #9  Riyadh timezone ─────────► standalone
  #10 Capture health monitor ──► soft-depends on #3 (cleaner signal) and #4 (queue states to surface)
  #11 Budget alert race ───────► standalone
  #12 Atomic local capture queue ► standalone (Swift, same file family as #4 — bundle in same PR)
  #13 DB CHECK constraints ────► standalone, but should land after #6/#25 UI validation ships,
                                  so users see a friendly client error before ever hitting the DB 400
  #14 Sender/bank ambiguity ───► standalone
  #15 Atomic last-account deletion ► depends on #6 (client already guards; this is the server-side
                                       belt-and-suspenders layer)

Batch 3 (performance/resilience):
  #16 Lazy/paginated tx list ──► standalone
  #17 Resumable pagination ────► pairs with #16 (#16 = rendering, #17 = fetch layer), ship together
  #18 Server-side aggregates ──► reuses the RPC-wiring analysis already done pre-pivot in this
                                  session (budget_progress_summary / category_spending_summary /
                                  monthly_financial_summary) — see note in §6
  #19 Backup schema-version framework ► standalone
  #20 Bill two-phase → single RPC ► depends on #7 shipping first (UI already handles partial
                                      failure gracefully; this removes the failure mode at the root)
  #21 Rate-limit hardening ────► standalone, reuses bump_capture_rate_limit pattern

Batch 4 (privacy/UX):
  #22 App-switcher privacy ────► standalone (Android)
  #23 Screenshot policy ───────► standalone (iOS), ship in same PR as #22
  #24 Loading/progress states ─► sweep of remaining screens after #6/#7 establish the pattern
  #25 Form validation ─────────► client-side companion to #13
  #26 APNs diagnostics ────────► standalone
  #27 Minor UX/logging ────────► grab-bag, no dependencies
```

## 3. Batch Ordering Rationale

Batch 1 is ordered by **who can reach the bug and how much damage one occurrence does**, not by how hard the fix is. The admin-panel gap (#1) is first because it requires zero special conditions — any of the 10,000 users can trigger it today by simply visiting a URL. The fingerprint race (#2) and device-ownership gap (#3) are next because both silently corrupt or misattribute real financial data with no error surfaced to anyone. SMS durability (#4) is a silent data-loss path. Onboarding (#5) and accounts (#6) are straight-line UX bugs reachable by every new user, not edge cases requiring bad luck. Bill payments (#7) is included in Batch 1 because it's the same "silent duplicate/partial write" class as #2, just in a lower-traffic surface. User deletion (#8) is included last in Batch 1 specifically because it's a compliance exposure (not a live bug being hit today) — it belongs in the release-blocker batch because a real deletion request arriving post-launch with zero handling is a legal problem, but it's ordered last within the batch because it's blocked on a policy decision rather than pure engineering.

Batch 2 items are real but require specific, less common conditions (travel/diaspora users for #9, two near-simultaneous app-resume events for #11, a shared sender ID across two banks for #14) or are silent-but-slow-burning (no capture-health signal, #10). None of them are reachable by simply using the app normally the way Batch 1's items are.

Batch 3 is pure resilience/performance — nothing here is wrong today for a typical launch-week user with a few weeks of history; all of it becomes a real problem as account age and data volume grow, which is a multi-month timeline, not a launch-week one.

Batch 4 is privacy hygiene and UX polish with no data-integrity or security dimension at all.

---

## 4. Detailed Batch 1 Implementation Plan

### Finding #1 — Admin panel has no admin-role check

**Severity:** Critical · **Status:** READY TO IMPLEMENT (schema + middleware); bootstrap step is BLOCKED BY ACCESS (needs a real admin email to seed)

**Exact root cause:** `admin/middleware.ts` calls `supabase.auth.getUser()` and treats "a valid session exists" as sufficient authorization. There is no table, claim, or check anywhere in the admin codebase that distinguishes an admin from any other registered Mali user. The admin Next.js app shares the same Supabase project, the same `auth.users` table, and the same anon key as the mobile app.

**Current behavior:** Any of the 10,000 launch users can navigate to the admin panel's login page, sign in with their own regular Mali app email/password, and land on `/dashboard`, `/banks`, `/parsers`, `/categories`, `/flags`, `/announcements`.

**Expected behavior:** Only rows present in a new `admin_users` table may reach any route under the `(admin)` route group or invoke any admin server action/API route. Every other authenticated user is redirected to a "not authorized" page and signed out of the admin session (not the mobile app session — these are independent browser/app sessions against the same auth backend).

**Affected files:**
- `admin/middleware.ts` (add the admin-membership check)
- `admin/lib/auth-guard.ts` (new file — shared `requireAdmin()` helper)
- Every file under `admin/app/(admin)/**/actions.ts` or equivalent server-action files (add `requireAdmin()` as the first line of every exported server action)
- `admin/app/(admin)/layout.tsx` (add a server-side admin check at layout render time, defense-in-depth alongside middleware)
- `admin/app/login/page.tsx` or wherever login redirect targets `/dashboard` (add a post-login admin check before redirecting, show "not authorized" instead of dashboard for non-admins)
- New: `admin/app/not-authorized/page.tsx`

**Affected database tables/functions/RPCs:**
- New table: `public.admin_users (id uuid primary key references not enforced — see note, granted_at timestamptz not null default now(), granted_by uuid null, note text null)`
- No changes to `banks`, `sms_parsers`, `categories`, `feature_flags`, etc. — these are correctly written via the service-role key already (confirmed: `admin/lib/supabase-server.ts` reads `SUPABASE_SERVICE_ROLE_KEY` server-side only). RLS on those tables is for the *mobile app's* anon/authenticated read access and is unrelated to this bug — do not touch it.

**Affected feature flags:** None. This is not gated behind a flag — it is a straight security fix and must apply unconditionally the moment it deploys.

**Proposed technical solution:**
A dedicated `admin_users` table, checked server-side on every protected request, with no client-side admin flag anywhere.

Note on the FK: do not add `references auth.users(id)` as an enforced foreign key — Supabase's `auth` schema FKs from `public` are supported but adding one here is unnecessary complexity for a small allowlist table; instead just store the UUID and validate it points to a real user at bootstrap time (see below). This keeps the migration simple and avoids any interaction with the `auth` schema's own migration lifecycle.

RLS on `admin_users`:
```sql
alter table public.admin_users enable row level security;
-- Self-check only: a user may see whether THEIR OWN id is present (needed so the
-- app-layer check can simply query "select 1 from admin_users where id = auth.uid()"
-- using the ordinary anon-key client, no service role needed for the check itself).
create policy "admin_users_self_check" on public.admin_users
  for select using (auth.uid() = id);
-- No insert/update/delete policy at all. The table can only be modified via the
-- service-role key or direct SQL (Management API / SQL editor) — never by any
-- authenticated client request. This is the actual security boundary: a regular
-- user cannot grant themselves admin no matter what they send from the client.
```

Middleware enforcement (`admin/middleware.ts`):
```
1. Existing: const { data: { user } } = await supabase.auth.getUser()
2. If no user → existing redirect to /login (unchanged)
3. NEW: const { data: adminRow } = await supabase
         .from('admin_users').select('id').eq('id', user.id).maybeSingle()
4. NEW: if (!adminRow) → redirect to /not-authorized (do NOT redirect to /login —
        the user IS authenticated, just not authorized; conflating the two states
        would be confusing and could invite a retry-login loop)
5. Only then: allow through to the (admin) route group
```
This must run on every matched request (confirm `middleware.ts`'s `config.matcher` already covers all `(admin)` routes — extend if it currently excludes anything, e.g., API routes under `admin/app/api/`).

Server-action/API enforcement (`admin/lib/auth-guard.ts`, new):
```ts
export async function requireAdmin() {
  const supabase = createServerClient(...); // existing server-side client factory
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) throw new Error('unauthenticated');
  const { data: adminRow } = await supabase
    .from('admin_users').select('id').eq('id', user.id).maybeSingle();
  if (!adminRow) throw new Error('not_authorized');
  return user;
}
```
Call `await requireAdmin()` as the literal first statement of every server action and every API route handler under `admin/app/(admin)/**` and `admin/app/api/**`. This is deliberately redundant with middleware — Next.js server actions can in some configurations be invoked by a direct POST that bypasses middleware matching depending on version/config, so the action itself must not trust that middleware already ran.

Layout-level check (`admin/app/(admin)/layout.tsx`): call the same check at layout render (server component) as a third redundant layer — belt-and-suspenders, cheap, and catches any route added later by someone who forgets middleware config.

**Alternative solutions considered:**
1. *Custom JWT claim* (`app_metadata.role = 'admin'`) checked directly off the JWT with no DB round trip. Rejected as the primary mechanism because rotating/revoking admin access would require calling the Admin API to update `app_metadata` and waiting for token refresh — slower to revoke in an emergency than deleting one row from a table. A DB-table check is instantly effective on the very next request.
2. *Fully separate Auth project/instance for admin.* Rejected as disproportionate — this is an internal tool for a small number of operators, not a customer-facing multi-tenant admin surface; the isolation benefit doesn't justify re-platforming the login flow before launch.
3. *IP allowlist / VPN-only access.* Worth layering in later as defense-in-depth but rejected as the *primary* fix because it doesn't address the actual bug (missing authorization logic) and depends on infrastructure (static IPs, VPN) not yet confirmed to exist.

**Why the chosen solution is safest:** It adds a new, isolated, additive table with no insert/update/delete policy reachable by any client — the only way to become an admin is a direct SQL statement run by someone with database access, which is exactly the trust boundary Mali already relies on for every other admin-only operation (service-role key usage). It requires no changes to any existing table's RLS, no changes to the mobile app, and is instantly revocable by deleting one row — no token expiry to wait out.

**Exact implementation steps:**
1. Write migration `NNNN_admin_users.sql` (see Migration Plan, §8, for the exact slot) creating the table + RLS policy above, `grant select on admin_users to authenticated` (select only, no other grants to `authenticated`/`anon`).
2. Write rollback `NNNN_admin_users_rollback.sql`: `drop table if exists public.admin_users;`
3. Add `admin/lib/auth-guard.ts` with `requireAdmin()`.
4. Update `admin/middleware.ts` per the pseudocode above.
5. Update `admin/app/(admin)/layout.tsx` to call `requireAdmin()` and redirect to `/not-authorized` on throw.
6. Add `requireAdmin()` as the first line of every server action / API route handler under `admin/app/(admin)/**`, `admin/app/api/**` (enumerate via `grep -rl "use server"` and `grep -rl "export async function (GET|POST|PUT|DELETE)"` under `admin/app`).
7. Add `admin/app/not-authorized/page.tsx` — simple static page, no data fetching, explains the account is not an admin account and offers a sign-out link.
8. Update login success redirect to check admin status before routing to `/dashboard`; route non-admins to `/not-authorized` instead.

**Exact file-by-file change plan:**
| File | Change |
|---|---|
| `admin/lib/auth-guard.ts` | New file, `requireAdmin()` export |
| `admin/middleware.ts` | Add admin-membership check after existing session check |
| `admin/app/(admin)/layout.tsx` | Add server-side `requireAdmin()` call |
| `admin/app/not-authorized/page.tsx` | New static page |
| `admin/app/login/page.tsx` (or its server action) | Check admin status before redirect target |
| Every `admin/app/(admin)/*/actions.ts` (banks, parsers, categories, flags, announcements) | Add `await requireAdmin()` as first line of each exported action |

**Database migration requirements:** One additive migration (new table + RLS + grant). REQUIRES LIVE MIGRATION APPROVAL before applying to the production project, per standing process this session — apply via the same Management API method used for prior migrations, then verify with `supabase migration list --linked` shows it as applied on both local and remote (the exact gap found and fixed for migration 0034 earlier this session — do not repeat that gap here; run `supabase migration repair` immediately if the tracking table doesn't reflect it).

**Rollback plan:** Drop the `admin_users` table (rollback file). If dropped, `requireAdmin()`'s query returns no rows for everyone — this **fails closed** (locks everyone out of the admin panel, including real admins) rather than failing open, which is the correct safe direction for a rollback of a security fix. Emergency access during a lockout: connect via the Supabase Dashboard SQL editor directly (bypasses the Next.js app and its bug entirely) and re-insert the admin row, or re-apply the migration.

**Data migration/backfill requirements:** None beyond the bootstrap insert (not a backfill — there is no prior admin-role data to migrate from).

**Security implications:** This closes a live privilege-escalation hole. No new attack surface is introduced — the new table is unreachable for writes by any client role.

**RLS implications:** New RLS policy on the new table only (select, own-row). No existing policy changed.

**Auth/session implications:** None for the mobile app. Admin-panel sessions for non-admin users are now redirected rather than granted access; their Supabase session itself remains valid (they can still use the mobile app normally) — only admin-panel access is denied.

**Offline implications:** None — admin panel has no offline mode.

**Notification implications:** None.

**Performance implications:** One additional indexed point-select (`admin_users` PK lookup) per admin-panel request — negligible.

**Compatibility risks:** None for the mobile app. Existing real admins must be seeded into `admin_users` before this ships, or they will be locked out (see bootstrap procedure).

**Test plan:**
- Unit: `requireAdmin()` throws for (a) no session, (b) valid session not in `admin_users`, (c) resolves for a valid session present in `admin_users`.
- Integration: hit every route under `(admin)` and every server action with (a) no auth cookie, (b) a real non-admin user's session, (c) a real admin user's session — assert 401/redirect, 403/redirect, and 200 respectively.

**Regression tests required:**
- Negative test (normal user): create a throwaway Supabase user via Admin API (same pattern used throughout this session's live QA), sign in to the admin panel with it, assert redirect to `/not-authorized` on every protected route and every server action.
- Negative test (unauthenticated): hit protected routes/actions with no session at all, assert redirect to `/login`.
- Forged-state test: attempt to set any client-controlled cookie/header/localStorage value that might resemble an "isAdmin" flag (there currently is none — this test asserts none is ever introduced/trusted by grepping the diff for any `req.cookies`/`req.headers` role check and asserting the only admin check path is the DB query).
- Positive test: seed a throwaway user into `admin_users`, confirm they *can* reach `/dashboard` and successfully call a server action.

**Manual iPhone tests required:** None — this finding is entirely within the Next.js admin panel, no mobile-app surface.

**Acceptance criteria:**
- A non-admin authenticated user is denied at middleware, layout, and server-action layers (all three independently verified by test, not just one).
- An admin user's existing workflows (viewing/editing banks, parsers, categories, flags, announcements) work unchanged.
- No RLS policy on any pre-existing table was modified.

**Definition of done:** Migration applied and verified in migration history; at least one real admin seeded and confirmed able to log in; all three regression test classes passing; PR reviewed and merged (not committed by this process — per standing instruction, changes are left for the user to review/commit).

**Dependencies on other findings:** None. Ship first, independently.

**Recommended commit grouping:** Single PR: migration + rollback, `auth-guard.ts`, middleware, layout, not-authorized page, and the `requireAdmin()` call added to every existing server action in one pass (touching many small files but one logical change).

**Stop conditions and rollback triggers:** If, after deploy, the seeded admin cannot log in, do not attempt further live fixes — immediately connect via the SQL editor, confirm the `admin_users` row exists with the exact correct UUID (`select id from auth.users where email = '...'` to cross-check), and fix directly in SQL. If the issue persists beyond a few minutes of investigation, roll back the migration (locks everyone out, fails closed, buys time to investigate without leaving the hole open).

---

### Finding #2 — Duplicate transactions from an unhandled race in fingerprint dedup

**Severity:** High · **Status:** READY TO IMPLEMENT

**Exact root cause:** `supabase/functions/process-ios-sms/index.ts`'s `detectDuplicate()` performs a `SELECT` against fingerprint candidates, then — if nothing found — a plain `INSERT` into `capture_fingerprints` whose result (including any `23505` unique-violation) is never read or checked. This is a classic check-then-act race: two requests for the same real message, each minting a distinct `payload_id`, can both complete their SELECT before either completes its INSERT, both see "no existing fingerprint," and both proceed to create a real transaction.

**Current behavior:** Two capture requests landing within the same fingerprint bucket, close enough in time, both succeed and both write a transaction — one real purchase becomes two ledger entries with no error, no warning, and no way for the user to know without manually noticing the duplicate.

**Expected behavior:** Exactly one of two racing requests for the same fingerprint ever creates a transaction; the other is deterministically treated as a duplicate, regardless of how close together in time the two requests arrive (down to true simultaneity).

**Affected files:** `supabase/functions/process-ios-sms/index.ts` (the `detectDuplicate()` function and its call site), `supabase/functions/_shared/capture_fingerprint.ts` (no change to the bucketing logic itself, only to how the result is used)

**Affected database tables/functions/RPCs:** `capture_fingerprints` (existing composite PK `(install_id_hash, fingerprint)` — this is the atomicity primitive; no schema change needed here)

**Affected feature flags:** None — this is a correctness fix, not gated.

**Proposed technical solution — atomic reservation design:**
Flip the operation from "select, then insert if absent" to "insert first, treat a unique-violation as the duplicate signal" — the same pattern already correctly used for the sibling `payload_id` replay check in this same file (which does check `error.code === '23505'`), just not yet applied to this second, independent fingerprint path.

**Unique key/index shape:** No change — the existing `(install_id_hash, fingerprint)` composite primary key already provides exactly the serialization guarantee needed. The fix is entirely in how the Edge Function *uses* that constraint.

**Conflict handling:**
```
1. Compute fingerprint bucket key(s) via the existing fingerprintTimeKeys() logic
   (current bucket + previous bucket for received_at-sourced timestamps; exact
   match only for sms_body-sourced timestamps — unchanged).
2. Attempt: INSERT INTO capture_fingerprints (install_id_hash, fingerprint,
   payload_id, seen_at) VALUES (...) for the CURRENT bucket key — this is the
   atomic reservation. Do this BEFORE deciding processed/duplicate status and
   BEFORE any transaction insert.
3. If this INSERT succeeds: this request is NOT a duplicate on the current-bucket
   key. Separately SELECT (read-only, no insert) the previous-bucket key to check
   for a match against an already-committed row from a genuinely earlier capture
   (preserves today's two-bucket tolerance window). If found, treat as duplicate
   per existing suspicious_duplicate semantics.
4. If the INSERT in step 2 raises 23505: another request already reserved this
   exact bucket key. Catch the error explicitly (mirroring the existing
   payload_id-replay error-code check elsewhere in this file), do NOT insert a
   transaction, and return the existing duplicate-status response shape already
   used elsewhere in this function (reuse, don't invent a new response shape).
```

**Interaction with payloadId idempotency:** Unchanged and unaffected — the existing `payload_id` replay check (same `payloadId` resubmitted, e.g. client retry) still runs first, exactly as today. This fix adds a second, independent layer underneath it for the case of two *different* `payloadId`s representing the same real-world message. Both checks coexist; neither replaces the other.

**Concurrent request sequence (also the regression test spec):**
1. Device (or a flaky Shortcuts automation) sends capture A (`payloadId=X`) and capture B (`payloadId=Y`) for the same real SMS, landing in the same fingerprint bucket, at nearly the same wall-clock time.
2. Both pass the (unrelated, unchanged) `payload_id`-replay check — neither is a replay of the other.
3. Both attempt the reservation INSERT for the identical `(install_id_hash, fingerprint)` key.
4. Postgres serializes: exactly one commits, the other raises `23505` — guaranteed by the unique index regardless of process/network timing, not a best-effort mitigation.
5. Winner proceeds to parse and insert into `processed_captures`/`user_transactions` as normal.
6. Loser catches `23505`, marks its capture as a duplicate, creates no transaction, returns a duplicate-status response (not an error) so the client doesn't retry or show an error toast.

**Alternative solutions considered:**
1. *Application-level mutex/lock (e.g., Postgres advisory lock on the fingerprint key) held across the whole check-and-decide sequence.* Rejected — more moving parts than needed; the unique constraint already provides the exact atomicity required with less code and no lock-release-on-crash risk.
2. *Serialize all captures for an install through a queue/single-writer.* Rejected — would add latency and complexity to every request to fix a rare race; the reservation-insert approach fixes it with zero added latency for the common (non-racing) case.

**Why the chosen solution is safest:** It reuses an already-existing, already-correct pattern in the same file (the `payload_id` 23505 handling) rather than introducing new locking primitives, minimizing the chance of a new, different bug. The database's own unique-constraint enforcement is the single source of truth for "who won the race," which cannot be fooled by clock skew, retries, or process scheduling the way an application-level check-then-act ever could be.

**Exact implementation steps:**
1. In `detectDuplicate()` (or a new sibling function `reserveFingerprint()`), reorder logic per the 4-step conflict-handling sequence above.
2. Explicitly capture and branch on the INSERT's error (`error?.code === '23505'`), matching the existing style used for the `payload_id` path elsewhere in the same file.
3. Ensure the previous-bucket SELECT-only check still runs on the non-conflict path, unchanged from today.
4. Add the Deno regression test (see Test Plan).

**Exact file-by-file change plan:**
| File | Change |
|---|---|
| `supabase/functions/process-ios-sms/index.ts` | Reorder `detectDuplicate()`'s logic to insert-first-then-check-conflict; explicit `23505` branch |
| `supabase/functions/process-ios-sms/index_test.ts` (or new `duplicate_race_test.ts`) | New concurrency regression test |

**Database migration requirements:** None — no schema change, this is purely an Edge Function logic fix.

**Rollback plan:** Redeploy the previous Edge Function version (`supabase functions deploy process-ios-sms` from the prior commit) — no schema/data changes to unwind.

**Data migration/backfill requirements:** None.

**Security implications:** None new. This closes a data-integrity gap, not a security gap.

**RLS implications:** None — `capture_fingerprints` RLS is already `false`/service-role-only and is unaffected.

**Auth/session implications:** None.

**Offline implications:** None — this is server-side only.

**Notification implications:** The "loser" request's client no longer gets a false "processed" response for a message that was actually a duplicate — it gets the existing duplicate-status shape, meaning the Swift extension's own notification logic (already correct, per this session's earlier collapse-id fix) receives an honest status and does not fire a second "new transaction" push for the same real purchase.

**Performance implications:** Negligible — one INSERT replaces one SELECT-then-conditional-INSERT; same number of round trips in the non-conflict path, one fewer in the conflict path (no longer need the initial SELECT before deciding to insert).

**Compatibility risks:** None — response shape for the duplicate case is unchanged (reusing the existing shape).

**Test plan:** Deno test using `Promise.all([...])` to fire two concurrent invocations of the reservation logic (or the full function handler, stubbing the parse step) with distinct `payloadId`s but identical fingerprint-relevant fields (same `install_id_hash`, same amount/merchant/time bucket). Assert: exactly one results in a transaction/processed status, the other results in a duplicate status, and no unhandled exception is thrown by either.

**Regression tests required:** The concurrency test above is the primary regression test (required per global constraints, since this is a race-condition fix). Also add a non-concurrent regression test confirming the existing "genuinely different transaction, different bucket" case still creates two transactions (no over-suppression introduced by this change).

**Manual iPhone tests required:** MANUAL QA REQUIRED — trigger two real bank SMS with the same amount/merchant within a few seconds of each other (or use the Shortcuts "run automation" action twice back-to-back on the same message) and confirm only one transaction appears.

**Acceptance criteria:** Live QA (same methodology as this session's collapse-id verification): fire two concurrent `process-ios-sms` calls with distinct payloadIds and colliding fingerprint fields against a throwaway QA install; confirm exactly one `processed_captures`/`user_transactions` row results.

**Definition of done:** Concurrency test passing in CI, live QA re-verification performed and documented (mirroring the collapse-id fix's live-evidence standard from earlier this session), deployed, no new `InvalidCollapseId`-style regressions in the surrounding function.

**Dependencies on other findings:** None.

**Recommended commit grouping:** Single PR, this function only.

**Stop conditions and rollback triggers:** If live QA shows the reservation insert introduces false-positive duplicates (two genuinely distinct transactions wrongly suppressed), stop and re-examine the previous-bucket SELECT logic before proceeding — do not ship a fix that trades duplicate-creation for duplicate-suppression.

---

### Finding #3 — Capture-device ownership never rotates/clears across sign-out and user changes

**Severity:** High · **Status:** READY TO IMPLEMENT (requires one additive column)

**Exact root cause:** `capture_devices.user_id` is only ever *set* (by `link-capture-device` on sign-in), never cleared, and `device_secret_hash` is never rotated on sign-out or re-link (explicitly documented in that function's own comment). `AppSession.signOut()` performs only local secure-storage cleanup and never calls any backend endpoint to unlink the device. Separately, `processed_captures` has no `user_id` column at all — only `install_id_hash` — so `sync-captures` (which drains the relay queue) is scoped to the *device*, not to whichever user is *currently* authenticated on it.

**Current behavior:** Two distinct hazards on a shared/handed-down physical device: (a) if direct-write/dual-write is enabled, a capture arriving in the gap between a new user opening the app and their `linkToCurrentUser()` call completing can be attributed to the *previous* user's Supabase `user_id`, since the Edge Function's direct-write path resolves the owning user from `capture_devices.user_id`, which is still stale; (b) unsynced `processed_captures` rows created while the device belonged to User A, if still unacked when User B links the same device, can be pulled by User B's client via `sync-captures`, since that endpoint filters by device identity only, not by which user actually captured the data.

**Expected behavior:** Signing out clears device ownership immediately (best-effort, retried on next launch if the call fails offline). A device with no linked owner behaves identically to a never-linked device (relay-only, no direct-write). Relay rows are stamped with the owning user at capture time and can only ever be claimed by that same user (or, if unclaimed/pre-link, by whoever links first) — never re-attributed to a different user after a hand-off.

**Affected files:** `app/lib/core/session/app_session.dart` (`signOut()`), `app/lib/features/capture/services/capture_device_registration_service.dart`, `supabase/functions/link-capture-device/index.ts`, `supabase/functions/sync-captures/index.ts`, `supabase/functions/process-ios-sms/index.ts` (the direct-write attribution lookup)

**Affected database tables/functions/RPCs:** `capture_devices` (no schema change — `user_id` is already nullable), `processed_captures` (additive nullable column, see below)

**Affected feature flags:** None new; interacts with existing `capture_direct_supabase_write` / `ledger_dual_write` (both currently `is_active = false` — this fix must be correct regardless of whether those flags are ever turned on, since they gate exactly the attribution logic this finding is about).

**Proposed technical solution:**

*Unlink and rotate behavior on sign-out:* Add a new Edge Function `unlink-capture-device` (device-credential-authenticated, same `verifyDevice()` pattern as every other capture endpoint — no Supabase JWT involved, matching the existing "App Intent never carries a user JWT" constraint) that sets `capture_devices.user_id = NULL` for the calling device. Call this from `AppSession.signOut()` as a best-effort, fire-and-forget call (do not block the sign-out UI on it; if it fails — e.g., offline — the next successful `linkToCurrentUser()` call on the *next* sign-in will still correctly overwrite `user_id` to the new user, so failure here is not catastrophic, only widens the exposure window slightly). Do NOT rotate `device_secret_hash` on sign-out — the App Intent extension must continue to authenticate with the same secret regardless of which Supabase user is currently signed into the Flutter app, since capture can and should continue working (relay-only) even when signed out.

*Relink behavior:* Unchanged — `linkToCurrentUser()` on sign-in continues to call `link-capture-device`, which sets `user_id` to the new user. No change needed here beyond ensuring it still runs at the same point in the sign-in flow.

*Pending relay ownership:* Add a new nullable column `processed_captures.claimed_user_id uuid` (additive migration). At INSERT time (in `process-ios-sms`), stamp it from `capture_devices.user_id` as it exists at that moment (NULL if the device is currently unlinked). Modify `sync-captures` to only return rows where `claimed_user_id = <the authenticated caller's user id>` **or** `claimed_user_id IS NULL` (unclaimed rows remain claimable by whoever syncs first, matching today's effectively-permissive behavior for the common single-user-per-device case, while closing the cross-user leak for the hand-off case). When an unclaimed row is synced by an authenticated user, `sync-captures` should also backfill `claimed_user_id` on that row to that user at the same time, so a *subsequent* device hand-off can no longer re-claim an already-claimed row.

*User A → sign-out → User B scenario, concretely:* A signs out → `unlink-capture-device` clears `capture_devices.user_id` to NULL (best-effort). Any capture arriving in the (now much narrower) window between A's sign-out and B's link either lands with `claimed_user_id = NULL` (if it arrives after the unlink completes) or `claimed_user_id = A` (if it arrives in the brief window before the unlink call completes, or if the unlink call failed while offline). B signs in, links the device (`user_id` now = B). B's `sync-captures` call only ever receives rows where `claimed_user_id` is NULL or already B — it can never receive a row stamped `claimed_user_id = A`. A, on a different device or next reconnecting session, can still sync their own `claimed_user_id = A` rows normally (this column doesn't change which device A eventually reads from if A signs in elsewhere — it only prevents *this specific device*, now controlled by B, from handing A's data to B).

*What happens to unacked captures:* They are never lost (per the "do not delete real data" constraint) — they remain in `processed_captures` exactly as today, just correctly gated by `claimed_user_id` so only the rightful owner's client can ever drain them via `sync-captures`. If A never returns to sync them from any device, they simply age out via the existing `run_prune_processed_captures` retention job like any other capture, same as today.

*How this avoids data loss and cross-user leakage:* Data loss is avoided because nothing is deleted or blocked from being written — the fix only changes *who is allowed to read* a given relay row. Cross-user leakage is avoided because a row's `claimed_user_id`, once set, is a permanent record of who captured it, independent of whatever the device's *current* linked user happens to be later.

**Alternative solutions considered:**
1. *Rotate `device_secret_hash` on every sign-out.* Rejected — would break the App Intent's ability to keep capturing (relay-only) while the Flutter app is signed out, which is a deliberate, desired capability (SMS keep arriving and get queued even before/between sign-ins).
2. *Delete unsynced `processed_captures` rows on sign-out.* Rejected outright — violates "do not delete real data" and would cause genuine data loss for a user who signs out and back in on the same device before ever opening the app to sync.
3. *Scope `sync-captures` by device only, unchanged, and rely solely on clearing `user_id` on sign-out to close the gap.* Rejected as insufficient on its own — it narrows the window but doesn't eliminate the specific hand-off race (capture arrives in the gap before unlink completes, or unlink fails offline); the `claimed_user_id` stamp is what makes the guarantee unconditional rather than best-effort.

**Why the chosen solution is safest:** It is purely additive (one nullable column, one new endpoint), preserves every existing capture that's ever been written, and turns a best-effort timing-dependent mitigation (clearing `user_id` promptly) into an unconditional guarantee (a row's owner is permanently recorded at the moment it's created, never inferred from mutable device state after the fact).

**Exact implementation steps:**
1. Migration: `alter table public.processed_captures add column claimed_user_id uuid null;` (no index needed yet at current scale; add one later if `sync-captures`' filter shows up in slow-query logs).
2. New Edge Function `unlink-capture-device/index.ts`, mirroring `link-capture-device`'s auth pattern but setting `user_id = null`.
3. `process-ios-sms/index.ts`: when inserting a `processed_captures` row, also set `claimed_user_id` from the device's current `user_id`.
4. `sync-captures/index.ts`: add the `claimed_user_id` filter (`.or('claimed_user_id.is.null,claimed_user_id.eq.' + callerUserId)`) and the backfill-on-claim update.
5. `app/lib/core/session/app_session.dart`: call the new unlink endpoint (best-effort, swallow errors) inside `signOut()`.
6. Regression tests (see below).

**Exact file-by-file change plan:**
| File | Change |
|---|---|
| `supabase/migrations/NNNN_processed_captures_claimed_user.sql` | Add `claimed_user_id` column |
| `supabase/rollback/NNNN_processed_captures_claimed_user_rollback.sql` | Drop the column |
| `supabase/functions/unlink-capture-device/index.ts` | New function |
| `supabase/functions/process-ios-sms/index.ts` | Stamp `claimed_user_id` at insert |
| `supabase/functions/sync-captures/index.ts` | Filter + backfill by `claimed_user_id` |
| `app/lib/core/session/app_session.dart` | Call unlink endpoint in `signOut()` |
| `app/lib/features/capture/services/capture_device_registration_service.dart` | Add the unlink-call helper method |

**Database migration requirements:** One additive column migration. REQUIRES LIVE MIGRATION APPROVAL.

**Rollback plan:** Drop the column (rollback file). `sync-captures` and `process-ios-sms` must be redeployed to their pre-change versions *before or atomically with* the column drop (deploying the column drop while the new code still references `claimed_user_id` would break the function) — sequence: redeploy old function code first, confirm healthy, then drop the column.

**Data migration/backfill requirements:** Existing unclaimed rows (created before this ships) get `claimed_user_id = NULL` by default, which is the correct "unclaimed, claimable by whoever syncs first" state — no backfill needed, the default is already safe.

**Security implications:** Closes a real cross-user data exposure vector on shared/handed-down devices. `unlink-capture-device` uses the same device-credential auth as every other capture endpoint — no new auth surface introduced.

**RLS implications:** None — `processed_captures` RLS remains `false`/service-role-only.

**Auth/session implications:** Sign-out gains one best-effort network call; must not block or delay the sign-out UX (fire-and-forget with a short timeout, matching the pattern already used for other best-effort background calls in `app_shell.dart`).

**Offline implications:** If sign-out happens fully offline, the unlink call fails silently — acceptable, since the *next* sign-in's `link-capture-device` call still correctly overwrites `user_id`, and the `claimed_user_id` stamping (the real guarantee) is independent of whether the unlink call ever succeeds.

**Notification implications:** None.

**Performance implications:** One additional filter clause on `sync-captures`' existing query — negligible at current or 10k-user scale.

**Compatibility risks:** None — additive column, existing rows default to the safe (unclaimed) state.

**Test plan:** Integration test simulating: device linked to A → A signs out (unlink call) → capture arrives (should stamp `NULL` or `A` depending on timing) → B links → B calls `sync-captures` → assert B never receives any row stamped `claimed_user_id = A`.

**Regression tests required:** The hand-off scenario above is a race-adjacent correctness test (required given the security-adjacent nature) — include both an "unlink completes before capture arrives" and "capture arrives before unlink completes" ordering to prove both are safe.

**Manual iPhone tests required:** MANUAL QA REQUIRED — sign in as User A on a real device, capture one SMS, sign out before syncing, sign in as User B, open the app, confirm B never sees A's transaction appear anywhere in B's account.

**Acceptance criteria:** No `sync-captures` response for User B ever includes a row whose `claimed_user_id` is a different, non-null user id.

**Definition of done:** Migration applied and verified; new function deployed; existing `process-ios-sms`/`sync-captures` redeployed with the stamping/filtering logic; hand-off regression test passing; manual iPhone test performed and documented.

**Dependencies on other findings:** None blocking; should land before #10 (capture health monitoring) so health signals aren't confused by cross-user relay noise.

**Recommended commit grouping:** Single PR covering the migration, the new function, and the two modified functions together (they're only meaningful as a unit).

**Stop conditions and rollback triggers:** If the `claimed_user_id` filter in `sync-captures` is found to ever withhold a user's *own* legitimate captures (e.g., a bug in the filter logic), stop immediately and roll back the function deploy — a false-negative here (data withheld from its rightful owner) is a regression on top of the fix and must not ship.

---

### Finding #4 — SMS can be silently lost forever if iOS kills the Shortcut extension mid-request

**Severity:** High · **Status:** READY TO IMPLEMENT

**Exact root cause:** `BankMessageShortcuts.swift`'s `perform()` only writes to `SharedCaptureStore` *after* the network call throws or completes — nothing is persisted before the `await` on the network request begins. If iOS terminates the extension process during that window (background App Intent execution budgets are short and not guaranteed to complete an 8-second request), the SMS is gone with no trace anywhere.

**Current behavior:** A weak-signal environment (elevator, basement, rural area, poor roaming) can cause the network request to still be in flight when the OS kills the extension — the transaction is silently never captured, with zero persistence and zero user-visible signal.

**Expected behavior:** The capture payload is durably persisted to the App Group store *before* the network attempt begins, under all circumstances, so that a hard process kill at any point after that write leaves a recoverable, retryable entry rather than nothing at all.

**Affected files:** `app/ios/BankMessageShortcuts/BankMessageShortcuts.swift`, `app/ios/BankMessageShortcuts/SharedCaptureStore.swift` (and its two byte-identical copies in `Runner/` and `ShareBankMessage/` — all three must change together and remain byte-identical, per the established project convention), `app/lib/features/capture/services/capture_sync_service.dart` (drain/retry logic, to handle the new `pendingSend` state)

**Affected database tables/functions/RPCs:** None — this fix is entirely client-side and relies on the already-existing server-side `payload_id` idempotent-replay handling in `process-ios-sms` (no server change needed).

**Affected feature flags:** None.

**Proposed technical solution:**

*Persist-before-network algorithm:*
1. On `perform()` entry, construct the complete capture payload immediately — `payloadId` (minted once, here, and never regenerated for this logical capture), `sanitizedText`, `sender`, `receivedAt`, and anything else needed to fully resubmit later.
2. Synchronously write this payload into `SharedCaptureStore` in a new `pendingSend` state, *before* constructing or awaiting the network request.
3. Only then attempt the network call.
4. On success: transition/remove the entry to a `sent` terminal state (mirrors existing cleanup).
5. On a normal thrown error (not a hard kill): existing fallback behavior already applies — the entry (now already present from step 2, rather than freshly added here) is left for the host app to drain.
6. On a hard OS kill: nothing else needs to happen in Swift, because step 2 already made the entry durable — recovery is entirely a *reader's* problem, not a *writer's* problem.

*Queue state machine:* `pendingSend` (persisted, network attempt not yet confirmed) → `sent` (terminal, safe to remove/ignore) . An entry found still in `pendingSend` by any later reader (a subsequent Shortcut invocation, or the host app on next launch) is treated as "attempt may have been interrupted" and is eligible for resubmission.

*Ack semantics:* An entry only ever leaves `pendingSend` on a **positive, definitive** response — either the extension's own call returns success, or a later host-app-driven retry gets a definitive terminal response (success *or* a "duplicate/already processed" response — both are safe terminal states given `payload_id` idempotency).

*Crash/kill recovery:* Automatic and free, given the design above — recovery is simply "the next reader of `SharedCaptureStore` finds a `pendingSend` entry and resubmits it."

*Retry semantics:* Retries **must** reuse the exact same `payloadId` minted in step 1 — never mint a fresh one for a retry. This is the crux of the whole fix: durability plus a stable idempotency key means retries (however many, however delayed) can never create a duplicate transaction, because `process-ios-sms` already handles replayed `payload_id`s correctly (built and tested earlier this session). The entire fix is client-side; no new server logic is required.

*Duplicate prevention:* Fully covered by stable-`payloadId` reuse plus the existing server-side idempotent-replay path — no new duplicate-prevention logic needed anywhere.

**Alternative solutions considered:**
1. *Reduce the network timeout further to "outrun" the OS kill.* Rejected — doesn't address the actual failure mode (the OS can kill the process at any point, not just after a fixed timeout) and would make genuinely slow-but-eventually-successful requests fail unnecessarily.
2. *Use a background URLSession that survives process termination.* Considered, but background `URLSession` configurations are designed for large transfers resuming later via a system-delivered callback, and integrating that with an App Intent's short-lived execution model adds significant complexity for a problem the simple persist-first approach already fully solves given the existing idempotent server. Rejected as disproportionate.

**Why the chosen solution is safest:** It requires no new server-side logic (reusing already-tested idempotent replay), no new external dependency (no background URLSession complexity), and reduces to a single ordering change (persist, then network) plus one new intermediate state in an already-existing store — the smallest possible change that fully closes the gap.

**Exact implementation steps:**
1. In `SharedCaptureStore.swift` (and its two other copies, kept byte-identical), add a `pendingSend` status alongside whatever states already exist for the queued-fallback entries.
2. In `BankMessageShortcuts.swift`'s `perform()`, move the "construct payload + persist" step to before the network call, tagging it `pendingSend`.
3. On network success, transition the entry to `sent`/remove it (reuse existing cleanup call).
4. In `capture_sync_service.dart`, extend the host-drain logic to also resubmit any `pendingSend` entries found on launch (in addition to whatever it already drains), using the entry's stored `payloadId` unchanged.
5. Verify byte-identity of all three `SharedCaptureStore.swift` copies after the change (`md5` check, same method used earlier this session).

**Exact file-by-file change plan:**
| File | Change |
|---|---|
| `app/ios/BankMessageShortcuts/SharedCaptureStore.swift` | Add `pendingSend` state |
| `app/ios/Runner/SharedCaptureStore.swift` | Identical change (byte-for-byte) |
| `app/ios/ShareBankMessage/SharedCaptureStore.swift` | Identical change (byte-for-byte) |
| `app/ios/BankMessageShortcuts/BankMessageShortcuts.swift` | Persist-before-network reorder in `perform()` |
| `app/lib/features/capture/services/capture_sync_service.dart` | Drain `pendingSend` entries alongside existing queued entries |

**Database migration requirements:** None.

**Rollback plan:** Revert the Swift changes (App Store / Sideloadly rebuild required — this is a native binary, not an Edge Function; rollback requires shipping a new build, there is no server-side toggle for this one). Given that constraint, this finding should go through extra manual QA before release, since rollback is slow.

**Data migration/backfill requirements:** None.

**Security implications:** None.

**RLS implications:** None.

**Auth/session implications:** None.

**Offline implications:** This finding is specifically about the offline/weak-signal case — that is the entire point of the fix.

**Notification implications:** A message recovered via retry after an interrupted extension still produces exactly one notification (governed by existing notify-only-if-stored logic, unaffected by this change).

**Performance implications:** One additional synchronous local write per capture (before the network call) — negligible, App Group `UserDefaults` writes are fast.

**Compatibility risks:** None for the server. All risk is in getting the Swift state machine right, hence the emphasis on a Swift unit test plus manual iPhone verification below.

**Test plan:** Swift unit test: inject a network client that never resolves (simulating an in-flight request), call the capture-initiating function, and assert `SharedCaptureStore` already contains a `pendingSend` entry with the correct `payloadId` *before* the network call would ever return — proving the persist happens first, not as a side effect of failure handling.

**Regression tests required:** The unit test above (deterministic, no timing dependency — it substitutes a never-resolving mock rather than trying to race a real OS kill).

**Manual iPhone tests required:** MANUAL QA REQUIRED — (a) enable Airplane Mode immediately after triggering the Shortcuts automation, wait, disable Airplane Mode, relaunch Mali, confirm the transaction eventually appears exactly once; (b) force-quit the Shortcuts app/extension via the App Switcher immediately after triggering the automation (best-effort approximation of an OS kill, since a true kill can't be manually forced), then relaunch Mali and confirm recovery.

**Acceptance criteria:** A capture interrupted by a simulated network failure or forced quit is never permanently lost — it appears in the ledger exactly once after connectivity/relaunch, with no duplicate.

**Definition of done:** Swift unit test passing, all three `SharedCaptureStore.swift` copies confirmed byte-identical post-change, both manual iPhone scenarios performed and documented, `xcodebuild` for both `Runner` and `BankMessageShortcuts` schemes green.

**Dependencies on other findings:** None, but shares files with #12 (atomic local capture queue) — recommend bundling in the same PR since both touch `SharedCaptureStore.swift`.

**Recommended commit grouping:** Bundle with #12 (same file family, avoids two separate native-rebuild QA cycles).

**Stop conditions and rollback triggers:** If manual QA shows any scenario where a `pendingSend` entry is never drained (stuck forever), stop and fix before release — a stuck-forever entry is worse than today's silent loss in one respect (it would eventually surface as a very late, confusing transaction) though still strictly better than permanent loss; treat any stuck-entry finding as blocking, not a follow-up.

---

### Finding #5 — Onboarding "start fresh" skips mandatory setup steps

**Severity:** High · **Status:** READY TO IMPLEMENT

**Exact root cause:** `restore_prompt_screen.dart` calls `finishOnboarding()` directly from both its "restore from backup" and "start fresh" button handlers, bypassing `setup_screen.dart`'s country/currency/account/capture-guide sequence entirely for both paths.

**Current behavior:** A new user who taps "start fresh" is dropped straight to the dashboard having never seen country/currency selection or the Shortcuts capture setup guide — a straight-line reachable path, not an edge case.

**Expected behavior:**
- *Exact required sequence for a genuinely new user (no restore chosen):* auth → country/currency selection → account setup → capture (Shortcuts) setup guide → `finishOnboarding()` → dashboard.
- *Returning-user behavior:* unaffected — a user whose account already has `_onboardingDone == true` skips straight to dashboard on sign-in, as today.
- *Restore path:* after a successful restore, country/currency/account setup should be **skipped** (the backup already contains this data — re-showing it would be redundant and confusing), but the user should still be routed through the capture (Shortcuts) setup guide, since that is a **device-level** configuration that a data restore cannot carry over to a new physical device.
- *Start-fresh path:* must go through the **full** `setup_screen.dart` sequence exactly as a user who never saw the restore prompt at all — country/currency → account → capture guide → `finishOnboarding()`.

**Affected files:** `app/lib/features/onboarding/restore_prompt_screen.dart`, `app/lib/features/onboarding/setup_screen.dart` (needs to support being entered "mid-way," at just the capture-guide step, for the restore branch), `app/lib/core/router/app_router.dart` (verify no change needed — see below)

**Affected database tables/functions/RPCs:** None.

**Affected feature flags:** None.

**Proposed technical solution:** Change `restore_prompt_screen.dart`'s two button handlers:
- "Start fresh": instead of calling `finishOnboarding()`, navigate forward into `setup_screen.dart`'s normal entry point (full sequence). `finishOnboarding()` is only ever called from the true end of that flow, never from the restore prompt directly.
- "Restore from backup": after the restore itself completes successfully, navigate into `setup_screen.dart` with a new parameter/mode indicating "skip to capture guide only" (add a constructor parameter, e.g. `startAtStep: SetupStep.captureGuide`, defaulting to the first step for the normal entry point) — then `finishOnboarding()` is called at the same single place at the end of that screen's flow for both branches.

**Alternative solutions considered:**
1. *Duplicate the capture-guide UI directly inside `restore_prompt_screen.dart` instead of routing into `setup_screen.dart`.* Rejected — duplicates UI and logic that already exists and is already tested; routing with a "start at step N" parameter is a smaller, safer change.
2. *Force full re-onboarding (including country/currency) even on the restore path.* Rejected — actively bad UX (redundant with restored data) and not what the finding asks for; the fix must be precise about which steps apply to which path.

**Why the chosen solution is safest:** `finishOnboarding()` ends up called from exactly one place (`setup_screen.dart`'s terminal step) for both the fresh-start and restore branches, eliminating the class of bug entirely (a future third entry point can't reintroduce this by accident, since there's only one legitimate "done" call site left to call).

**Exact implementation steps:**
1. Add a `startAtStep` parameter to `setup_screen.dart` (default: first step, i.e. today's behavior for the normal signup path is unaffected).
2. Change `restore_prompt_screen.dart`'s "start fresh" handler to navigate to `setup_screen.dart` with default (first) step.
3. Change the "restore from backup" handler to, after restore success, navigate to `setup_screen.dart` with `startAtStep` set to the capture-guide step.
4. Remove both direct `finishOnboarding()` calls from `restore_prompt_screen.dart`.
5. Confirm `app_router.dart`'s redirect logic needs no change (it keys off `_onboardingDone`, which is now only ever set from the one remaining call site — verify by reading the redirect logic, no code change expected here, just confirmation).

**Exact file-by-file change plan:**
| File | Change |
|---|---|
| `app/lib/features/onboarding/setup_screen.dart` | Add `startAtStep` parameter, honor it in initial state |
| `app/lib/features/onboarding/restore_prompt_screen.dart` | Both handlers route into `setup_screen.dart` instead of calling `finishOnboarding()` directly |

**Database migration requirements:** None.

**Rollback plan:** Revert the Flutter changes; no data/schema impact.

**Data migration/backfill requirements:** None — this only affects the flow for users onboarding *after* the fix ships; already-onboarded users are unaffected.

**Security implications:** None.

**RLS implications:** None.

**Auth/session implications:** None — `_onboardingDone`/`_completedAccountKeys` semantics in `app_session.dart` are unchanged, only *when* they get set changes.

**Offline implications:** None beyond what `setup_screen.dart` already handles today.

**Notification implications:** None.

**Performance implications:** None.

**Compatibility risks:** None for existing onboarded users. New users onboarding via "start fresh" will now see 2-3 additional screens they previously skipped — this is the intended fix, not a regression, but note it for release-notes/support-team awareness since support may get "why do I see more setup screens now" questions if anyone compares notes with an earlier tester.

**Test plan:** Widget test: tapping "start fresh" navigates to `setup_screen.dart` at its first step (not directly to dashboard); tapping "restore from backup" and completing a restore navigates to `setup_screen.dart` at the capture-guide step; completing `setup_screen.dart` from either entry point calls `finishOnboarding()` exactly once.

**Regression tests required:** Existing onboarding tests (force-quit-before-finish, returning-user skip) must still pass unchanged — re-run the full onboarding test suite, not just new tests, since this touches shared router/session logic.

**Manual iPhone tests required:** MANUAL QA REQUIRED — walk both the "start fresh" and "restore from backup" paths end to end on a real device/simulator and confirm the exact expected screens appear in the exact expected order for each.

**Acceptance criteria:** No path exists that reaches the dashboard without either (a) being a returning user, or (b) having passed through country/currency/account setup at least once, or (c) having passed through the capture guide at least once (restore path).

**Definition of done:** Widget tests passing, manual walkthrough of both paths performed and documented, `flutter analyze`/`flutter test` clean.

**Dependencies on other findings:** None.

**Recommended commit grouping:** Single PR, onboarding files only.

**Stop conditions and rollback triggers:** If the widget tests reveal the restore path's "skip to capture guide" entry breaks any state `setup_screen.dart` assumes is already initialized by its earlier steps (e.g., a null currency reference), stop and add the missing null-safety/defaults before shipping — do not ship a fix that trades "skips setup" for "crashes on restore."

---

### Finding #6 — Account creation/deletion has the weakest error handling of any write path

**Severity:** High · **Status:** READY TO IMPLEMENT

**Exact root cause:** `accounts_screen.dart`'s account form has no busy-state guard around its save/delete actions and only catches `on RepoException` — any other exception type propagates unhandled. This is purely a client-side UX/robustness gap (the server-side atomic hardening for the specific last-account-deletion race is deliberately scoped separately, as Batch 2 finding #15, so this finding is scoped to busy-state, duplicate-submit prevention, generic error handling, and UI-state restoration only).

**Current behavior:** A slow network invites duplicate account creation (button stays tappable through the whole await) or a confusing stuck state on delete; any unexpected exception type crashes or silently does nothing with no user feedback.

**Expected behavior:** The save/delete button is disabled (ideally with a visible spinner) for the duration of the network call; a retried tap while busy is a no-op; any exception (not just `RepoException`) shows a generic, friendly error and leaves the form populated with the user's entered values for retry.

**Affected files:** `app/lib/features/settings/accounts_screen.dart` (or wherever `_AccountForm` lives — confirm exact path; this session's earlier research referenced it as the accounts management screen at route `/accounts`)

**Affected database tables/functions/RPCs:** None for this finding specifically (the create-account idempotency-key reuse recommendation below touches `user_accounts.local_id`'s existing unique index, no schema change).

**Affected feature flags:** None.

**Proposed technical solution:**
1. Add a `bool _busy` field to the form's `State`, set via `setState` at the start of save/delete and cleared via `setState` in a `finally` block regardless of outcome.
2. Guard the save/delete method's entry: `if (_busy) return;`.
3. Disable (and visually indicate, e.g., a small inline spinner replacing the button's label) the submit/delete control while `_busy == true`.
4. Change the catch clause from `on RepoException catch (e)` to also include a trailing generic `catch (e)` branch showing a generic Arabic error message, so no exception type is ever silently swallowed or left unhandled.
5. Ensure the `TextEditingController`s backing the form fields are never cleared on error — only on confirmed success — so a failed save leaves the user's input exactly as they typed it, ready to retry.
6. For account **creation** specifically: confirm (or add, if missing) that the client generates a stable `local_id` once per creation attempt and reuses the same value on any retry within that attempt's lifetime, so a retried create-after-timeout naturally resolves against the existing `idx_user_accounts_user_local` unique index (already present in the schema) rather than creating a second account.

**Alternative solutions considered:**
1. *Optimistic UI (show the account immediately, reconcile in the background).* Rejected for this finding — adds complexity disproportionate to the actual bug (missing busy-state guard), and the app's established pattern elsewhere (budget/goal forms, which are already "clean" per the QA report) is exactly the simple busy-state-guard pattern being applied here; consistency with existing good examples is preferred over introducing a new pattern.

**Why the chosen solution is safest:** It matches the pattern already proven correct elsewhere in the same codebase (`budget_form_screen.dart`, `goal_form_screen.dart`, both audited and found clean) rather than inventing a new approach — the fix is "bring this screen up to the standard the rest of the app already meets."

**Exact implementation steps:**
1. Add `_busy` state field + `setState` wiring around save and delete.
2. Add the generic `catch (e)` fallback branch.
3. Confirm/add stable `local_id` generation-once-per-attempt for creation.
4. Add widget tests for double-tap prevention and generic-error display.

**Exact file-by-file change plan:**
| File | Change |
|---|---|
| `app/lib/features/settings/accounts_screen.dart` | `_busy` field, guarded save/delete, generic catch, stable `local_id` reuse on retry |

**Database migration requirements:** None.

**Rollback plan:** Revert the Flutter change; no data impact.

**Data migration/backfill requirements:** None.

**Security implications:** None.

**RLS implications:** None.

**Auth/session implications:** None.

**Offline implications:** A save attempted while offline now shows a clear, generic error (instead of possibly hanging or silently failing) and leaves the form populated for retry once connectivity returns.

**Notification implications:** None.

**Performance implications:** None.

**Compatibility risks:** None.

**Test plan:** Widget tests: rapid double-tap on save while a slow (delayed-completion) fake repository is in flight results in exactly one create call; an injected non-`RepoException` error (e.g. a plain `Exception`) results in a visible generic error message, not a crash or silent no-op; form field values survive a failed save.

**Regression tests required:** The double-tap and generic-exception tests above.

**Manual iPhone tests required:** MANUAL QA REQUIRED — throttle network (Xcode Network Link Conditioner or equivalent) and confirm the button visibly disables during a slow save, and that a forced failure shows a clear error with the form still populated.

**Acceptance criteria:** No code path in this screen can create two accounts from one logical user action, and no exception type reaches the user as a silent failure or a crash.

**Definition of done:** Widget tests passing, manual throttled-network test performed and documented.

**Dependencies on other findings:** Precedes #15 (server-side atomic last-account-deletion RPC) — this client-side fix ships first and already substantially narrows that race; #15 closes it completely.

**Recommended commit grouping:** Single PR, this screen only.

**Stop conditions and rollback triggers:** None specific — this is a low-risk, additive UX hardening change.

---

### Finding #7 — Bill-payment recording has no progress feedback and pops before the network call runs

**Severity:** High · **Status:** READY TO IMPLEMENT

**Exact root cause:** `bill_details_sheet.dart`'s record-payment dialog calls `Navigator.pop()` before the actual network calls execute, and shows no busy/spinner state for the multi-second duration of those calls; `bill_form_sheet.dart`'s two-phase write (save bill, then record payment) has no `finally` block resetting its busy flag and no stable, retry-safe request identifiers generated up front.

**Current behavior:** A user on a slow connection taps "record payment," sees the dialog close immediately with no further feedback, and — reasonably assuming the tap didn't register — is likely to retry, risking a duplicate payment/transaction (each retry today would mint a fresh `IdGenerator.next()` id rather than reusing one).

**Expected behavior:** The dialog remains open (with a visible busy/spinner state, controls disabled) for the duration of the network call(s) and only closes on a definitive success or a handled, retryable failure; any retry of the same logical "save" action reuses the same `client_request_id`(s) minted on the first attempt, so a retry after partial failure can never create a duplicate payment or duplicate bill row.

**Affected files:** `app/lib/features/subscriptions/bill_details_sheet.dart`, `app/lib/features/subscriptions/bill_form_sheet.dart`

**Affected database tables/functions/RPCs:** `record_bill_payment` RPC (no change — already does `on conflict (user_id, client_request_id) do nothing` + fetch-existing fallback, confirmed earlier this session; the fix here is entirely about the *client* consistently reusing one `client_request_id` per logical attempt).

**Affected feature flags:** None.

**Proposed technical solution:**
1. **Stable `client_request_id`:** generate the bill's own identifier and the payment's `client_request_id` **once**, at the moment the user opens the save/record-payment flow, and store them in the widget's `State` — reuse the exact same values on every retry within that same sheet's lifetime (never regenerate per tap).
2. **Progress state:** add a busy flag to both `bill_form_sheet.dart` and the record-payment dialog in `bill_details_sheet.dart`; disable the relevant buttons and show a spinner while busy.
3. **Dialog lifecycle:** restructure `_showRecordPayment` so `Navigator.pop()` is only called *after* the network call(s) resolve successfully — on failure, keep the dialog open with an inline error and a retry affordance (reusing the same stable `client_request_id` from step 1).
4. **Partial success handling:** if the bill-save call succeeds but the payment-record call fails, update the error copy shown to the user to something like "تم حفظ الفاتورة، لكن فشل تسجيل الدفعة — أعد المحاولة" (bill saved, but recording the payment failed — please retry) rather than the current generic "an unexpected error occurred while saving," which incorrectly implies nothing was saved. Because the bill-save id is also stable/reused (step 1), retrying safely no-ops the already-succeeded bill-save (upsert) and only actually performs the still-missing payment-record call.
5. **Duplicate prevention:** fully covered by 1 + the existing RPC's `on conflict do nothing` behavior — no new server logic needed.

**Alternative solutions considered:** Collapsing the two-phase write (bill-save, then payment-record) into a single RPC call is the more thorough fix, but is deliberately deferred to Batch 3 (#20) — this finding (#7) is scoped to the UI-level mitigation that can ship immediately and safely with no server change, given the existing RPC is already idempotent; #20 is the deeper "make the two operations atomic at the source" upgrade once #7 has already stopped user-facing duplicates.

**Why the chosen solution is safest:** It changes only client-side sequencing and error copy, relying entirely on an already-tested, already-idempotent server RPC — no server deploy is required for this finding, minimizing risk and allowing it to ship fast as a release blocker.

**Exact implementation steps:**
1. In `bill_form_sheet.dart`: generate stable ids in `initState`/on first build, add busy flag with `finally`-guarded reset, update error copy for the partial-failure case.
2. In `bill_details_sheet.dart`: restructure `_showRecordPayment` to keep the dialog open during the network call, add busy/spinner state, move `Navigator.pop()` to after success.
3. Add widget tests for: stable id reuse across a simulated retry, dialog-stays-open-during-await, correct partial-failure copy shown.

**Exact file-by-file change plan:**
| File | Change |
|---|---|
| `app/lib/features/subscriptions/bill_form_sheet.dart` | Stable ids, busy flag + finally, partial-failure copy |
| `app/lib/features/subscriptions/bill_details_sheet.dart` | Dialog lifecycle reorder, busy/spinner state |

**Database migration requirements:** None.

**Rollback plan:** Revert the Flutter changes; no data impact (the RPC is unchanged).

**Data migration/backfill requirements:** None.

**Security implications:** None.

**RLS implications:** None.

**Auth/session implications:** None.

**Offline implications:** A save attempted offline now shows a clear, retryable error state instead of a dialog that silently closed with no feedback.

**Notification implications:** None.

**Performance implications:** None.

**Compatibility risks:** None.

**Test plan:** Widget tests per implementation steps above; also a test confirming a simulated double-tap on "record payment" (fast, back-to-back) results in exactly one `record_bill_payment` call being made (or, if two calls are made due to a genuine double network request, that both carry the identical `client_request_id` so the server-side conflict-handling still results in exactly one row).

**Regression tests required:** The stable-id-reuse test is the key regression test here (prevents backsliding into "fresh id per tap").

**Manual iPhone tests required:** MANUAL QA REQUIRED — throttle network, record a bill payment, confirm the dialog visibly stays open with a spinner and only closes on success; force a failure (e.g., airplane mode mid-save) and confirm the retry affordance works without creating a duplicate.

**Acceptance criteria:** No sequence of taps/retries on this screen can ever produce two `user_bill_payments` rows for one logical payment.

**Definition of done:** Widget tests passing, manual throttled/failure test performed and documented.

**Dependencies on other findings:** Precedes #20 (two-phase → single-RPC consistency upgrade in Batch 3).

**Recommended commit grouping:** Single PR, both bill screens together (they're two halves of the same user flow).

**Stop conditions and rollback triggers:** None specific — additive UX hardening, no server change.

---

### Finding #8 — No architecture exists for user deletion / data retention

**Severity:** High (compliance exposure) · **Status:** BLOCKED BY PRODUCT DECISION (policy parameters) — schema/worker scaffolding is READY TO IMPLEMENT independently

**Exact root cause:** Confirmed via direct query this session: **zero foreign key exists from any `user_id` column to `auth.users`**, and **zero code anywhere** (grepped `app/`, `admin/`, `supabase/functions/`) acts on the existing-but-unused `profiles.delete_scheduled_at` column. If a user is ever deleted from `auth.users` by any means, every row they own across every `user_*` table remains forever, orphaned and unreachable through the app but still present in the database.

**Current behavior:** There is no way to fulfill a "delete my account" request today beyond removing the `auth.users` row itself (and it is not yet confirmed whether even a user-facing "delete my account" action exists anywhere in the app — this must be confirmed as a prerequisite scoping question before implementation, see below). Financial data, once orphaned, persists indefinitely.

**Expected behavior:** A user-initiated deletion request results in (a) immediate session invalidation, (b) a grace period during which the request can be cancelled, (c) at the end of the grace period, complete and permanent removal of all of that user's data across every table, their Storage backup blob, and their `auth.users` row itself.

**Affected files:** New: a scheduled Edge Function (e.g. `purge-deleted-users/index.ts`); possibly a new "delete my account" UI flow if one does not already exist (**scoping question for Codex to confirm before implementation — grep the app for any existing delete-account entry point; if none exists, building that UI is a separate, larger scope than just the backend purge worker, and should be raised back to the product owner explicitly rather than assumed**).

**Affected database tables/functions/RPCs:** New `SECURITY DEFINER` function `purge_user_data(p_user_id uuid)`; a new pg_cron schedule invoking the purge worker; every `user_*` table (as the target of the purge); `profiles.delete_scheduled_at` (already exists, currently unused — becomes load-bearing).

**Affected feature flags:** None required for the worker itself, but consider gating the *user-facing* "delete my account" entry point (if newly built) behind a flag for a controlled rollout, consistent with how every other new user-facing capability in this app has shipped.

**Proposed retention policy options (for product-owner decision):**
- (a) *Immediate hard delete on request.* Simplest, most privacy-forward, but no recovery window for accidental requests or support disputes.
- (b) *Grace-period soft delete + scheduled hard purge (recommended default).* Set `delete_scheduled_at` at request time; do not delete immediately; a scheduled worker hard-deletes everything once the grace period elapses; the user can cancel during the window by clearing `delete_scheduled_at`.
- (c) *Anonymization instead of deletion.* Not recommended as the default — in a personal-finance app, the amounts/merchants/dates *are* the sensitive data, not just a name/email field; anonymizing would strip little real risk while retaining none of the analytical value anonymization is usually meant to preserve. Hard delete is cleaner and more legally defensible.

**Recommended default:** (b), with a 30-day grace period as a starting proposal — **BLOCKED BY PRODUCT DECISION** for the final grace-period length, whether cancellation is offered (recommended: yes), and confirmation of (b) over (a)/(c) generally, plus which legal jurisdictions Mali must comply with (affects whether 30 days is acceptable, too long, or needs to be shorter).

**Database cascade/scheduled-worker approach:** Since no FK/cascade exists to rely on, the purge must be an explicit, ordered sequence of deletes, child tables before parent tables:
```
1. user_bill_payments, user_goal_contributions, user_plan_transaction_links
2. user_subscriptions, user_goals, user_plans
3. user_budgets, user_transactions
4. user_accounts
5. user_smart_inbox
6. sender_bank_mappings
7. capture_devices (and, via its own cascade, capture_fingerprints) — matched by user_id
8. profiles
9. Storage: delete the user's backup blob (backups.blob_path) via the Storage API —
   this cannot be done from pure SQL, requires a Storage API call
10. auth.users row — via the Admin API (auth.admin.deleteUser()), not raw SQL
```
Because steps 9-10 require the Storage API and the Auth Admin API respectively (not reachable from a pure Postgres function), the worker itself should be implemented as a **scheduled Edge Function** invoked by pg_cron (the same `pg_net`-triggered pattern already used for `run_prune_processed_captures`), which performs the SQL deletes (1-8, wrapped in the new `purge_user_data` SQL function for atomicity) and then makes the Storage and Admin API calls in the same invocation.

**Deletion grace period:** 30 days proposed — BLOCKED BY PRODUCT DECISION for final number.

**Anonymization vs hard delete:** Hard delete recommended — BLOCKED BY PRODUCT DECISION for final confirmation.

**Backups/storage cleanup:** Included in the worker design (step 9 above).

**Legal/privacy risks:** Until this ships, Mali cannot fulfill a data-erasure request at all. If Mali serves users in any jurisdiction with a legal right-to-erasure requirement, this is a compliance gap independent of its QA severity ranking — flagging explicitly for product/legal awareness, not just as a technical backlog item.

**What requires product-owner approval before implementation:** grace-period length; hard-delete vs. anonymize vs. immediate; whether a user-facing "delete my account" flow exists yet or needs to be built from scratch as a prerequisite; applicable legal jurisdictions.

**Alternative solutions considered:** Relying on a manual, ad-hoc SQL script run by an engineer whenever a deletion request arrives. Rejected — does not scale past a handful of users, is error-prone (easy to miss a table), and leaves no audit trail of what was deleted and when; a scheduled worker with a fixed table list is safer and auditable.

**Why the chosen solution is safest:** It is additive (new function, new scheduled job, no changes to existing tables' shape), reversible during the grace period (cancellation), and reuses the exact scheduling mechanism (pg_cron + Edge Function) already proven in production for `run_prune_processed_captures`.

**Exact implementation steps (schema/worker scaffolding only — do not wire the actual grace-period trigger UI until policy is confirmed):**
1. Write `purge_user_data(p_user_id uuid)` SQL function performing the ordered deletes above (SQL, additive — new function only).
2. Write the scheduled Edge Function that finds `profiles` where `delete_scheduled_at < now()`, calls the SQL function, then performs the Storage blob removal and Admin API user deletion.
3. Register the pg_cron schedule (matching the existing daily-schedule pattern).
4. Do **not** build or wire up the user-facing "request deletion" entry point until the product decision lands — implement it as a separate, explicitly-scoped follow-up once grace period/policy is confirmed.

**Exact file-by-file change plan:**
| File | Change |
|---|---|
| `supabase/migrations/NNNN_purge_user_data_function.sql` | New `purge_user_data()` SQL function |
| `supabase/rollback/NNNN_purge_user_data_function_rollback.sql` | Drop the function |
| `supabase/functions/purge-deleted-users/index.ts` | New scheduled worker |
| (Future, blocked) `app/lib/features/settings/...` | "Delete my account" entry point — not in this pass |

**Database migration requirements:** One additive function-only migration for the scaffolding. REQUIRES LIVE MIGRATION APPROVAL for the function itself; the pg_cron schedule registration is a separate, explicit approval step since it begins actually running against real data on a timer.

**Rollback plan:** Drop the function; unregister the pg_cron schedule. No data is deleted by the scaffolding alone (it only runs against rows where `delete_scheduled_at` is already set, which nothing currently sets, since no UI exists yet to set it) — the scaffolding is inert until the user-facing trigger is built.

**Data migration/backfill requirements:** None.

**Security implications:** The purge function is `SECURITY DEFINER` and must be tightly scoped — grant `execute` only to the service role, never to `authenticated`/`anon`.

**RLS implications:** None changed; the purge function operates with elevated privilege by design (it must delete across all users' data structurally, though in practice always scoped to one `p_user_id` per invocation).

**Auth/session implications:** Session invalidation on deletion request (once the UI exists) should happen immediately, independent of the grace period, so a "deleted" account cannot keep being used while data removal is pending.

**Offline implications:** None for the worker (server-side only).

**Notification implications:** Consider (product decision, not engineering) whether to notify the user by email at grace-period start and again shortly before permanent deletion — out of scope for this engineering pass, flagged for product awareness.

**Performance implications:** Negligible — this runs on a daily schedule against what should be a very small number of pending-deletion rows at any given time.

**Compatibility risks:** None — purely additive, inert until wired to a UI trigger.

**Test plan:** SQL function test: seed a throwaway QA user (same Admin-API pattern used throughout this session) with rows across every affected table, invoke `purge_user_data`, assert zero rows remain in every table for that user, and assert other users' rows are completely untouched.

**Regression tests required:** The cross-user-untouched assertion above is the critical regression test — a purge bug that deletes the wrong user's data would be catastrophic; test it explicitly, not just "the target user is gone."

**Manual iPhone tests required:** None for the worker itself (server-side); MANUAL QA REQUIRED once the user-facing deletion-request UI is eventually built (out of scope for this pass).

**Acceptance criteria (for the scaffolding only):** `purge_user_data` correctly and completely removes one user's data across every listed table with zero impact on any other user's data, verified against a real throwaway QA account, cleaned up afterward per this session's established QA-data-hygiene practice.

**Definition of done (for the scaffolding only):** Function migrated, scheduled worker deployed but **not yet reachable by any user action** (no UI wired), cross-user-safety test passing and documented, pg_cron schedule registered and confirmed active.

**Dependencies on other findings:** None technically, but the user-facing trigger (out of scope here) depends on the product decision landing first.

**Recommended commit grouping:** Single PR for the SQL function + scheduled worker, explicitly labeled in the PR description as "scaffolding only, inert until a deletion-request UI is built and product policy is confirmed."

**Stop conditions and rollback triggers:** Do not wire any user-facing "request deletion" button to this worker until the product decision on grace period and hard-delete-vs-anonymize is explicitly confirmed in writing — this is a hard stop, not a suggestion, given the irreversibility of the eventual purge.

---

## 5. Batch 2 Implementation Outline — Data Correctness

### #9 — Hardcoded Riyadh UTC+3 offset
**Severity:** Critical (data-correctness) · **Status:** READY TO IMPLEMENT, pending one product clarification
**Root cause:** `app/lib/core/utils/riyadh_time.dart` hardcodes `Duration(hours: 3)` for every day/week/month boundary calculation, regardless of the device's actual timezone or the user's physical location.
**Current vs expected:** Today, a user physically outside Saudi Arabia has their transactions silently bucketed into the wrong calendar day/week/month for budgets, reports, and streaks. Expected: boundaries should reflect either the device's local timezone or a deliberately-chosen fixed business timezone, but whichever is chosen must be an explicit product decision, documented in code, not an unstated assumption.
**Affected files:** `app/lib/core/utils/riyadh_time.dart` and every call site (budget rollover, dashboard "today/this week/this month," streak/engagement day-gap calculations).
**Solution:** **BLOCKED BY PRODUCT DECISION** on one point first: should day/week/month boundaries follow the *device's* local timezone (correct for travelers, but means two users in different timezones see "today" boundary at different UTC instants — arguably the more intuitive choice for a personal expense tracker), or should Mali deliberately keep a fixed business timezone regardless of device location (simpler, consistent, but reproduces today's bug for anyone not in that timezone)? Recommended default: switch to device-local timezone (`DateTime.now()` without the hardcoded offset, using Dart's built-in local-timezone-aware `DateTime`), since "what day did I spend this money" should match the user's own lived experience of that day, not a fixed reference timezone. Implementation: replace `RiyadhTime`'s fixed-offset arithmetic with device-local equivalents; keep the class name/API shape if convenient for a smaller diff, or rename if the team prefers `LocalTime` to reflect the new semantics (Codex should confirm naming preference before the rename, to avoid unnecessary churn across call sites if a smaller diff is preferred).
**Migration/rollback:** None — Dart-only change, no schema impact.
**Test plan:** Unit tests constructing `DateTime`s in several fixed timezones (via `TZDateTime` or Dart's timezone-aware test scaffolding) and asserting boundary calculations match the intended zone; regression test confirming Saudi-based users see unchanged behavior (since Saudi Arabia has no DST, a device correctly set to Asia/Riyadh should compute identical boundaries under either the old or new logic — a valuable "no silent regression for the majority of current users" check).
**Manual QA:** MANUAL QA REQUIRED — change the simulator's timezone away from Riyadh, log a transaction near a day boundary, confirm it lands in the locally-correct day.
**Acceptance criteria:** A transaction's day/week/month bucket matches the device's local calendar date at the moment of the transaction, for any device timezone.
**Dependencies:** None.

### #10 — Capture health monitoring
**Severity:** High · **Status:** READY TO IMPLEMENT
**Root cause:** Zero app-side signal exists anywhere that SMS capture has stopped working (automation disabled, permission revoked, or otherwise silently broken).
**Solution:** Add a `last_capture_at` (or equivalent) surfaced to the Flutter app — simplest approach: derive it client-side from the most recent `user_transactions.source = 'ios_shortcut'` row's `created_at` (no new server state needed) or, more robustly, from the most recent successfully-synced `processed_captures` row via a small new read-only endpoint/RPC. Add a lightweight settings-screen diagnostic ("آخر عملية رصد: منذ 3 أيام") and, if that gap exceeds a threshold (e.g., 7 days) while the user has historically had regular capture activity, a one-time gentle in-app nudge ("لم نستقبل رسائل بنكية جديدة منذ فترة — تأكد أن الاختصار لا يزال مفعّلاً") — not a hard alert, since a genuinely quiet week of no purchases is also a valid, non-broken state; this is a heuristic nudge, not a certainty signal.
**Affected files:** New settings-screen diagnostic widget; a small new provider computing the last-capture gap; possibly a new read-only RPC if the client-side derivation proves insufficient.
**Migration/rollback:** Only if a new RPC is added (additive, trivial rollback).
**Test plan:** Unit test on the gap-computation logic; widget test for the nudge appearing/not appearing at the right threshold.
**Manual QA:** MANUAL QA REQUIRED — disable the Shortcuts automation on a real device, wait (or manipulate the last-capture timestamp in a debug build), confirm the nudge appears.
**Acceptance criteria:** A user can, without contacting support, discover from within the app roughly how long it's been since a capture was last processed.
**Dependencies:** Soft-depends on #3 (cleaner attribution) so this signal isn't polluted by cross-user relay noise on shared devices.

### #11 — Budget alert race (duplicate 80%/100% notifications)
**Severity:** Medium · **Status:** READY TO IMPLEMENT
**Root cause:** `BudgetProgressUseCase`'s `alert80Sent`/`alert100Sent` read-then-write has no lock; 4 unsynchronized call sites in `app_shell.dart` can invoke it concurrently.
**Solution:** Add a process-wide in-flight guard (mirroring the existing `_inFlightSync` pattern already proven correct in `CaptureSyncService`) around `BudgetProgressUseCase.call()` — if a call is already in flight, either await the existing in-flight future (preferred, matches the established pattern) rather than starting a second, independent invocation.
**Affected files:** `app/lib/domain/usecases/budget_progress_usecase.dart` (or a thin wrapper at the provider level, `app/lib/core/di/app_providers.dart`, if keeping the domain class itself framework-agnostic is preferred).
**Migration/rollback:** None — Dart-only.
**Test plan:** Deterministic concurrency test: fire two concurrent `call()` invocations against a fake repository with a controllable delay, assert only one alert fires for a single threshold crossing (required per the global "race fixes need a deterministic concurrency test" constraint).
**Manual QA:** Not required — fully covered by the deterministic test, no real-device timing dependency.
**Acceptance criteria:** Two concurrent invocations around the same threshold-crossing event produce exactly one notification.
**Dependencies:** None.

### #12 — Atomic local capture queue (`SharedCaptureStore` race)
**Severity:** Medium · **Status:** READY TO IMPLEMENT
**Root cause:** `SharedCaptureStore.enqueue()`'s load→append→save is not atomic across concurrent extension processes.
**Solution:** Introduce a lightweight cross-process lock around the read-modify-write (e.g., a file lock or `NSFileCoordinator`-based coordination over the App Group container, since `UserDefaults(suiteName:)` itself has no built-in cross-process transaction primitive) — bundle with #4 since both touch the same three `SharedCaptureStore.swift` copies and both require the same native-rebuild QA cycle.
**Affected files:** `app/ios/BankMessageShortcuts/SharedCaptureStore.swift` + 2 identical copies.
**Migration/rollback:** Native rebuild required; no server-side toggle.
**Test plan:** Swift unit test simulating two concurrent `enqueue()` calls (via dispatch queues or simulated concurrent access) and asserting both entries survive.
**Manual QA:** MANUAL QA REQUIRED — trigger several bank SMS in very quick succession on a real device and confirm all are eventually captured, none lost.
**Acceptance criteria:** No burst of near-simultaneous local-mode captures ever loses an entry.
**Dependencies:** Ship in the same PR/native-rebuild cycle as #4.

### #13 — DB CHECK constraints on parent financial tables
**Severity:** Medium · **Status:** READY TO IMPLEMENT
**Root cause:** `user_budgets.amount`, `user_goals.target_amount`, `user_plans.budget_amount`, `user_subscriptions.amount` have no `CHECK (amount > 0)`, and `user_plans` has no `CHECK (end_date >= start_date)` — inconsistent with the pattern already applied to child tables (`user_bill_payments`, `user_goal_contributions`) in earlier migrations.
**Solution:** Additive migration adding the missing CHECK constraints, mirroring the exact style already used for the child tables. Sequence this migration **after** the client-side validation fixes (#6, #25) ship, so real users encounter a friendly client-side error message before ever hitting a raw Postgres 400 from a constraint violation (defense in depth, not a replacement for client validation).
**Affected tables:** `user_budgets`, `user_goals`, `user_plans`, `user_subscriptions`.
**Migration/rollback:** Additive `ALTER TABLE ... ADD CONSTRAINT ... CHECK (...)`; rollback drops the constraint. **Before applying, verify no existing production row would violate the new constraint** (run a `SELECT count(*) WHERE NOT (condition)` against each table first — if any pre-existing row would violate it, that data must be reviewed/corrected before the constraint can be added, since a CHECK constraint addition fails outright against any existing violating row).
**Test plan:** SQL test confirming an insert violating each new constraint is rejected with the expected error code; confirm existing valid data continues to insert/update successfully.
**Manual QA:** Not required — purely a DB-layer test.
**Acceptance criteria:** A direct API call bypassing the Flutter client can no longer insert a non-positive amount or an inverted date range into any of the four tables.
**Dependencies:** Should land after #6/#25 (client-side validation) per the ordering rationale above.

### #14 — Sender-to-bank ambiguity for shared SMS gateways
**Severity:** Medium · **Status:** READY TO IMPLEMENT, pending data confirmation
**Root cause:** `sender_bank_mappings`' `confirmedMapping` is keyed by raw sender ID only; if two banks share one SMS gateway/shortcode, all traffic from that sender gets attributed to whichever bank was confirmed first.
**Solution:** Before writing a fix, confirm via the actual `sender_bank_mappings` seed/production data whether this collision pattern occurs at all in Mali's supported markets (this determines whether the fix is urgent or purely theoretical) — if confirmed as a real pattern, add a content-based tiebreaker (checking message-body keywords specific to each candidate bank, similar to `BankProfiles.detect`'s existing keyword logic) as a secondary disambiguation step whenever a sender ID maps to more than one confirmed bank for different users, rather than trusting the first confirmation unconditionally for that sender ID account-wide.
**Affected files:** `app/lib/domain/usecases/resolve_bank_for_sender_usecase.dart`.
**Migration/rollback:** None unless a schema change is needed to store multiple candidate mappings per sender (evaluate once the data-confirmation step above is done).
**Test plan:** Unit test with two synthetic bank profiles sharing one sender ID and distinguishable message content, asserting correct per-message disambiguation.
**Manual QA:** Not required if fully covered by unit tests against realistic message fixtures.
**Acceptance criteria:** A shared sender ID no longer silently misattributes every message to one bank once real disambiguating content is present.
**Dependencies:** None, but implementation should not proceed until the data-confirmation step establishes real-world relevance.

### #15 — Atomic last-account deletion (server-side RPC)
**Severity:** Medium · **Status:** READY TO IMPLEMENT
**Root cause:** The "refuse to delete the last account" check is a client-side check-then-act (count, then separate delete call), not atomic.
**Solution:** New RPC `delete_account(p_account_id uuid)` (mirrors `set_default_account`'s style) that locks the user's active-account count and performs the soft-delete inside one transaction, refusing atomically if the count would drop to zero.
**Affected tables/RPCs:** New function `delete_account`; `user_accounts` (no schema change, only the delete path moves server-side).
**Migration/rollback:** Additive function; rollback drops it (client falls back to the existing check-then-act path, which is safe again once #6's busy-state guard has shipped and substantially narrowed the window).
**Test plan:** Concurrency test: fire two simultaneous `delete_account` calls against a user with exactly 2 active accounts, assert exactly one succeeds and the other is rejected with a clear "cannot delete last account" error — required per the global "race fixes need a deterministic concurrency test" rule.
**Manual QA:** Not required — fully covered by the deterministic concurrency test.
**Acceptance criteria:** It is structurally impossible (not just unlikely) for a user to end up with zero active accounts via this path.
**Dependencies:** Depends on #6 (client already guards against the common case; this is the unconditional server-side guarantee).

---

## 6. Batch 3 Implementation Outline — Performance and Resilience

### #16 — Lazy/paginated transaction list rendering
**Severity:** Medium-High · **Status:** READY TO IMPLEMENT
**Root cause:** `transactions_screen.dart` builds an eager `ListView` with a `for`-loop-constructed `children:` list rather than `ListView.builder`.
**Solution:** Convert to `ListView.builder` (or a `CustomScrollView`/`SliverList` if date-group headers are needed), building only visible rows on demand.
**Test plan:** Widget test confirming only a bounded number of row widgets are instantiated for a large fixture dataset (not all rows), using `find.byType` counts against the rendered tree.
**Manual QA:** MANUAL QA REQUIRED — scroll performance check on a real/simulated device with a large seeded transaction history.
**Dependencies:** Pairs with #17 (ship together).

### #17 — Resumable/bounded pagination at the fetch layer
**Severity:** Medium · **Status:** READY TO IMPLEMENT
**Root cause:** `TransactionRepository.getAll()` has no limit/pagination parameter; the transactions screen always fetches and Dart-filters the entire history.
**Solution:** Add a paginated fetch method to the repository (page/cursor-based, reusing the existing 500-row page size already used internally for the full-fetch loop) and wire the transactions screen to request pages as the user scrolls, rather than one unbounded `getAll()` per filter change.
**Test plan:** Repository test confirming page-by-page fetch returns the correct, non-overlapping rows across pages for a large fixture set.
**Manual QA:** MANUAL QA REQUIRED — confirm scrolling to the bottom of a large history smoothly loads more rows without a long upfront stall.
**Dependencies:** Ship with #16.

### #18 — Wire the app to already-existing server-side aggregate RPCs
**Severity:** Medium · **Status:** READY TO IMPLEMENT — **note:** this exact scope was already analyzed in depth earlier in this same session before the adversarial-QA pivot interrupted it. That analysis found: `monthly_financial_summary` and `category_spending_summary` are **already wired** in `dashboard_providers.dart` and `reports_providers.dart` behind the existing `dashboard_supabase_summary` flag (currently `is_active = false`) — no new work needed there beyond the parity testing already scoped. `budget_progress_summary` is **not yet wired anywhere** — the concrete plan (already fully designed pre-pivot) is: inject an optional `fetchBatchSpent` closure into `BudgetProgressUseCase`'s constructor (keeping the domain layer free of a direct Supabase dependency, consistent with its existing DI style), batching the RPC call by the ≤4 distinct current-period tuples (one per `BudgetPeriod` enum value), gated by a new flag `budget_progress_supabase_rpc` requiring `budgets_supabase_primary` + `accounts_supabase_primary` + `transactions_supabase_primary` also true (mirroring the existing `supabaseDashboardSummaryEnabled()` composition pattern), added via an additive migration inserting the new flag row (`is_active = false`, `rollout_percent = 0`, following the exact insert style already used for `dashboard_supabase_summary` in migration `0030_financial_summary_rpcs.sql`). Codex should resume this exact design rather than re-deriving it.
**Migration:** One additive feature-flag-row insert migration + rollback (delete the row / restore prior state).
**Test plan:** Parity tests comparing Dart-computed vs RPC-computed values across: same user, same date range, category/account filters, transfers excluded, refunds handled, soft-deleted rows excluded, multi-currency behavior unchanged, month-boundary/timezone cases (coordinate with #9's timezone fix — parity tests should be written/re-run against whichever timezone semantics #9 lands with), >1000-row pagination baseline vs RPC result.
**Manual QA:** Not required for the RPC wiring itself (covered by parity tests); standard regression pass on dashboard/budgets screens after enabling the flag for a QA user only.
**Acceptance criteria:** RPC-computed and Dart-computed values match exactly across every parity scenario before the flag is ever proposed for wider-than-QA rollout.
**Dependencies:** Should be re-sequenced after #9 (timezone fix) so parity tests aren't written against soon-to-change day-boundary semantics.

### #19 — Backup schema-version reconciliation framework
**Severity:** Medium · **Status:** READY TO IMPLEMENT
**Root cause:** `restore_backup_usecase.dart` has exactly one hardcoded post-restore fixup (the accounts-table migration case) and no general mechanism for handling the *next* schema change.
**Solution:** Introduce a versioned backup format (`schemaVersion` field written into every new backup) and a small ordered list of post-restore migration steps, each tagged with the backup-schema-version range it applies to, run in order after a restore — generalizing today's one-off accounts fixup into the first entry of this list rather than a special case.
**Test plan:** Restore a fixture backup tagged with an old schema version, confirm all applicable fixups run in order and the resulting local DB matches what a fresh restore-then-migrate would produce.
**Manual QA:** MANUAL QA REQUIRED — restore an actual old backup file (if one exists from before this session's earlier migrations) on a current build and confirm no data loss or crash.
**Dependencies:** None.

### #20 — Bill payment two-phase write → single RPC
**Severity:** Medium · **Status:** READY TO IMPLEMENT
**Root cause:** Bill creation and payment recording are two separate client-initiated calls; #7 mitigated the UX symptom, this closes the root cause.
**Solution:** New RPC `create_subscription_and_record_payment(...)` (or extend `record_bill_payment` to optionally accept subscription-creation parameters atomically) so the client makes one network call instead of two, eliminating the partial-success state entirely rather than just handling it gracefully.
**Migration:** Additive new RPC; rollback drops it (client falls back to the two-call pattern hardened in #7, which remains safe).
**Test plan:** RPC test confirming atomicity — a forced failure partway through leaves neither a bill nor a payment row, never one without the other.
**Manual QA:** Not required — covered by the RPC-level atomicity test.
**Dependencies:** Depends on #7 shipping first.

### #21 — Rate-limit hardening on device-auth endpoints
**Severity:** Low · **Status:** READY TO IMPLEMENT
**Root cause:** `verifyDevice()`-gated endpoints other than `process-ios-sms` (`register-device`, `link-capture-device`, `register-push-token`, `sync-captures`) have no rate limiting, unlike `process-ios-sms`'s existing `bump_capture_rate_limit`.
**Solution:** Reuse the exact same `bump_capture_rate_limit`-style RPC/table pattern (or the same table with a distinct rate-limit key per endpoint) applied to these four endpoints.
**Migration:** Likely none needed if reusing the existing `capture_rate_limits` table with a per-endpoint key prefix; otherwise a small additive table.
**Test plan:** Test confirming repeated calls beyond the threshold are rejected, and legitimate call volumes are unaffected.
**Manual QA:** Not required.
**Dependencies:** None.

---

## 7. Batch 4 Implementation Outline — Privacy and UX

### #22 — App-switcher privacy (Android `FLAG_SECURE`)
**Severity:** Medium · **Status:** READY TO IMPLEMENT
**Solution:** Set `FLAG_SECURE` on the Android window (via `flutter_windowmanager` or platform-channel call to `WindowManager.LayoutParams.FLAG_SECURE`) so the app-switcher/recents thumbnail never shows real content and screenshots are blocked by the OS.
**Manual QA:** MANUAL QA REQUIRED — confirm recents thumbnail is blanked, confirm the OS screenshot action is blocked (Android shows its own "can't take screenshot" toast).
**Dependencies:** Ship with #23.

### #23 — Screenshot/privacy-screen policy (iOS)
**Severity:** Medium · **Status:** READY TO IMPLEMENT
**Solution:** iOS has no direct `FLAG_SECURE` equivalent to block screenshots outright, but the app-switcher snapshot can be replaced with a blank/branded placeholder view during `applicationDidEnterBackground` (a standard, well-documented iOS pattern). Note explicitly that this does **not** prevent a user from taking a screenshot while actively using the app (iOS provides no API to block that) — it only prevents sensitive data appearing in the app-switcher snapshot; this limitation should be understood and accepted as the ceiling of what's achievable on iOS, not treated as an incomplete fix.
**Manual QA:** MANUAL QA REQUIRED — confirm the app-switcher snapshot shows the placeholder, not real balances.
**Dependencies:** Ship with #22.

### #24 — Sweep remaining loading/progress-state gaps
**Severity:** Low-Medium · **Status:** READY TO IMPLEMENT
**Root cause:** `goal_details_screen.dart`'s contribution sheet has a `saving` flag never wired to `setState` (no visible spinner, though re-entry is still blocked at the logic level).
**Solution:** Apply the same busy-state pattern established in #6/#7 to this and any other remaining screen found in a final sweep (grep for `var saving`/`bool _busy`-shaped local variables not connected to `setState` across `lib/features`).
**Manual QA:** MANUAL QA REQUIRED per screen touched.
**Dependencies:** Reuses the pattern from #6/#7 — sequence after those ship so the pattern is established and consistent.

### #25 — Remaining client-side form validation gaps
**Severity:** Low-Medium · **Status:** READY TO IMPLEMENT
**Root cause:** Goal deadline can be in the past with no re-validation on submit; `bill_form_sheet.dart`'s `manualPaidAmount` allows exactly 0; `nextDueDate` picker allows up to 365 days in the past with no validator.
**Solution:** Add the missing validators, as the client-side companion to #13's DB CHECK constraints — client validation gives a friendly message, DB constraint is the backstop.
**Manual QA:** Not required — covered by widget tests.
**Dependencies:** Should ship before #13 lands (per the ordering rationale — friendly client error before raw DB 400).

### #26 — APNs registration-failure diagnostics
**Severity:** Low · **Status:** READY TO IMPLEMENT
**Root cause:** `didFailToRegisterForRemoteNotificationsWithError` only logs in debug builds; production failures are completely silent.
**Solution:** Surface this failure back to the Dart layer (via the existing method-channel pattern already used for successful token registration) so it can at minimum be recorded for the capture-health diagnostic (#10) rather than vanishing entirely.
**Manual QA:** MANUAL QA REQUIRED — deny notification permission on a real device, confirm the failure is now visible to the Dart layer (even if only surfaced via the #10 diagnostic, not necessarily a standalone alert).
**Dependencies:** Feeds into #10.

### #27 — Remaining minor UX/logging findings
**Severity:** Low · **Status:** READY TO IMPLEMENT
**Scope:** Grab-bag closure of any remaining low-severity items not otherwise assigned above (e.g., any further silent-catch blocks found during the #24 sweep). Codex should compile the final list opportunistically while executing #24/#26 and close them in the same pass rather than as separate PRs, unless a given item turns out to be larger than expected, in which case split it out and re-flag its severity.
**Dependencies:** Executed alongside #24/#26.

---

## 8. Migration Plan

All migrations below are additive-first, each with a rollback file, applied in this order (numbering continues from the current latest, `0034`, applied earlier this session):

| # | Migration | Finding | Type | Approval |
|---|---|---|---|---|
| 0035 | `admin_users` table + RLS | #1 | Additive (new table) | REQUIRES LIVE MIGRATION APPROVAL |
| 0036 | `processed_captures.claimed_user_id` column | #3 | Additive (new column) | REQUIRES LIVE MIGRATION APPROVAL |
| 0037 | `purge_user_data()` function (scaffolding only) | #8 | Additive (new function) | REQUIRES LIVE MIGRATION APPROVAL + explicit product sign-off before any UI wires to it |
| 0038 | `budget_progress_supabase_rpc` feature flag row | #18 | Additive (data row insert) | REQUIRES LIVE MIGRATION APPROVAL |
| 0039 | CHECK constraints on `user_budgets`/`user_goals`/`user_plans`/`user_subscriptions` | #13 | Additive constraint (verify no existing violating rows first) | REQUIRES LIVE MIGRATION APPROVAL |
| 0040 | `delete_account()` RPC | #15 | Additive (new function) | REQUIRES LIVE MIGRATION APPROVAL |
| 0041 | `create_subscription_and_record_payment()` RPC (or equivalent) | #20 | Additive (new function) | REQUIRES LIVE MIGRATION APPROVAL |
| 0042 | Device-endpoint rate-limit table/columns (if not reusing existing table) | #21 | Additive | REQUIRES LIVE MIGRATION APPROVAL |

No migration in this plan drops, renames, or alters an existing column's type. Every migration ships with a same-numbered rollback file under `supabase/rollback/`, following the existing project convention exactly.

## 9. Rollback Plan

General principle for this whole plan: every server-side change fails closed (denies access / declines to act) rather than failing open, when rolled back — this is explicit in Finding #1's rollback design and holds for every other finding touching auth or financial writes. Client-side (Flutter/Swift) changes roll back via a new build; there is no live server-side toggle for native-code fixes (#4, #12, #22, #23), which is why those are called out as needing extra manual QA before release — their "rollback" is slower than an Edge Function redeploy.

## 10. Test Strategy

Three tiers, consistent with this session's established QA methodology:
1. **Unit/widget tests** — deterministic, no timing dependency, run in CI (`flutter test`, `deno test`).
2. **Concurrency tests** — deterministic simulated races (not sleep-based flaky tests), required for every finding in this plan classified as a race condition (#2, #11, #15).
3. **Live QA against a throwaway Supabase user** — the Admin-API-provisioned QA-user methodology used throughout this session, for anything touching RPCs or Edge Functions, with mandatory cleanup afterward (delete QA rows + QA auth users, verify zero remaining, exactly as done for every live-evidence check earlier in this session).

## 11. Manual QA Plan

Every finding marked `MANUAL QA REQUIRED` above needs a real (or simulator, where sufficient) iPhone pass, since this working environment has no interactive display session and cannot drive real device UI itself (established fact from earlier in this session). Group manual QA passes by native-rebuild cycle to minimize how many times a build needs to be produced: (#4 + #12) together, (#22 + #23) together, everything else can be tested via simulator/hot-reload without a fresh native build.

## 12. Commit Plan

One PR per finding within Batch 1 (8 PRs), except where explicitly noted to bundle (#4+#12 share native files). Batch 2-4 findings may be grouped more loosely by file-family (e.g., all onboarding/account/bill UX fixes across batches touching the same screens could reasonably land in fewer, larger PRs if that's the team's preference) — Codex should default to one-PR-per-finding unless file overlap makes that wasteful, and should never bundle a Batch 1 finding into the same PR as a Batch 2+ finding, to keep the release-blocker set independently reviewable and mergeable.

## 13. Risk Register

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Admin bootstrap locks out the real admin | Low | Medium | Fails closed; SQL-editor escape hatch documented in #1 |
| Fingerprint reservation fix introduces false-positive duplicate suppression | Low | High | Explicit non-regression test required (#2) |
| `claimed_user_id` filter withholds a user's own legitimate captures | Low | High | Explicit acceptance criterion + stop condition in #3 |
| Riyadh-timezone fix regresses the majority of existing Saudi-based users | Low | Medium | Explicit "no silent regression for Riyadh-timezone devices" test in #9 |
| CHECK constraint migration fails against pre-existing violating data | Medium | Low (migration just fails, doesn't corrupt) | Pre-migration verification query required in #13 |
| User-deletion worker deletes the wrong user's data | Very low | Critical | Explicit cross-user-untouched regression test required in #8 |
| Native (#4/#12/#22/#23) fixes ship with an undiscovered edge case, requiring a slow app-update rollback | Medium | Medium | Extra manual QA emphasis; grouped native-rebuild QA passes |

## 14. Open Product Decisions

1. **#8 (user deletion):** grace-period length, hard-delete vs. anonymize, whether a deletion-request UI exists/needs building, applicable legal jurisdictions. **Hard blocker** — do not wire any UI to the purge worker without this.
2. **#9 (timezone):** device-local vs. fixed-business-timezone semantics for day/week/month boundaries.
3. **#14 (sender ambiguity):** whether this collision pattern is confirmed to occur in Mali's actual supported-bank data, or purely theoretical (affects urgency/priority, not correctness of the analysis).
4. **Notification copy for #8's grace-period start/end** (email or in-app) — product/legal call, not engineering.

## 15. Codex Execution Checklist

- [ ] Confirm exact file paths for every "Affected files" entry above before editing (some paths were referenced by convention from earlier session research and should be re-verified against the current tree, e.g. confirm `_AccountForm`'s exact containing file for #6).
- [ ] For every migration: verify `supabase migration list --linked` shows it applied on **both** local and remote after applying — do not assume the tracking table updated correctly; repair immediately if not (this exact gap occurred and was caught for migration 0034 earlier this session).
- [ ] For every race-condition finding: write and pass the deterministic concurrency test **before** considering the finding done — a fix without a reproducing-then-passing test is not acceptable per the global constraints.
- [ ] For every auth/security finding: write and pass the normal-user-denied and unauthenticated-denied negative tests **before** considering the finding done.
- [ ] For every native (Swift) change touching `SharedCaptureStore.swift`: verify all three copies (`BankMessageShortcuts/`, `Runner/`, `ShareBankMessage/`) remain byte-identical via `md5` after the change.
- [ ] Do not enable any feature flag globally at any point in this work — every new flag ships `is_active = false`, `rollout_percent = 0`, and stays there until a separate, explicit rollout decision.
- [ ] Do not commit — leave all changes in the working tree per standing project instruction; the orchestrator reviews and commits.
- [ ] Batch 1, Finding #8: implement scaffolding only; do not build or wire any user-facing trigger until the product decision in §14 is resolved in writing.
- [ ] Run the full gate list (`flutter analyze`, `flutter test`, `xcodebuild` for both Runner and BankMessageShortcuts schemes where native files changed, `deno check`/`deno test` where Edge Functions changed, `git diff --check`) before considering any batch complete.
