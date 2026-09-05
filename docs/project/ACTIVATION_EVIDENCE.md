# Qirsh — activation evidence log

Read-only production verification performed while executing the activation plan.
Project `rjwphwsefnuotpbtuycf`, verified before every call. **No secret value is
recorded here, and none ever should be.**

---

## 2026-09-05 · Phase I Step 1 — Vault `project_url` · **NOT EXECUTED**

**The authorised action was conditional on the secret being ABSENT. It is not
absent, so nothing was written.** What was found instead materially changes the
plan.

### Finding 1 — `project_url` exists, and its value is wrong

`vault.secrets` holds exactly two entries, both created 2026-09-04 17:58:47 UTC:
`project_url` and `affiliate_worker_secret`. The earlier record that Vault held
**neither** is superseded.

The stored `project_url` fails its contract. Verified by boolean comparison only
— the value was never selected or printed:

| Check | Result |
|---|---|
| equals `https://rjwphwsefnuotpbtuycf.supabase.co` | **false** |
| length | **36** (expected 40) |
| starts `https://` · ends `.supabase.co` | true · true |
| contains the authorised ref `rjwphwsefnuotpbtuycf` | **false** |
| contains any ZERO-CONTACT ref | **false** |
| trailing slash | false |

So it is `https://<16-character label>.supabase.co` — a well-formed Supabase URL
pointing at **neither our project nor a forbidden one**. It does not resolve
(Finding 3), which is what has kept it harmless.

### Finding 2 — the cron guards, and why only one passes

All six cron jobs are scheduled and `active`. The three worker crons read
**Vault** secrets (lowercase), which are a **different store** from the Edge
Function secrets (uppercase) verified earlier. Both stores exist and they do not
overlap:

| Cron | Second Vault secret required | Present? | Fires? |
|---|---|---|---|
| `notification-retry-dispatch-5min` | `notification_retry_worker_secret` | ❌ | fails closed |
| `cron-daily-reminders-job` + 0057 triggers | `service_role_key` | ❌ | fails closed |
| `purge-scheduled-deletions-job` | `purge_worker_secret` | ❌ | **fails closed** |
| `affiliate-sync-hourly` | `affiliate_worker_secret` | ✅ | **passes the guard** |

Edge secrets present: `GEMINI_API_KEY`, `NOTIFICATION_RETRY_WORKER_SECRET`,
`PURGE_WORKER_SECRET`, `SUPABASE_DB_URL`. Note two of those have Vault
counterparts that are **absent** — having the Edge secret does not satisfy a cron
that reads Vault.

### Finding 3 — no credential has left the database

`affiliate-sync-hourly` has been attempting hourly since 07:17 UTC today. Every
`pg_net` attempt failed identically:

```
status_code = NULL   error_msg = "Couldn't resolve host name"
```

DNS never resolved, so no TCP connection was opened and the
`Authorization: Bearer <affiliate_worker_secret>` header was **never
transmitted**. Six recorded attempts, all failed the same way. This is the only
reason a wrong `project_url` has been harmless.

### Finding 4 — **ZERO Edge Functions are deployed**

Verified twice, independently:

- Management API `GET /v1/projects/{ref}/functions` → `0 function(s) deployed`
- Direct probes → `catalog-flags`, `catalog-delta`, `parse-sms`,
  `purge-scheduled-deletions`, `affiliate-sync` all return **HTTP 404**
  (a deployed function returns 401 unauthenticated, not 404)

This is the largest correction to the activation plan. Consequences:

- **Remote feature flags cannot be fetched** (`catalog-flags` 404), so the client
  falls back to `_defaults` — every flag OFF. **Flipping server flag rows would
  change nothing** until functions are deployed.
- **Catalog delta sync is dead** — no banks, parsers, categories or
  merchant_keywords updates reach any device.
- **AI parse assist does not work** despite `GEMINI_API_KEY` being set —
  `parse-sms` is 404. The earlier claim that AI assist was "live and
  user-activatable today" was **wrong**.
- **iOS Shortcuts capture** (`process-ios-sms`) and **push workers** do not exist.
- **The purge worker does not exist**, independently of its missing Vault secret.

### Why the write was withheld

1. The authorisation was "if absent, create". It is present — the precondition
   fails, and overwriting is a different, unauthorised action.
2. Correcting it **would achieve nothing** for the stated objective: purge needs
   `purge_worker_secret` (absent) *and* its Edge Function (not deployed).
3. Correcting it **would change state in a deliberately deferred area** — it is
   the only missing condition for `affiliate-sync-hourly` to start issuing real
   hourly requests, and affiliate is P4, gated on a provider contract.

### Scheduled deletion purge — **NOT operational**

Three independent blockers, in the order they must be cleared:

1. `purge-scheduled-deletions` Edge Function is **not deployed** (404).
2. Vault `purge_worker_secret` is **absent**.
3. Vault `project_url` is **wrong** (Finding 1).

No destructive deletion test was attempted, and none should be until 1–3 are
cleared. The repository defines no approved safe-fixture method for exercising a
real purge, so that requirement is recorded rather than improvised.

### Next blocker, precisely

**Phase I Step 2 (deploy Edge Functions) must precede Step 1.** The ordering in
the plan was wrong: Step 1 cannot be validated — and several later steps cannot
work at all — while zero functions are deployed. The correct sequence is deploy
functions → set the three missing Vault secrets → correct `project_url` last,
because correcting it is what arms the affiliate cron.
