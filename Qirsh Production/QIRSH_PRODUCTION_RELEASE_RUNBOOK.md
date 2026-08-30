# QIRSH — PRODUCTION RELEASE RUNBOOK

**The authoritative execution order from today until Qirsh is live on the App
Store and Google Play.** Open this file, find the first unchecked step, do it,
verify it, tick it, continue.

**HEAD when written:** `576be89a` · **Repository state:** source/local complete, gates green.

---

## STATUS MARKERS

| Marker | Meaning |
|---|---|
| `[x]` | COMPLETE — proven, do not repeat |
| `[ ]` | TODO |
| `[~]` | WAITING / BLOCKED on something else |
| `[!]` | YOUSSEF ACTION — only you can do it |
| `[CLAUDE]` | Claude can do it now |
| `[AUTH]` | Claude can do it **only after you explicitly authorise that action** |
| `[DEVICE]` | Needs a physical phone |
| `[EXTERNAL]` | Needs an external console/account |

**`[x]` never means "the code exists".** It means implemented *and* verified at
the level that step claims. Source completion and live verification are tracked
separately throughout.

---

## QUICK STATUS DASHBOARD

| # | Phase | Status | Owner | Blocker | Next action |
|---|---|---|---|---|---|
| 0 | Source / local remediation | **[x] COMPLETE** | Claude | — | nothing — do not repeat |
| 1 | Legal hosting | `[ ]` TODO | Youssef | needs any HTTPS static host | publish `build/legal/` |
| 2 | New Supabase production project | `[ ]` TODO | Youssef | project does not exist yet | **create it — see §2.1** |
| 3 | Backend provisioning (migrations, functions, secrets) | `[~]` WAITING | Claude `[AUTH]` | needs Phase 2 | — |
| 4 | Apple developer configuration | `[ ]` TODO | Youssef | — | can start in parallel now |
| 5 | Android keystore | `[ ]` TODO | Youssef | — | can start in parallel now |
| 6 | Signed release builds | `[~]` WAITING | Youssef + Claude | needs 1, 2, 4, 5 | — |
| 7 | Physical-device QA (incl. UX-035) | `[~]` WAITING | Youssef `[DEVICE]` | needs Phase 6 | — |
| 8 | Internal beta (TestFlight / Play) | `[~]` WAITING | Youssef | needs Phase 7 | — |
| 9 | Capability activation (PUSH → PULL) | `[~]` WAITING | Claude `[AUTH]` | needs Phase 8 | — |
| 10 | Store submission | `[~]` WAITING | Youssef | needs Phase 9 | — |
| 11 | Staged rollout + monitoring | `[~]` WAITING | Youssef | needs Phase 10 | — |

### ► CURRENT NEXT STEP

**[!] Youssef — create the new Supabase production project (§2.1),** and in
parallel start Apple (§5) and Android keystore (§6). Those three have no
dependencies on each other and are the critical path.

Everything Claude can do without you is already done.

---
---

# ALREADY COMPLETED — DO NOT REPEAT

Recovered from repository evidence, tests and gate output. Each row is
implemented **and** verified locally. None of this needs redoing.

## Financial correctness

| Area | Evidence |
|---|---|
| `[x]` Exact-money architecture (integer minor units) | `app/lib/domain/finance/money.dart`, `currency_scale.dart` |
| `[x]` Money-typed display formatter (R-8) | `money_format.dart`, `app/lib/features/common/money_text.dart` |
| `[x]` Currency-scale table drift fixed (R-8a) | display scale now derives from the canonical registry |
| `[x]` Planning money conversion, schema v29→v31 | `app/lib/data/db/app_database.dart` |
| `[x]` Netting contract preserved and made visible | `financial_semantics.dart` unchanged; Reports explains it |
| `[x]` 3-decimal currencies no longer rounded | migration `0091`, `fmtCaptureMoney` |

## Security, privacy, sync

| Area | Evidence |
|---|---|
| `[x]` Consent enforcement, fail-closed | `app/lib/core/privacy/consent_authority.dart` |
| `[x]` Egress inventory — 12 gated, 1 exempt, 0 open | `app/test/architecture/egress_inventory_test.dart` |
| `[x]` SQLCipher encryption, fail-closed on missing extension | `app_database.dart`, key in platform keychain |
| `[x]` Guarded tombstones / CAS conflict typing (Phase 9K–9N) | live 2-client gate, zero PGRST116 |
| `[x]` Supabase-primary authority retired (MALI-034) | arch guard, `tools/check_arch_guard.sh` |
| `[x]` Backup/restore overhaul, portability | `app/lib/core/backup/` |

## Product surfaces

| Area | Evidence |
|---|---|
| `[x]` Phase J UI/UX closure — **39/39 findings closed**, 10 new found and fixed | `docs/audit/QIRSH_PHASE_J_UIUX_CLOSURE.md` |
| `[x]` On-device AI classifier (OD-13), zero per-request cost | `app/lib/engine/intelligence/merchant_classifier.dart` |
| `[x]` Parser fixes: 3-decimal, glued currency, evidence gate | `0087`, `0091` |
| `[x]` Admin operator-trust findings (UX-017…021) | `admin/tests/admin-ux-closure.test.mjs` |

## Release preparation

| Area | Evidence |
|---|---|
| `[x]` Migrations 0084–0091 written and reviewed | `supabase/migrations/` |
| `[x]` **Rollbacks for 0084–0091** (were missing) | `supabase/rollback/`, lint-enforced from 0084 |
| `[x]` Fresh-database dry-run: **all 91 apply in order** | `supabase/tools/dryrun_migrations.sh` |
| `[x]` Rollback round-trip proven | 0084–0091 re-apply after rollback |
| `[x]` Legal documents written | `docs/legal/PRIVACY_POLICY.md`, `TERMS.md` |
| `[x]` Legal static site generator | `tools/build_legal_site.py` → `build/legal/` |
| `[x]` IBM Plex OFL licence resolved from local sources | `app/assets/fonts/IBMPlexSansArabic-OFL.txt` |
| `[x]` Font licences registered in-app | `app/lib/core/theme/font_licenses.dart` |
| `[x]` `LEGAL_BASE_URL` added to all 3 CI workflows | `codemagic.yaml` |
| `[x]` Empty-define trap fixed | `app/lib/core/config/legal_urls.dart` |
| `[x]` Android signing fails closed, no debug-key fallback | 10 tests in `android_release_signing_test.dart` |
| `[x]` Repository coherence guards | `head_completeness_test.dart`, `quarantine_coherence_test.dart` |
| `[x]` Root cleanup + documentation taxonomy | this workspace, `docs/` |

## Gate evidence

Strict `REQUIRE_ALL_GATES=1 tools/ci_gates.sh` at HEAD `8a97a9ba`:

```
{"passed":12,"failed":0,"tool_missing":0,"caller_skipped":0,"artifact_pending":1,"strict":1}
ALL RUN GATES PASSED
```
Flutter **2840 bulk + 24 crypto**, analyze 0 issues, admin **113**, deno all functions.

---

# WHAT REMAINS BEFORE PRODUCTION

Only these. Everything else is done.

1. Host the legal site and get a public HTTPS URL.
2. Create the **new** Supabase production project.
3. Provision that backend: migrations 0001–0092, 24 Edge Functions, secrets, Auth.
4. Apple: identifiers, capabilities, APNs key, certificates, profiles.
5. Android: production keystore.
6. Signed release builds carrying `LEGAL_BASE_URL`.
7. Physical-device QA on real iPhone + Android, including UX-035.
8. Internal beta on TestFlight and Play internal testing.
9. Prove and activate exact PUSH, then exact PULL.
10. Store submission, approval, staged rollout, monitoring.

---
---

# PHASE 0 — BEFORE YOU TOUCH ANYTHING

## 0.1 `[x]` The wrong-project hazard — read this once

`supabase/.temp/project-ref` on this machine currently contains:

```
bdhqjijscwdzqwqanygv        # organisation iyfzfynifrmwcjbcyfwv, name "Nbjg"
```

That is **not** production and **not** evidence staging. It is gitignored, so
it is local state rather than a repository leak — but **any `supabase db push`
or `supabase functions deploy` run from this directory today lands there and
looks like it succeeded.**

**The rule for the rest of this runbook:** before *any* remote Supabase command,
prove the target.

```bash
cat supabase/.temp/project-ref     # must print the NEW production ref
```

A mismatch is a full stop, not a warning.

## 0.2 Projects that must never be contacted

| Project | Ref | Rule |
|---|---|---|
| Old production | `vrombzdgwqjjiijbidqb` | ZERO contact. Superseded by the new project. |
| Evidence staging | `dpdukyozedajelflkeix` | ZERO contact. |
| "Nbjg" (currently linked) | `bdhqjijscwdzqwqanygv` | Not a target. Unlink before deploying. |

---

# PHASE 1 — LEGAL HOSTING

**Why first:** both stores require a reachable privacy-policy URL, and the URL
must be compiled into the build. Getting this early removes it from the critical
path later.

## 1.1 `[x]` Legal documents written and reviewed

`docs/legal/PRIVACY_POLICY.md` · `docs/legal/TERMS.md`

Verified by `app/test/core/legal_urls_test.dart` to describe behaviour the code
actually has: consent off by default, on-device AI, revocation ≠ deletion.

## 1.2 `[x]` Static site generator built

```bash
python3 tools/build_legal_site.py
```
Produces `build/legal/{index.html, privacy/index.html, terms/index.html}`.
Directory-style, so `/privacy` and `/terms` resolve with no host config.
No dependencies. An empty render **fails the build** rather than publishing a
blank policy.

## 1.3 `[!] [ ] [EXTERNAL]` YOUSSEF — publish the site

**A paid custom domain is not required.** Any reliable public HTTPS static host
works. Easiest options, cheapest first:

| Option | How | Result URL |
|---|---|---|
| GitHub Pages | push `build/legal/` to a `gh-pages` branch of any public repo | `https://<user>.github.io/<repo>` |
| Cloudflare Pages | "Direct Upload", drag the `build/legal` folder | `https://<project>.pages.dev` |
| Netlify Drop | drag `build/legal` onto app.netlify.com/drop | `https://<name>.netlify.app` |

**Steps**
1. Run `python3 tools/build_legal_site.py`.
2. Upload the **contents** of `build/legal/` as the site root.
3. Open `https://<host>/privacy` and `https://<host>/terms` in a browser.

**Expected result:** both pages render, styled, readable on mobile, dark-mode aware.

**Verify:**
```bash
curl -sI https://<host>/privacy | head -1   # HTTP/2 200
curl -sI https://<host>/terms   | head -1   # HTTP/2 200
```

**Record:** `LEGAL_BASE_URL = https://<host>` (no trailing slash).

**Do NOT yet:** rebuild the app. That happens in Phase 6.

**If it fails:** a 404 on `/privacy` means the host is not serving
`privacy/index.html` for an extensionless path. Use `/privacy/` with the
trailing slash to confirm, then enable "clean URLs" on the host.

## 1.4 `[x] [CLAUDE]` Placeholder semantics retired — DONE

The legal site is live at `https://qirsh-legal.albaraai-dev.workers.dev`, and
that host is now the **built-in default** in `legal_urls.dart`.

This inverted the original design deliberately. The default used to be an
unresolvable host so a missing CI variable would be caught — but it was only
catchable by tapping the link in a finished build, which in practice means a
store reviewer finds it after submission. A working default degrades a missing
variable to *working links* instead of dead ones.

`legalUrlsArePlaceholder` asked whether the default was still in use, which
meant something only while the default was dead. It is replaced by
`legalBaseUrlIsBuildOverride`, which reports whether a define was supplied.
The old tripwire assertion is gone; `legal_urls_test.dart` now pins the exact
default URLs and proves the override and empty-define paths in their own runs.

`LEGAL_BASE_URL` is therefore **no longer a release blocker** — it stays wired
in all three workflows for staging or a future host change.

### PHASE 1 EXIT CRITERIA
- [ ] `https://<host>/privacy` returns 200 and renders
- [ ] `https://<host>/terms` returns 200 and renders
- [ ] `LEGAL_BASE_URL` recorded where you can find it at build time

---

# PHASE 2 — NEW SUPABASE PRODUCTION PROJECT

The production backend is a **brand-new project**. Nothing is reused.

## 2.1 `[!] [ ] [EXTERNAL]` YOUSSEF — create the project

**Where:** <https://supabase.com/dashboard> → **New project**

**Configure:**

| Field | Value | Why |
|---|---|---|
| Organisation | your own | — |
| Name | `qirsh-production` | unambiguous next to "Nbjg" |
| Database password | generate a strong one | **you cannot retrieve it later** |
| Region | `eu-central-1` (Frankfurt) or nearest Gulf region | latency for SA/EG/AE users |
| Plan | Free is fine to start | pg_cron and Vault are available; upgrade before public launch for backups |

**Save the database password into your password manager before clicking create.**
Supabase shows it once.

**Expected result:** project provisions in 1–2 minutes and reaches "Active".

**Then collect these five values** — Dashboard → **Project Settings → API**:

| Value | Where | Sensitivity | Goes to |
|---|---|---|---|
| **Project Ref** | in the dashboard URL `/project/<ref>` | not secret | CLI linking, verification |
| **Project URL** | `https://<ref>.supabase.co` | not secret, ships in app | `--dart-define=SUPABASE_URL` |
| **anon public key** | API settings | **client-safe by design** (RLS enforces access) | `--dart-define=SUPABASE_ANON_KEY` |
| **service_role key** | API settings | **SECRET — server only** | never in the app; Edge platform injects it |
| **DB connection string** | Settings → Database | **SECRET** | local `psql` migration runs |

> **The anon key is meant to be public.** It identifies the project, it does not
> grant access — RLS does that. The **service_role key bypasses RLS entirely**
> and must never reach the mobile app, a commit, or a screenshot.

**Verify the project is yours and empty:**
Dashboard → Table Editor → the `public` schema should have no application tables.

**Do NOT yet:** link the CLI, run migrations, or create anything by hand. The
migrations create the schema; hand-made tables would collide.

## 2.2 `[!] [ ] [AUTH]` YOUSSEF — authorise linking, then Claude links

Give Claude the Project Ref and say explicitly: *"authorised to link to
`<ref>`"*.

```bash
supabase projects list                      # confirm the ref is visible
supabase link --project-ref <NEW_REF>
cat supabase/.temp/project-ref              # MUST print <NEW_REF>
```

**Expected result:** the file contains the new ref, not `bdhqjijscwdzqwqanygv`.

**Verify:** the `cat` output matches character-for-character.

**If it fails:** `supabase login` first. Never proceed on a mismatch.

## 2.3 Dashboard configuration Youssef must do by hand

Migrations create tables, policies, functions and triggers. They **cannot**
create platform settings. These are yours.

### 2.3a `[!] [ ] [EXTERNAL]` Enable required extensions

**Where:** Dashboard → **Database → Extensions**

| Extension | Why Qirsh needs it | Used by |
|---|---|---|
| `pgcrypto` | UUIDs, digests | schema-wide |
| `pg_cron` | scheduled purge + notification retry dispatch | `cron.schedule(...)` in migrations |
| `pg_net` | outbound HTTP from Postgres to Edge Functions | `net.http_post(...)` |

**Verify:**
```sql
select extname from pg_extension
 where extname in ('pgcrypto','pg_cron','pg_net');   -- expect 3 rows
```

**If `pg_cron` is unavailable:** it needs a paid tier on some regions. Without
it the purge and retry workers never fire — they must then be driven by an
external scheduler. Note it and continue; it does not block anything else.

### 2.3b `[!] [ ] [EXTERNAL]` Create the `backups` storage bucket

**Where:** Dashboard → **Storage → New bucket**

| Field | Value |
|---|---|
| Name | `backups` |
| Public | **OFF** |

Migration `0001_init.sql` creates the RLS policies for it; `0086` adds the
owner-liveness write barrier. **The bucket itself must exist first** — the
policies attach to it.

**Verify:** `select id, public from storage.buckets;` → one row, `backups`, `false`.

### 2.3c `[!] [ ] [EXTERNAL]` Configure Auth providers

**Where:** Dashboard → **Authentication → Providers**

**Sign in with Apple** — needs Phase 5 first:

| Field | Value | From |
|---|---|---|
| Enabled | on | — |
| Services ID | `com.youssefsafwat.mali.signin` | Apple Developer (§5.3) |
| Team ID | your 10-char team id | Apple Developer membership page |
| Key ID | the Sign-in-with-Apple key id | Apple Developer (§5.3) |
| Private key | `.p8` contents | Apple Developer (§5.3) |

**Google** — the app already ships a Google iOS client id:

| Field | Value |
|---|---|
| Enabled | on |
| Client IDs | the iOS client id in `app/ios/Runner/Info.plist` (`CFBundleURLSchemes`) |
| **Skip nonce checks** | **ON** |

> The nonce setting is not cosmetic. Google Sign-In on iOS supplies a nonce the
> Supabase default flow rejects; leaving it off makes Google sign-in fail on
> device while working in tests.

**Redirect URLs** — Dashboard → **Authentication → URL Configuration**:
add `com.youssefsafwat.mali://login-callback` and your site URL.

**Verify:** each provider shows "Enabled" and the Apple entry lists the Services ID.

### 2.3d Everything else is created by migrations

| Dependency | Created by | Manual? |
|---|---|---|
| All application tables | `0001`…`0092` | no |
| RLS policies | migrations | no |
| Storage policies on `backups` | `0001`, `0086` | no (bucket is manual) |
| `supabase_realtime` publication | Supabase default | no |
| Database functions / triggers | migrations | no |
| Cron jobs (`cron.schedule`) | migrations | no — but `pg_cron` must be enabled (§2.3a) |
| Vault secrets | `vault.create_secret` in migrations | no |

### PHASE 2 EXIT CRITERIA
- [ ] Project active; Ref, URL, anon key, service_role key, DB password all recorded
- [ ] CLI linked and `cat supabase/.temp/project-ref` prints the new ref
- [ ] `pgcrypto`, `pg_cron`, `pg_net` enabled
- [ ] `backups` bucket exists, private
- [ ] Apple + Google providers configured, nonce checks skipped for Google

---

# PHASE 3 — BACKEND PROVISIONING

## 3.1 `[!] [ ] [AUTH]` Set Edge Function secrets — BEFORE deploying

Set these first so the workers never run unauthenticated even briefly.

`SUPABASE_URL`, `SUPABASE_ANON_KEY`, `SUPABASE_SERVICE_ROLE_KEY` are injected by
the platform — **do not set them**.

```bash
cat supabase/.temp/project-ref     # prove the target first

supabase secrets set PURGE_WORKER_SECRET="$(openssl rand -base64 32)"
supabase secrets set NOTIFICATION_RETRY_WORKER_SECRET="$(openssl rand -base64 32)"
supabase secrets set APNS_KEY_ID=<from Apple §5.4>
supabase secrets set APNS_TEAM_ID=<your team id>
supabase secrets set APNS_BUNDLE_ID=com.youssefsafwat.mali
supabase secrets set APNS_PRIVATE_KEY="$(cat AuthKey_XXXXXXXXXX.p8)"
# optional:
supabase secrets set GEMINI_API_KEY=<Google AI Studio>
supabase secrets set GOOGLE_MAPS_API_KEY=<Google Cloud, Places API enabled>

supabase secrets list              # names only — values are never echoed
```

The two worker secrets must be **freshly generated and distinct from the
service-role key**. That separation is the whole design: a leaked worker secret
must not confer database superpowers.

Full inventory with consequences: [`02_Supabase/secrets_checklist.md`](02_Supabase/secrets_checklist.md).

## 3.2 `[!] [ ] [AUTH]` Apply migrations 0001 → 0092

The database is empty; the entire chain runs.

**Already proven locally** — `supabase/tools/dryrun_migrations.sh` applied all 91
in filename order on a fresh `postgres:17`, and 0084–0091 re-applied after
rollback. What is untested is *this specific project's* platform state.

```bash
cat supabase/.temp/project-ref     # prove the target

# One file at a time, so a failure stops at a known point.
for f in supabase/migrations/*.sql; do
  echo "── $f"
  psql "$PROD_DATABASE_URL" -v ON_ERROR_STOP=1 -f "$f" || { echo "STOPPED AT $f"; break; }
done
```

`supabase db push` also works but applies everything in one pass; prefer the loop.

**Expected result:** 91 files apply. `0087` reports how many parsers it demoted
(non-zero is correct). `0091` may `WARNING` about remaining `{1,2}` caps — not fatal.

**Verify:**
```sql
select count(*) from information_schema.tables where table_schema='public';
select count(*) from public.sms_parsers where validation_status='passed';
select count(*) from public.categories;        -- 21 incl. the all_expenses sentinel
```

**Do NOT:** blindly re-run a failed migration. Read the error first — most are
ordering or a missing platform prerequisite from §2.3, not a bad migration.

**If it fails:** the matching reversal is in
`supabase/rollback/<name>_rollback.sql` for everything from 0084 up. Read
`11_Rollback_Recovery/migration_recovery.md` before running one — **0084 and
0085 must NOT be rolled back by dropping their functions.**

### ⚠️ Expect this user-visible consequence of `0087`

`0087` returns evidence-free `passed` parsers to `pending`, and `catalog-delta`
serves **only** passed parsers. **Some banks will stop parsing** until their
rules gain golden-test evidence. That is the fix working as designed, not a
regression — but plan for it rather than meet it in support tickets.

## 3.3 `[!] [ ] [AUTH]` Deploy the 24 Edge Functions

```bash
cat supabase/.temp/project-ref     # prove the target

cd supabase
for fn in catalog-delta catalog-announcements catalog-flags catalog-versions \
          catalog-campaigns catalog-coupons parser-test bank-discovery \
          parse-sms process-ios-sms enrich-merchant merchant-feedback \
          evaluate-budgets evaluate-goals evaluate-gamification \
          cron-daily-reminders link-capture-device unlink-capture-device \
          register-device register-push-token set-device-consent \
          sync-captures purge-scheduled-deletions process-notification-retries; do
  echo "── $fn"; supabase functions deploy "$fn" || break
done
```

There is no dependency order between functions; they share `_shared/` which
deploys with each.

**Two deploy with JWT verification off, deliberately** —
`purge-scheduled-deletions` and `process-notification-retries` are cron/operator
workers, gated on their own shared secret instead of a user JWT. Both fail
closed if the secret is unset (`bearerSecretAuthorized` returns `false` on an
empty secret), so deploying before §3.1 is safe but pointless.

Per-function detail: [`02_Supabase/edge_functions.md`](02_Supabase/edge_functions.md).

**Verify:** Dashboard → Edge Functions → 24 listed, each "Deployed".
```bash
curl -s -o /dev/null -w "%{http_code}\n" \
  -X POST https://<ref>.supabase.co/functions/v1/purge-scheduled-deletions
# expect 403 — proves the worker is up AND rejecting unauthenticated calls
```

## 3.4 `[ ] [AUTH]` Backend verification sweep

```sql
select extname from pg_extension where extname in ('pgcrypto','pg_cron','pg_net');
select id, public from storage.buckets;
select count(*) from pg_policies where schemaname='public';
select jobname, schedule from cron.job;
select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where n.nspname='public' and p.prosecdef;   -- SECURITY DEFINER functions
```

### PHASE 3 EXIT CRITERIA
- [ ] All secrets set; `supabase secrets list` shows every required name
- [ ] 91 migrations applied; verification queries return sane counts
- [ ] 24 Edge Functions deployed
- [ ] Unauthenticated worker call returns 403/401
- [ ] `cron.job` contains the scheduled jobs (if `pg_cron` enabled)

---

# PHASE 4 — AI ARCHITECTURE

Full detail: [`03_AI/`](03_AI/). Summary of what is true today.

## 4.1 `[x]` Primary: on-device classifier — free, offline, shipping

`app/lib/engine/intelligence/merchant_classifier.dart` — a TF-IDF character
n-gram nearest-neighbour model trained on the ~330-pair merchant→category
catalog the app already ships.

- **Zero per-request cost, zero model asset, no native dependency.** Pure Dart,
  well under a millisecond.
- **Abstains below a confidence floor** rather than guessing. The promise is
  precision when it speaks, not coverage.
- **Write fence:** may influence *only* a suggested category and a normalised
  display name. It can never touch amount, currency, direction, date, account or
  card identity, balances, any `_minor` field, or dedup/sync keys.

**This is the normal path and it requires no network, no key, and no consent.**

## 4.2 `[x]` Optional fallback: Gemini — wired, gated, never required

Constructed only when `SupabaseConfig.isConfigured`
(`app/lib/core/di/app_providers.dart`), calling the `parse-sms` Edge Function —
**the app never holds a Gemini key.** The key lives server-side as
`GEMINI_API_KEY`.

| Question | Answer |
|---|---|
| When invoked? | only when the deterministic parser cannot resolve a message |
| Consent? | `aiConsentGranted` must be true; `EgressClass.aiProcessing` fails closed with `ai_consent_off` |
| Payload? | re-sanitised **server-side** before the model sees it (`reSanitize`) |
| Key handling? | server-only; never in the binary, never in a define |
| Response validation? | structured, schema-checked; a malformed response is discarded |
| Missing key? | returns `upstream_unavailable` (retryable). **Local operation continues.** |
| Timeout / quota? | `fetchWithTimeout`; failure is non-fatal |
| Financial authority? | **none** — deterministic parser remains authoritative for amount, currency, direction, account and card identity |
| Disable entirely? | do not set `GEMINI_API_KEY`, or unset it: `supabase secrets unset GEMINI_API_KEY` |

**If `GEMINI_API_KEY` is absent, Qirsh works normally.** Only the AI-assisted
fallback for unparseable messages is unavailable. Shipping without it is a
supported configuration.

### PHASE 4 EXIT CRITERIA
- [ ] Decision recorded: ship with Gemini enabled, or without
- [ ] If enabled, `GEMINI_API_KEY` set (§3.1) and consent copy reviewed

---

# PHASE 5 — APPLE

Full detail: [`05_Apple/`](05_Apple/).

## 5.1 `[!] [ ] [EXTERNAL]` Apple Developer Program membership
<https://developer.apple.com/programs/> — $99/yr. Record your **Team ID**
(10 characters, top-right of the developer portal).

## 5.2 `[!] [ ] [EXTERNAL]` App ID and capabilities

**Where:** Certificates, Identifiers & Profiles → **Identifiers** → **+** → App IDs → App

| Field | Value |
|---|---|
| Bundle ID | `com.youssefsafwat.mali` (explicit) |

**Capabilities to enable — all four are required by shipped code:**

| Capability | Why | Evidence |
|---|---|---|
| Push Notifications | budget/capture alerts | `aps-environment` in `Runner.entitlements` |
| Sign in with Apple | auth provider | `com.apple.developer.applesignin` |
| App Groups | app ↔ extension handoff | `group.com.youssefsafwat.mali` |
| Keychain Sharing | shared device secret + capture key | two groups in entitlements |

**Also create App IDs for the two extensions** — a missing extension profile
fails the signed build late and confusingly:
- `com.youssefsafwat.mali.BankMessageShortcuts`
- `com.youssefsafwat.mali.ShareBankMessage`

Both need the same App Group and Keychain Sharing.

**Create the App Group:** Identifiers → App Groups → `group.com.youssefsafwat.mali`.

## 5.3 `[!] [ ] [EXTERNAL]` Sign in with Apple (Services ID + key)

1. Identifiers → **+** → **Services IDs** → `com.youssefsafwat.mali.signin`
2. Enable "Sign in with Apple", Configure → primary App ID `com.youssefsafwat.mali`
3. Return URL: `https://<NEW_REF>.supabase.co/auth/v1/callback`
4. Keys → **+** → enable "Sign in with Apple" → download the `.p8` **once**
5. Feed Services ID, Team ID, Key ID and `.p8` into Supabase §2.3c

## 5.4 `[!] [ ] [EXTERNAL]` APNs authentication key

**Where:** Certificates, Identifiers & Profiles → **Keys** → **+**

- Name: `Qirsh APNs`; enable **Apple Push Notifications service (APNs)**
- Download the `.p8` — **this download happens exactly once**
- Record the **Key ID**

Feed into Supabase secrets (§3.1): `APNS_KEY_ID`, `APNS_TEAM_ID`,
`APNS_BUNDLE_ID=com.youssefsafwat.mali`, `APNS_PRIVATE_KEY` (full `.p8` including
the BEGIN/END lines).

> One APNs key serves development and production. `aps-environment` in the build
> selects which environment the token targets.

## 5.5 `[!] [ ] [EXTERNAL]` Distribution certificate + profiles

- Certificates → **+** → **Apple Distribution**
- Profiles → **+** → **App Store** → one each for the app and **both extensions**

### PHASE 5 EXIT CRITERIA
- [ ] Team ID recorded
- [ ] Three App IDs with all capabilities
- [ ] App Group created
- [ ] Services ID + Sign-in key, wired into Supabase
- [ ] APNs `.p8` downloaded, four secrets set
- [ ] Distribution certificate + three provisioning profiles

---

# PHASE 6 — ANDROID SIGNING

Full detail: [`06_Android/signing_keystore.md`](06_Android/signing_keystore.md).

## 6.1 `[!] [ ] ` YOUSSEF — generate the production keystore

```bash
keytool -genkeypair -v -keystore mali-release.jks \
  -keyalg RSA -keysize 2048 -validity 10000 -alias mali
```

> **If you lose this file or its passwords, you can never update the app again.**
> You would have to publish a new listing under a new package name and abandon
> every install and review. Back it up in **two independent** places (password
> manager + encrypted offline copy) before continuing.
>
> Enrolling in **Play App Signing** (§10.2) reduces but does not remove this: it
> protects the *app* signing key, while this remains your *upload* key.

## 6.2 `[!] [ ] ` Configure locally

```bash
cp app/android/key.properties.example app/android/key.properties
# fill in storePassword, keyPassword, keyAlias=mali, storeFile=/absolute/path/mali-release.jks
git status     # MUST show nothing new — both patterns are gitignored
```

CI alternative: `ANDROID_KEYSTORE_PATH`, `ANDROID_KEYSTORE_PASSWORD`,
`ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD`.

## 6.3 `[x]` Signing behaviour is already correct

`app/android/app/build.gradle.kts` — verified by 10 tests:

- **Release never falls back to the debug key.** Without a signing config, every
  `assemble*Release` / `bundle*Release` / `package*Release` task fails with a
  named error. This guard exists because a debug-signed upload was rejected once.
- AdMob app id is shape-validated against the exact regex the SDK enforces at
  *process start*, where no Dart guard could help. Malformed **fails the build**;
  absent warns and ships with ads off.

### PHASE 6 EXIT CRITERIA
- [ ] Keystore generated and backed up twice
- [ ] `key.properties` filled, `git status` clean
- [ ] `keytool -list -v -keystore mali-release.jks -alias mali` prints the SHA-256

---

# PHASE 7 — SIGNED RELEASE BUILDS

**Prerequisites:** Phases 1, 2, 5, 6 complete.

## 7.1 `[ ] [CLAUDE]` Android AAB

```bash
cd app
flutter build appbundle --release \
  --dart-define=SUPABASE_URL=https://<NEW_REF>.supabase.co \
  --dart-define=SUPABASE_ANON_KEY=<anon key> \
  --dart-define=SENTRY_DSN=<optional> \
  --dart-define=LEGAL_BASE_URL=https://<host>
```

**Verify the artifact is signed with your key:**
```bash
keytool -printcert -jarfile build/app/outputs/bundle/release/app-release.aab
# SHA-256 must match: keytool -list -v -keystore mali-release.jks -alias mali
```

> **Known local limitation:** in the current sandbox, Gradle's JVM TLS handshake
> to `dl.google.com` is terminated even though `curl` to the same URL returns
> 200. This is environmental, not a repo defect — plugin resolution succeeded, so
> the pinning is correct. Build on your own machine or in Codemagic.

## 7.2 `[!] [ ] [EXTERNAL]` iOS IPA

Codemagic workflow `ios-signed-release` (recommended — it runs the strict gate
before signing), or locally:

```bash
cd app && flutter build ipa --release --dart-define=... （same four defines）
```

`codemagic.yaml` already passes `LEGAL_BASE_URL` in all three build workflows;
set it in the Codemagic `supabase` variable group.

## 7.3 `[ ]` Verify the legal links in the built app

Install the build, open **Settings → الخصوصية والبيانات**, tap both links.
They must open your live pages. If they open `mali.youssefsafwat.com`, the
define did not reach the build — check the variable group.

### PHASE 7 EXIT CRITERIA
- [ ] AAB signed, fingerprint matches
- [ ] IPA built and validated
- [ ] Both legal links open live pages from inside the app

---

# PHASE 8 — PHYSICAL-DEVICE QA

Full procedures and pass/fail criteria:
[`08_Device_QA/device_qa_checklist.md`](08_Device_QA/device_qa_checklist.md) ·
UX-035: [`08_Device_QA/UX_035_verification.md`](08_Device_QA/UX_035_verification.md)

`[DEVICE]` throughout — a simulator cannot exercise any of this.

**Capabilities stay OFF for all of Phase 8.** Cloud financial sync is inactive
by design; do not activate it to "test" it here.

### PHASE 8 EXIT CRITERIA
- [ ] Every BLOCKING row passes on a real iPhone
- [ ] Every BLOCKING row passes on a real Android
- [ ] UX-035 verified with screenshots at max text scale
- [ ] No money value on any screen disagrees with the source message

---

# PHASE 9 — INTERNAL BETA

[`09_Beta/`](09_Beta/) — TestFlight, Play internal testing, acceptance criteria.

Ship with **sync flags off and capabilities `unknown`**. State that in the
tester notes so nobody reports it as a bug.

### PHASE 9 EXIT CRITERIA
- [ ] ≥1 week internal use, no BLOCKING defect open
- [ ] Capture works on real bank messages from ≥2 banks
- [ ] No crash affecting >1% of sessions

---

# PHASE 10 — CAPABILITY ACTIVATION

Full detail: [`07_Cloud_Capabilities/`](07_Cloud_Capabilities/).

## In plain language

Qirsh stores money as exact integers. Sending them to a server and back can
corrupt them if anything converts through a float. Rather than assume the server
round-trips exactly, the app **refuses to sync money until that has been proven
in production**, one direction at a time.

## 10.1 `[x]` Code readiness — done

| Gate | State | Meaning |
|---|---|---|
| `exactPushTransportCapability` | `unknown` | outbound exact-money sync blocked |
| `exactPullTransportCapability` | `unknown` | inbound exact-money sync blocked |
| `planningServerCurrencyCapability` | `unknown` | budgets/goals cloud sync deferred |
| `kServerRevisionCas` | `false` | CAS ships off (`app/lib/core/sync/sync_capabilities.dart`) |

Authority is **positive proof only** — both `unknown` and `unsupported` block.

## 10.2 ⚠️ Activation is a CODE CHANGE, not a toggle

All three providers are hardcoded in
`app/lib/data/sync/exact_transport_capability.dart` and are **not wired to
`FeatureFlagService`**. No dashboard switch can activate them. Activation means
editing that file, rebuilding, and shipping.

**Consequence for incidents:** the **fast kill switch is the feature flags**
(`ledger_push_sync`, `ledger_pull_sync`, `planning_*_sync`) — remote and
immediate. A capability revert needs a release. Flip the flag first; treat the
capability revert as the follow-up.

A feature flag can never *falsely authorise* an unverified capability: the gate
requires the capability, and flags only ever narrow.

## 10.3 `[~] [ ] [AUTH]` Prove PUSH, then activate

**Order is PUSH first, and the reason matters:** a push failure is contained —
the outbox parks the write durably with `exact_money_transport_unverified` and
nothing is lost. A pull failure under an unverified transport writes **wrong
money into the local canonical store**, which is neither contained nor
automatically repairable.

**Test data — pick values that break naive implementations:**

| Case | Value | Currency | Proves |
|---|---|---|---|
| 3-decimal | `12.345` | KWD | scale not truncated to 2 |
| 0-decimal | `150` | JPY | no phantom fraction |
| 2-decimal boundary | `0.01` | SAR | smallest unit survives |
| Large magnitude | `90071992547409.93` | SAR | beyond 2^53 — a float would corrupt this |
| Negative | `-1240.50` | SAR | sign preserved |

**PUSH proof:** write each through the real PostgREST path; read back with
`::text`; require **byte-exact** equality with what was sent. Also confirm
idempotency (same request id does not double-write) and that a conflicting
update produces a typed durable conflict rather than a silent overwrite.

**Then activate** — edit only the push provider:
```dart
final exactPushTransportCapabilityProvider =
    Provider<ExactTransportCapability>((ref) {
  return ExactTransportCapability.verifiedExact;  // verified <date>, evidence <link>
});
```
Ship. Watch parked-write count fall to zero.

## 10.4 `[~] [ ] [AUTH]` Prove PULL, then activate

Same values, opposite direction. Require byte-exact `NUMERIC::text`. Then set
`exactPullTransportCapabilityProvider`.

## 10.5 `[~] [ ] ` Planning currency needs BOTH

`planningServerCurrencyCapabilityProvider` requires migration `0077` deployed
**and** that direction's transport verified. `weakerCapability()` keeps
budgets/goals parked unless both are `verifiedExact` — never one alone.

### PHASE 10 EXIT CRITERIA
- [ ] PUSH evidence captured for all five value cases
- [ ] PUSH activated, shipped, parked writes drained
- [ ] PULL evidence captured
- [ ] PULL activated, shipped, no decode errors in the field

---

# PHASE 11 — STORE SUBMISSION

[`10_Store_Release/`](10_Store_Release/) — App Store Connect, Play Console,
metadata, staged rollout.

Key declarations that must match `docs/legal/PRIVACY_POLICY.md`:

- **iOS:** `ITSAppUsesNonExemptEncryption = false` is already set. Qirsh uses
  SQLCipher; the exemption for standard encryption protecting the user's own
  data normally applies — **confirm against Apple's current criteria before
  submitting.** It is a legal declaration.
- **Android:** the Data Safety form, plus a justification for the
  notification-listener permission. That is the single most common rejection
  reason for this app category — explain that it reads bank notifications
  on-device to create the user's own spending record and that nothing is
  transmitted without consent.

### PHASE 11 EXIT CRITERIA
- [ ] Both store records complete with reachable privacy URL
- [ ] Builds uploaded and processed
- [ ] Review passed on both stores

---

# PHASE 12 — STAGED ROLLOUT AND MONITORING

1. Google Play: 5% → 20% → 50% → 100%, at least 24h at each step.
2. App Store: phased release (7-day automatic ramp).
3. Watch: crash-free rate, Sentry, parse failures, parked writes, auth errors.
4. Halt and hold at the current percentage on any regression — do not roll
   forward through a signal.

---
---

# STOP — DO NOT RELEASE IF

Any one of these is true, production release does not proceed.

| # | Blocker |
|---|---|
| 1 | The privacy policy URL does not resolve, or the in-app link opens the placeholder host |
| 2 | The Android keystore is not backed up in two independent places |
| 3 | `cat supabase/.temp/project-ref` does not print the intended production ref |
| 4 | Any migration 0001–0092 failed and was left partially applied |
| 5 | An Edge Function worker responds to an **unauthenticated** request with anything but 401/403 |
| 6 | `PURGE_WORKER_SECRET` or `NOTIFICATION_RETRY_WORKER_SECRET` equals the service-role key |
| 7 | The service-role key appears in any build, commit, screenshot or log |
| 8 | Any money value on any screen disagrees with the source bank message |
| 9 | A capability was activated without captured byte-exact evidence for that direction |
| 10 | PULL was activated before PUSH |
| 11 | Physical-device QA has an open BLOCKING failure |
| 12 | UX-035 could not be verified and large values are illegible or wrong on a real device |
| 13 | The strict gate is not green at the exact commit being shipped |
| 14 | Store privacy declarations disagree with `docs/legal/PRIVACY_POLICY.md` |
| 15 | Sign-out does not preserve unsynced local data (MALI-053n) |

---

# EMERGENCY — WHAT TO DO WHEN SOMETHING BREAKS

Full procedures: [`11_Rollback_Recovery/`](11_Rollback_Recovery/).

| Symptom | First action | Speed |
|---|---|---|
| Money syncing wrong | flip `ledger_push_sync` / `ledger_pull_sync` **off** | immediate |
| Parser mis-reading a bank | set that parser's `validation_status` to `pending` | immediate |
| Gemini failing or costing | `supabase secrets unset GEMINI_API_KEY` | immediate |
| An Edge Function is broken | redeploy the previous version | minutes |
| A migration broke something | the matching `supabase/rollback/` file — **read the header first** | minutes |
| Everyone must upgrade | `arm_force_update()` (migration `0089`, audited) | next app launch |
| A capability is wrong | flag off **now**; capability revert in the next release | flag: immediate |

**Never** roll back `0084` or `0085` by dropping their functions — those replace
functions that already existed, and dropping them leaves account deletion and XP
awards with no implementation at all.
