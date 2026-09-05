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

---

## 2026-09-05 · Corrected sequence A–G · **A and B complete · C BLOCKED · D/E/F/G not executed**

### A — affiliate DISARMED ✅ (production change, reversible)

```sql
select cron.alter_job(5, active := false);   -- 'affiliate-sync-hourly'
```

| | before | after |
|---|---|---|
| jobid 5 `affiliate-sync-hourly` | `active = true` | **`active = false`** |

Job definition, schedule (`17 * * * *`) and command are **retained untouched** —
only the active flag changed. No provider data touched, no affiliate function
deployed, no affiliate activation performed.

**To re-enable later:** `select cron.alter_job(5, active := true);`

This was done first, deliberately: `affiliate_worker_secret` is already present
in Vault, so a corrected `project_url` would otherwise be the single remaining
condition for this cron to start issuing real hourly requests.

### B — function classification matrix (traced, not documented)

Callers traced across `app/lib`, `supabase/migrations` (cron + triggers),
`admin/`, and function-to-function calls.

| Function | Class | Real caller evidence |
|---|---|---|
| `parse-sms` | **1 — core user-facing** | client ×2; **AI parse assist is dead without it** |
| `catalog-delta` | **1** | client ×2 — all catalog sync |
| `catalog-flags` | **1** | client — **remote feature flags dead without it** |
| `catalog-versions` | **1** | client |
| `catalog-coupons` | **1** | client — coupons catalog backend |
| `catalog-announcements` | **1** | client (`catalog_sync_service.dart:89`) |
| `catalog-campaigns` | **1** | client (`catalog_sync_service.dart:120`) |
| `bank-discovery` | **1** | client ×2 |
| `enrich-merchant` | **1** | client ×2 |
| `process-ios-sms` | **1** | client — **iOS Shortcuts capture dead without it** |
| `sync-captures` | **1** | client |
| `link-capture-device` / `unlink-capture-device` | **1** | client |
| `register-device` / `set-device-consent` | **1** | client |
| `register-push-token` | **1** | client |
| `merchant-feedback` | **1** | client |
| `purge-scheduled-deletions` | **2 — retention** | cron jobid 4 |
| `process-notification-retries` | **2 — infra** | cron jobid 2 (0052 + 0053) |
| `evaluate-budgets` | **2** | DB **trigger** on transactions (0057:48) |
| `evaluate-goals` | **2** | DB trigger (0057:142) |
| `evaluate-gamification` | **2** | DB trigger (0057:95) |
| `cron-daily-reminders` | **2** | cron jobid 3 |
| `affiliate-sync` | **3 — DEFERRED** | cron jobid 5 (now paused) |
| `affiliate-postback` | **3 — DEFERRED** | external network only |
| `prepare-affiliate-click` | **3 — DEFERRED** | no client caller (gateway unwired) |
| `affiliate-click-status` | **3 — DEFERRED** | no caller |
| `parser-test` | **4 — INTERNAL** | admin panel only (`admin/app/(admin)/parsers/[id]`) |
| — | **5 — OBSOLETE** | none identified |

### C — deployment **BLOCKED** by account privileges

Attempted: the 23 REQUIRED-NOW functions (classes 1 + 2), affiliate and
`parser-test` excluded by name. Result:

```
POST https://api.supabase.com/v1/projects/rjwphwsefnuotpbtuycf/functions/deploy?slug=…
403 {"message":"Your account does not have the necessary privileges to access this endpoint."}
```

Reproduced on a single-function retry. **Still 0 functions deployed.**

The limitation is specific to the deploy endpoint, not a read-only token:

| Endpoint | Result |
|---|---|
| `GET /v1/projects/{ref}/functions` | **200** |
| `GET /v1/projects/{ref}/secrets` | **200** |
| `POST /v1/projects/{ref}/database/query` (incl. writes) | **works** — the cron pause succeeded |
| `POST /v1/projects/{ref}/functions/deploy` | **403** |

**Owner action required.** Either the personal access token lacks a functions
write scope, or the account's role in org `jpcjcumbjsyojemsxmqo` does not permit
function deployment. `--use-api` (server-side bundling) was used because Docker
is unavailable on this machine; whether the Docker path would also 403 could not
be tested.

### D and E — deliberately NOT executed, and a correction to the ordering

**D (Vault worker secrets) not executed.** With no functions deployed the
secrets would configure nothing, and one of them is actively unsafe in the
current state:

> `service_role_key` is the project's highest-value credential. The 0057 triggers
> send it as `Authorization: Bearer` to `project_url || '/functions/v1/…'` — and
> `project_url` currently points at a host that is **not ours**. Writing
> `service_role_key` into Vault *before* correcting `project_url` would create a
> path that transmits the service-role key to a foreign host the moment that host
> resolves. Today it does not resolve; that is luck, not a control.

**Therefore the stated order should change for this one secret.** The reason E
was placed last — "correcting `project_url` arms the affiliate cron" — was
**already neutralised by step A**. The safe order is now:

1. restore function-deploy privileges → deploy classes 1 + 2
2. **correct `project_url`** (safe: affiliate cron is paused)
3. **then** write `service_role_key`, `purge_worker_secret`,
   `notification_retry_worker_secret` into Vault

**E not executed** — its stated precondition ("required functions are deployed")
is unmet.

### Shared-bearer contract, for when D runs

Verified from source. Edge functions read **UPPERCASE** env vars; the cron
callers read **lowercase** Vault entries; they must hold the *same* value:

| Cron caller reads (Vault) | Function compares (Edge env) | Vault state |
|---|---|---|
| `purge_worker_secret` | `PURGE_WORKER_SECRET` (`purge-scheduled-deletions:47`) | **absent** |
| `notification_retry_worker_secret` | `NOTIFICATION_RETRY_WORKER_SECRET` (`process-notification-retries:27`) | **absent** |
| `service_role_key` | platform service-role key (0057 triggers) | **absent** |
| `affiliate_worker_secret` | `AFFILIATE_WORKER_SECRET` (`affiliate-sync:38`) | present |

The Edge secrets `PURGE_WORKER_SECRET` and `NOTIFICATION_RETRY_WORKER_SECRET`
**do exist**, but their values cannot be read back (the API returns digests only),
so matching them requires rotating **both sides together** to one freshly
generated value — not guessing the existing one.

### F and G — not executed

Both depend on C. No cron/worker proof is possible while the workers do not
exist, and no destructive deletion test was attempted.
