# Deployment Report — Supabase Migrations + Verification

Project: `vrombzdgwqjjiijbidqb` (ACTIVE_HEALTHY, eu-central-1) · linked CLI 2.106.0.
**No code committed. No writes made to the production database.**

## 1. Applied migrations
`supabase migration list` shows **0058, 0059, 0060, 0061 already present in the Remote
migration history** — they were applied **before** this step (the "apply" was a no-op;
Postgres records a migration only after its SQL commits, so each ran successfully).

| Migration | Local file | Remote history | Note |
|---|---|---|---|
| 0058 | `0058_user_cards.sql` | ✅ applied | |
| 0059 | `0059_user_accounts_extended_fields.sql` | ✅ applied | (A4 — not in your list, but present & required) |
| 0060 | `0060_user_settings.sql` | ✅ applied | |
| 0061 | `0061_user_categories_sync_constraint.sql` | ✅ applied | (your note said "0061_categories.sql"; actual filename differs) |

**No migration failed. No migration content was modified.**

## 2. Schema verification (read-only, against production REST API)
| Check | Result |
|---|---|
| `user_cards` table | HTTP 200 (exists) |
| `user_cards` cols `local_account_id, last4, network, source` | HTTP 200 (exist) |
| `user_settings` table | HTTP 200 (exists) |
| `user_settings` cloud cols `local_id, theme, currency, privacy_mode_enabled, ai_consent_granted, cloud_processing_enabled` | HTTP 200 (exist) |
| `user_settings.db_encryption_key_ref` (device-local — must NOT sync) | **HTTP 400 (correctly absent)** — privacy invariant holds |
| `user_categories` table | HTTP 200 (exists) |
| `user_accounts` 0059 cols `credit_limit, bank_account_number, exclude_from_totals, metadata` | HTTP 200 (exist) |

## 3. Gates
- `flutter analyze` — **clean (0 issues)**.
- `flutter test` — **774 passed**.

## 4. Warnings
- **0059 was applied but not in your list.** It adds the extended `user_accounts`
  columns the A4 account form depends on. Harmless & required; flagging for awareness.
- Filename mismatch: `0061_user_categories_sync_constraint.sql` (not `0061_categories.sql`).

---

## 5. What I could NOT do — the real runtime audit (honest limitation)
You asked for a **complete end-to-end runtime audit through the running app** for every
entity (pull→Drift, appears in UI, create/edit/delete in the UI, outbox entry, push,
row in Supabase, multi-device pull, conflict, offline, reconnect, restart-while-pending,
dup/idempotency). **I cannot perform this from this environment**, and I won't fake it:

- I can't drive a running GUI app (tap buttons, read the screen).
- I have no signed-in auth session to push/pull a real user's rows.
- I have no second device for multi-device propagation.
- I can't toggle Airplane Mode / cut the radio, or force-quit mid-sync.

Writing test rows straight into the **production** DB via REST would (a) need a real
`auth.uid()` or the service_role key (bypassing RLS), and (b) pollute your live data —
so I deliberately made **zero writes**.

**What IS genuinely verified:** the production schema/migrations (above), the code
(`analyze` clean), and the sync layer's logic + edge cases via 774 automated tests
(offline write/enqueue/push/pull/conflict/idempotency/restart-survival/multi-device on
the shared outbox). That is strong evidence — but it is *not* the on-device runtime
audit you asked for.

## 6. Owner runbook — real runtime audit (run on a signed-in build)
Build/run signed in with Supabase, then per entity do the UI action and verify the
server with the queries below. Get a bearer token from the app session (or use the
Supabase dashboard SQL editor, which bypasses the need for a token).

**Verify a push landed (dashboard SQL editor, as your user):**
```sql
-- after creating a Card in the app:
select id, local_id, local_account_id, last4, network, source, deleted_at
from user_cards where user_id = auth.uid() order by created_at desc limit 5;

-- after changing Settings (cloud cols only; encryption key must be absent):
select local_id, theme, currency, privacy_mode_enabled, ai_consent_granted from user_settings where user_id = auth.uid();

-- after Create/Edit/Delete a custom Category:
select local_id, name_ar, icon, color, is_income, deleted_at from user_categories where user_id = auth.uid() order by updated_at desc;
```
**Verify the local outbox (device, debug):** the app writes to `planning_sync_outbox`
(and `ledger_*` for transactions). An offline edit should insert a row there; after
reconnect it should be gone (drained).

**Per-entity runtime matrix to fill on-device** (Accounts, Transactions, Cards,
Categories, Budgets, Goals, Plans, Subscriptions, Settings, Smart Inbox, Gamification,
Sender→Bank, Notification logs):
1. Fresh install signed in → confirm existing server rows **pull into Drift** and show in UI.
2. Create/Edit/Delete in UI → row changes in the SQL query above.
3. Airplane Mode → do the same → confirm it persists in the UI (Drift) with no error.
4. Reconnect → confirm the row now appears/updates in Supabase.
5. Second device → confirm it pulls the change.
6. Force-quit during a pending write → relaunch → confirm it still pushes (no dup).

## Verdict
**Database deployment: DONE and verified** (migrations applied, schema correct, privacy
invariant holds, analyze + tests green). **On-device end-to-end runtime audit: NOT run
here** — it requires the running app on real devices with real auth and network control,
which this environment doesn't provide. Runbook above is ready for you (or a device) to
execute.
