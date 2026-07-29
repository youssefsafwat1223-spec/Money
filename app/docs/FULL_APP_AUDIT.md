# Mali full application adversarial engineering audit

**Audit date:** 2026-07-28  
**Repository:** `Money`, branch `feat/accounts-multicurrency`, HEAD `88475da80b37c720c6e033ea3e5d5c21ce0fb88b`  
**Primary target:** `app/`; supporting targets: `supabase/`, `admin/`, `codemagic.yaml`  
**Mode:** read/inspect and report only; no fixes and no commit  
**Release verdict:** **Not safe**

## Executive assessment

The repository has a substantial automated Dart test suite, clean static analysis, fail-closed SQLCipher startup, Drift-only UI reads, deterministic SHA-256 feature bucketing, a two-second parser-isolate timeout, stable category keys, owner-scoped RLS in the core financial tables, and byte-identical iOS shared-capture-store sources. Those controls are real.

They are not sufficient for release. This audit found release-blocking defects in consent, account isolation, release configuration, Edge Function authorization, account deletion, sync durability, pull completeness, conflict handling, capture durability, and Android production networking. The most serious paths can expose user A's local financial data to user B, ship a production binary with the fixed test OTP `123456`, let ordinary project JWTs drive service-role Edge Functions with forged user identifiers, silently lose offline edits/captured messages, or permanently fail to erase an account.

This report records **44 findings: 5 Critical, 17 High, 15 Medium, and 7 Low**. Twenty-three are marked release blockers. “Live” Supabase deployment state is deliberately not inferred from migration files.

### Quality-gate result

| Gate | Result |
|---|---|
| `cd app && flutter analyze` | **PASS — 0 issues.** Terminal: `No issues found! (ran in 12.0s)` |
| `cd app && flutter test` | **PASS — 908 passed, 0 failed, 0 environment-blocked.** Terminal: `05:42 +908: All tests passed!` |
| `cd app && flutter test test/widget_test.dart` | **PASS — 1 passed.** Terminal: `00:07 +1: All tests passed!` |
| Edge unit tests | **31 passed; `catalog-delta/index_test.ts` environment-blocked.** Importing the handler called `Deno.serve`, and sandbox listener creation failed with `PermissionDenied: Operation not permitted`. This is not classified as a product failure. |
| Supabase Node contract tests | **5 passed, 0 failed, 5 skipped.** The skipped tests require `SUPABASE_URL`, anon key, and service-role key. |
| Admin authorization tests | **3 passed, 1 failed.** `admin/tests/admin-authorization.test.mjs` failed its parser-test ordering assertion because it searches for double-quoted `.from("...")` while the correctly ordered function uses single quotes. This is a genuine red auxiliary suite caused by a brittle implementation-text assertion, not a demonstrated auth bypass. |
| iOS build/native tests | **Environment-blocked.** Xcode 26.5/CocoaPods 1.16.2 are installed, but Flutter attempted to update `/usr/local/share/flutter/bin/cache` outside the writable sandbox; CoreSimulatorService was also unavailable. |
| Android build/native tests | **Environment-blocked.** `flutter doctor -v` reports no Android SDK. |
| Local SQL/RLS execution | **Environment-blocked.** Supabase CLI 2.106.0 is installed, but Docker API access is denied and no live credentials are available. |
| Dependency audit/currentness | **Partially verified.** Flutter dependency resolution reports 88 packages with newer versions incompatible with constraints. Registry-backed `npm audit`/`npm outdated` failed with `ENOTFOUND`; Flutter's outdated command was blocked by the global-cache write restriction. |

The full Flutter run emitted repeated Drift warnings about multiple `AppDatabase` instances sharing a `QueryExecutor`. It did not fail, but it is evidence of test-harness isolation risk. The pre-declared `widget_test.dart` animation-timer failure did **not** reproduce in either the full run or the targeted retry.

## A. Architecture map

### Module and trust-boundary map

```text
                          ┌─────────────────────────────────┐
                          │ Flutter UI / go_router          │
                          │ features/* screens + Riverpod   │
                          └───────────────┬─────────────────┘
                                          │ domain interfaces/use cases
                                          v
                          ┌─────────────────────────────────┐
                          │ Routed repositories             │
                          │ current route: Drift only       │
                          └───────────────┬─────────────────┘
                                          │
          ┌───────────────────────────────┼──────────────────────────────┐
          v                               v                              v
┌──────────────────┐          ┌──────────────────────┐        ┌────────────────────┐
│ SQLCipher/Drift  │          │ background sync     │        │ local services     │
│ app_database v27│<────────> │ outbox/push/pull    │        │ parser/categorizer │
│ 32-byte key in  │          │ direct SQL+Supabase │        │ reports/notifs     │
│ secure storage  │          └──────────┬───────────┘        └────────────────────┘
└────────┬─────────┘                     │
         │                               v
         │                    ┌──────────────────────────────┐
         │                    │ Supabase                     │
         │                    │ Auth/PostgREST/RPC/Storage   │
         │                    │ pg_net/pg_cron/Edge/APNs     │
         │                    └──────────────┬───────────────┘
         │                                   │ service-role functions
         │                                   v
         │                    ┌──────────────────────────────┐
         │                    │ APNs / Gemini / Sentry       │
         │                    │ external trust boundaries   │
         │                    └──────────────────────────────┘
         │
         ├──────── iOS MethodChannel ────────┐
         │                                    v
         │      Runner + Share Extension + App Intent/Shortcuts
         │      App Group UserDefaults + flock-protected capture queue
         │
         └──────── Android MethodChannel ────> ACTION_SEND in-memory queue
                                               (no SMS receiver implementation)
```

### Layer assessment

- UI financial reads are currently Drift-only. `app/lib/core/di/app_providers.dart:446-627` wires routed repositories with only Drift delegates, and remote catalog data is first persisted to Drift.
- Business logic is mostly in Dart. The remote catalog is content-oriented; parser/categorization decisions remain in the Dart engine. Server engagement functions nevertheless duplicate budget, goal, streak, and XP policy, causing behavior divergence.
- Background workers bypass repository interfaces by design but are spread across `features/planning_sync`, `features/capture`, `features/gamification`, `data/sync`, and `core/*`. They directly issue SQL and Supabase calls, making ownership, conflict, and retry rules inconsistent.
- An automated local-import graph over 375 Dart files and 1,669 internal import edges found one cycle: `features/app/app_shell.dart` → `features/dashboard/dashboard_screen.dart` → `features/app/app_shell.dart`.
- Legacy Supabase-primary repositories and cache-repair code remain reachable even though the current documented architecture says Drift is authoritative. `FinancialCacheRepairService` still describes Supabase as authoritative and can rebuild local slices.
- Direct-access inventory was performed for `Supabase.instance`/`SupabaseClient`/PostgREST/RPC/Storage, `AppDatabase`/custom SQL, `FlutterSecureStorage`, `UserDefaults`/shared preferences, local notifications, and MethodChannels. No financial screen was found reading Supabase as its normal UI data source; direct screen-to-DB coupling remains in manual transaction budget checks and AppShell orchestration.

### Data stores and components

| Store/component | Contents and role | Audit conclusion |
|---|---|---|
| Drift/SQLCipher | Categories, merchants, transactions, budgets, goals/contributions, achievements/streak/XP, subscriptions/payments, settings, accounts, cards, duplicates, plans/links, outboxes, smart inbox, mappings, dedup, catalog, notification events | Encryption fails closed. Schema/version/migration/ownership and atomicity defects are detailed below. |
| Flutter secure storage | SQLCipher key, auth/onboarding state, local-data owner UID, install/session preferences | Appropriate for the DB key; owner UID is only a guard, not row-level isolation. |
| iOS App Group UserDefaults | Raw queued SMS text, backend URL/anon key, install ID, device secret, APNs data, routes/log events | Sandboxed but not encrypted; destructive drain and privacy-manifest issues exist. |
| Android process memory | Shared ACTION_SEND messages in a static list | Not durable across process death; no background SMS capture. |
| Supabase Postgres | Catalog, profiles/backups/metrics, ledger, planning parents/children, cards/settings/categories, inbox, capture, gamification, logs | Source migrations are broadly owner-RLS scoped; Edge authorization, deletion, pagination, privilege, and compatibility defects remain. Live parity is unverified. |
| Supabase Storage | Per-user encrypted backups | Storage policies are owner-path scoped in migration text. Purge ordering can orphan objects. |
| Admin Next.js | Catalog/announcement/campaign management using server-side service role | API handlers use `requireAdmin`; the one failing test is brittle. Deployment secrets and live authorization were not verified. |

## B. End-to-end flow maps

### 1. Transaction capture

```text
iOS Share/App Intent
  -> SharedCaptureStore.enqueue (App Group, stable payload ID, flock)
  -> optional process-ios-sms Edge call/device-secret auth
  -> processed_captures + optional user_transactions + APNs
  -> Flutter destructively drains entire native queue
  -> CaptureSyncService fetches relay rows / local ingest parses in 2s isolate
  -> Drift transaction write
  -> ledger outbox enqueue (separate transaction)
  -> dedup payload marker (separate transaction)
  -> local notification
  -> server relay ack only after normal import path

Android
  -> user ACTION_SEND text
  -> MainActivity static in-memory list
  -> destructive MethodChannel drain
  -> same local ingest path
```

Normal backend import-before-ack ordering is correct. Kill/auth/error windows around the native drain, Drift insert, outbox insert, and dedup marker are not atomic and can lose or duplicate captures.

### 2. Manual transaction creation

```text
ManualTransactionSheet
  -> AddManualTransactionUseCase/AddTransactionUseCase
  -> DriftTransactionRepository.saveTransaction
  -> INSERT transaction
  -> SELECT it back
  -> LedgerOutboxQueue.enqueue
  -> SyncWakeup / periodic AppShell sync
  -> user_transactions upsert by (user_id, client_request_id)
  -> server ID attached locally
  -> pull refreshes metadata only for an existing row
  -> dashboard/provider invalidations + budget/engagement checks
```

Double-submit guards exist in major forms, but the local write and outbox are not one database transaction. Refund/status semantics are not faithfully encoded in the ledger outbox.

### 3. Edit/delete transaction

```text
Details/manual sheet
  -> Drift update or status='ignored'
  -> separate outbox update/delete
  -> push finds server by server_id or client_request_id
  -> update/tombstone
  -> outbox row deleted
  -> pull fetches newest 200
```

The update conflict token is absent from the payload, and existing-row pulls do not import remote financial fields. Deletes can be missed by capped/unfiltered tombstone pulls. Deleting a transaction separately removes related bill payments; those child outboxes are not included in the sign-out flush.

### 4. Authentication and session lifecycle

```text
Bootstrap
  -> optional Supabase.initialize
  -> AppSession.load secure metadata
  -> bind onAuthStateChange / reconcile current session
  -> open shared SQLCipher DB
  -> router uses SessionStatus

Interactive sign-in
  -> Google/Apple/OTP AuthService
  -> Supabase session
  -> setIdentity + remote onboarding marker
  -> claim local_data_owner_uid only if empty/same
  -> startup reconcile/backfill -> push -> pull

Sign-out
  -> best-effort 6s partial push
  -> local table wipe/reseed
  -> clear owner/auth metadata
  -> asynchronous device unlink
  -> provider/session reset
```

An expired session leaves the shared local DB intact. Re-authenticating as a different Supabase user does not reject/wipe a conflicting owner, so the new user can reach the old user's Drift data.

### 5. Cloud sync

```text
local write -> outbox (usually non-atomic) -> SyncWakeup or 30s poll
  -> guarded startup backfill (incomplete entity list)
  -> accounts push -> accounts pull
  -> planning-parent push -> planning-parent pull -> singleton registration push
  -> ledger push -> ledger pull
  -> smart-inbox push -> pull
  -> planning-child push -> pull
  -> gamification bootstrap/pull
  -> notification-log/sender-mapping specialized sync
  -> global DB revision -> broad provider refresh
```

Push-before-pull is implemented for the main engines, but no cursor/pagination exists, conflict resolution is incomplete, and several specialized entities use different durability models.

### 6. Card management

```text
CardFormSheet -> DriftCardRepository create/update/delete
  -> planning outbox when signed in
  -> user_cards upsert/tombstone
  -> planning pull -> Drift card
```

With `kUserCardsCloudV2=false`, unassigned cards are never queued and design fields are omitted. Migration `0064` exists only as source text; deployment is unverified, so current code intentionally keeps those values device-local.

### 7. Budget and bill scheduling

```text
Budget form -> Drift budget -> parent outbox -> user_budgets
  -> BudgetProgressUseCase queries Drift transaction totals
  -> local threshold notification
  -> server transaction trigger -> evaluate-budgets -> APNs

Bill form/payment -> Drift subscription/payment/counter
  -> parent outbox + child outbox
  -> user_subscriptions upsert
  -> record_bill_payment RPC for child/counter
  -> local planner schedules due reminder
  -> daily server cron independently sends APNs
```

The local bill/payment/counter writes are non-atomic. Server and local schedulers can duplicate notifications, and the server ignores per-user notification preferences/quiet hours.

### 8. Notifications

```text
settings.notifications_json
  -> NotificationPlanner / BudgetAlertPlanner
  -> cancel tracked planned IDs
  -> zonedSchedule exactAllowWhileIdle / iOS pending center
  -> notification log event in Drift/App Group
  -> tap/action route
  -> immediate DB action or plaintext pending-action file
  -> notification_logs sync
```

Stable SHA-derived IDs and Android boot receivers are present. iOS pending limits, exact-alarm access, edit-time rescheduling, cross-user pending actions, server preference enforcement, and lock-screen content remain unsafe.

### 9. Backup and restore

```text
BackupSnapshotBuilder sequentially SELECTs a table subset
  -> JSON snapshot
  -> Argon2id (64 MiB, 3 iterations) + AES-GCM
  -> private user Storage path + backups metadata

Restore
  -> download/decrypt
  -> delete a table subset
  -> insert snapshot rows
  -> repair/reseed
  -> provider invalidation / sync
```

Cryptography and storage path policy are sound in source. Snapshot consistency and coverage are not: cards, custom categories, inbox/mappings/duplicates/outboxes and newer account fields are absent.

### 10. Account deletion

```text
Privacy screen
  -> request_account_deletion RPC (30-day timestamp)
  -> immediate local wipe/reset + Supabase sign-out
  -> [missing automatic invocation]
  -> purge-scheduled-deletions Edge worker
  -> purge_user_data RPC
  -> Storage delete
  -> auth.admin.deleteUser
```

No source migration/cron wires the purge worker. If a later manual run deletes SQL first and then Storage/auth deletion fails, the profile row used to rediscover the due account is already gone, making retry incomplete.

### 11. Report generation

```text
Report request
  -> ReportSnapshotBuilder issues repository queries
  -> getAll() + in-memory filter for optional appendix
  -> immutable snapshot + metrics/composition
  -> PDF render in isolate when font bytes available
  -> plaintext temp PDF
  -> preview -> share or print
  -> only a future report invocation sweeps files older than six hours
```

The isolate and share warning are positive. Period-boundary totals can disagree with the exclusive appendix, large histories are loaded into memory, and temp-file cleanup is delayed.

## Entity-by-entity sync audit

| Entity | Local write and durability | Push / server validation | Pull / acknowledgement / conflict | Principal gap |
|---|---|---|---|---|
| Accounts | Drift + planning outbox, separate statements | Upsert `user_accounts`; RLS owner; unique `(user_id,local_id)` and one-active-default index | Top 200; metadata-aware update; pending becomes conflict | Default switch bypasses atomic RPC and can violate unique default; no pagination; relations orphan on delete |
| Transactions | Drift + ledger outbox, separate statements | Upsert by `(user_id,client_request_id)`; owner RLS; tombstone update | Top 200 active/top 200 unfiltered recent rows; existing rows receive only sync metadata | Remote edits never apply; conflict token omitted; refund/withdrawal/status round-trip loss |
| Budgets | Drift + planning outbox | Owner-RLS upsert; category/account mapping | Generic newest-200 pull; pending marked conflict | Blind last writer; missed rows/tombstones; local/server threshold logic diverges |
| Goals | Drift + parent outbox; contribution and goal increment separate | Parent upsert; contribution RPC idempotent by client request | Parent/child pulls; 200/500 caps | Local atomicity gap; no conflict UI; server notifications callable through unsafe Edge path |
| Bills/subscriptions | Drift + parent outbox | Owner-RLS parent upsert | Generic parent pull | Local recurrence/counter and cloud values can diverge |
| Bill payments | Payment, bill counter, then child outbox are separate | Relationship-aware RPC and owner checks | Child pull cap 500; server counter reapplied | Crash can leave payment/counter/outbox inconsistent; sign-out flush omits children |
| Plans | Drift + parent outbox | Owner-RLS upsert | Generic top-200 pull | Blind LWW and no cursor |
| Plan links | Link + child outbox | Find/insert/tombstone relationship rows | Top-500 pull, parent-ID resolution | Parent not yet synced creates poison retries; no pagination/conflict UI |
| Categories | Built-ins local; custom rows + planning outbox | `user_categories`, owner RLS; stable key references | Generic pull | Startup reconcile ignores them; wipe removes custom rows; pending writes can disappear on sign-out |
| User settings | Singleton + planning outbox | `user_settings`, owner RLS | Pull first, then register singleton | AI/cloud consent is forced true; notification writes before binding are intentionally dropped from outbox |
| Cards | Drift + conditional parent outbox | `user_cards`, owner RLS | Generic pull | Unassigned/design data deliberately local-only while v2 flag false |
| Smart inbox | `pending_sync` bit, no durable outbox history | Direct status update | Top 200 active/tombstones; local dismissal wins | No backoff/dead letter; no pagination; status-only writes lost on offline sign-out |
| Gamification | Local tables updated by Dart rules | Bootstrap-only writes; server Edge also awards XP | Full remote aggregate overwrites local XP/streak | No outbox/versioning; post-bootstrap local progress is discarded |
| Sender mappings | Row-local `pending/failed` marker | Batch upsert on owner unique key | Full download before upload; timestamp guard preserves pending | No pagination/backoff; specialized pattern differs from main sync |
| Notification logs | Append-only local events | Direct owner upsert | No pull; marks local event synced after success | Wipe omits event table; max-attempt event is silently discarded |
| Capture payloads | Native durable iOS queue / volatile Android queue | Device-secret-auth relay; fingerprint reservation; optional ledger dual write | Fetch max 50, local import/marker, then ack | Destructive native drain; non-atomic import marker; Android process-death loss |
| Backups | Encrypted snapshot generated on demand | Owner storage path + metadata | List/download/decrypt/replace subset | Snapshot omits important data and is not transactionally consistent |

No server cursor is persisted for any of the financial pullers. There is no stable `(updated_at,id)` keyset pagination, no end-of-snapshot watermark, no device revision/vector clock, and no user-facing conflict resolution path.

## Local data and Drift audit

`AppDatabase.schemaVersion` is 27 (`app/lib/data/db/app_database.dart:14,39`), despite `CLAUDE.md` still saying 4. The database manually creates 29+ operational tables plus catalog tables. Drift declares `allTables => const []` and no-op create/upgrade callbacks; `initialize()` runs schema creation, compatibility ALTERs, seed/repair passes, consent enforcement, then `PRAGMA user_version = 27`.

Positive controls:

- SQLCipher via sqlite3mc is checked at startup; failure to load the cipher throws instead of opening plaintext.
- A random 32-byte DB key is generated using `Random.secure()` and stored in platform secure storage.
- `PRAGMA foreign_keys=ON` is set on both connection and initialization.
- Important indexes exist for transaction time, duplicate fingerprints, server IDs/sync status, outbox retry, card account, bill-payment relations, mappings, and catalog lookup.
- Built-in category keys are stable strings and server mapping translates keys rather than local category UUIDs.

Material weaknesses:

- Schema initialization is not one encompassing transaction. A kill can leave a partially migrated DB that then relies on idempotent reruns.
- There are no local FKs from transactions/budgets/goals/subscriptions/cards to accounts, from bill payments to transactions, or from several diagnostic/dedup rows to their parents.
- Monetary values are SQLite `REAL`, while server values are `NUMERIC`; this is unsafe for cumulative multi-currency arithmetic and currencies with non-two-decimal minor units.
- Common financial queries need composite indexes such as `(account_id,status,occurred_at,type)`; current single-column time indexes still require large scans.
- `DataWipeService` deletes table-by-table without a transaction and omits `notification_log_events` and `financial_import_runs`.
- Ownership is database-wide, represented by one secure-storage UID. Rows themselves have no local owner column and queries are not owner-scoped.

## Supabase database, migrations 0001–0064

### Schema/policy inventory

Migration text defines profile/backup/metrics/catalog tables; capture device, relay, fingerprint, and rate-limit tables; owner financial ledger and smart inbox; accounts/planning parents and relationship children; custom categories/import runs; account deletion; notification logs/retry queue; gamification; cards; and user settings.

Core financial tables consistently enable RLS and use `user_id = auth.uid()` in `USING`/`WITH CHECK`. Relationship RPCs recheck ownership. Storage backup policies bind the first object path segment to `auth.uid()`. The admin allowlist is client-read-only for the current admin row and privileged admin API access is server-side. These are good source-level controls.

High-risk exceptions and rollout problems:

- Engagement/reminder Edge Functions create service-role clients but do not authenticate the invoking request or bind the payload user/record to the caller.
- `run_cron_daily_reminders()` is `SECURITY DEFINER` and is not explicitly revoked from `PUBLIC`/anon/authenticated in migration 0057.
- The scheduled account-purge worker is not scheduled; its own source says it is not wired.
- Purge SQL predates later tables and retains `notification_logs` via `ON DELETE SET NULL`; its multi-system sequence is not retry-safe.
- Account/default, financial-import, and child RPCs have explicit grants, but deployment ordering and old-client compatibility have not been exercised against a real migration chain here.
- Migration 0064 and client flag state are intentionally mismatched until remote deployment; live deployment cannot be assumed.
- The `metrics` insert policy accepts any authenticated row with `WITH CHECK (true)`, permitting metric spam because rows have no owner binding.
- Multiple migrations replace hotfix versions of import/bill-payment functions. Source order is coherent, but there is no runnable clean-install/upgrade SQL gate in this environment.

### Edge functions and backend services

Capture endpoints use device secrets/fingerprints and have meaningful idempotency/rate-limit tests. Parser-test verifies the user JWT and admin allowlist before privileged reads. Bank-discovery hashes sender identifiers in logs. Notification retry code distinguishes transient and permanent APNs failures.

By contrast, `evaluate-budgets`, `evaluate-gamification`, `evaluate-goals`, and `cron-daily-reminders` trust request bodies and immediately use service-role access. JWT verification at the gateway would only establish that some project token is valid; it does not prove the forged `record.user_id` is the caller or that the request came from the database webhook. Migration 0057 sends service-role Bearer tokens, but the functions never require that privilege.

## Privacy and security assessment

- Database-at-rest encryption, `FLAG_SECURE` on Android, and iOS app-switcher privacy cover are present.
- Sentry disables default PII, screenshots, and tracing, but the scrubber only edits exception values containing numeric patterns. Event messages, breadcrumbs, contexts, extras, tags, filenames, and merchant text are untouched.
- Cloud/AI processing has no effective opt-out and conflicts with Arabic/English strings claiming nothing leaves the device.
- Raw queued SMS and a bearer-like device secret are stored in App Group UserDefaults. App Groups are sandboxed, but this storage is not encrypted at the application layer.
- iOS `PrivacyInfo.xcprivacy` declares no collected-data types and omits the required-reason UserDefaults API even though all three native targets access App Group UserDefaults.
- Plaintext CSV exports are not deleted; share failure copies the entire ledger to the system clipboard. Temp PDFs are swept only when report generation is opened again.
- Normal sign-out unlinks capture devices best-effort. Account deletion bypasses that configured unlink and wipes state first.
- No HMAC secret was found embedded in the app binary. The capture device secret is provisioned/stored, not a compile-time global secret.

## Financial logic assessment

Transfers are excluded from primary income/expense totals. Refund handling is inconsistent: category-specific totals subtract refunds, while overall/daily/category/merchant/budget calculations ignore them. Accounts flagged `exclude_from_totals` are omitted from headline/currency totals but still included in daily/category/merchant breakdowns. This creates internally contradictory dashboards and reports.

Queries use inclusive SQL `BETWEEN`, while report periods and appendix filtering are modeled as half-open `[from,to)`. A transaction exactly at the next-period boundary can enter totals but not the appendix. Daily grouping uses SQLite `'localtime'`, while budget/report utilities mix device local time, UTC, and Riyadh-specific boundaries; historical grouping can change after timezone travel.

Currency codes are preserved and multi-currency totals are grouped rather than summed globally in the main report path. Precision is still binary floating point end-to-end locally, and multiple UI/export paths hard-code two decimal places.

## Notifications and scheduling assessment

Notification IDs are SHA-256-derived and separated into ranges; the previously documented unstable-hash/collision defect is fixed. Timezone initialization uses an IANA device zone, planned IDs are tracked for cancellation, and Android boot/action receivers are declared.

Outstanding problems:

- iOS schedules every planned item without prioritizing the 64-pending system limit.
- Android requests notification permission but does not request/check exact-alarm access before `exactAllowWhileIdle`. Both `USE_EXACT_ALARM` and `SCHEDULE_EXACT_ALARM` are declared, which also needs store-policy review.
- Bill/budget edits do not directly reschedule; correctness waits for startup/resume/another trigger.
- Server budget/goal/bill/streak pushes ignore local notification preferences and quiet hours and can duplicate local alerts.
- Lock-screen notification bodies can disclose merchant, amount, card context, goal name, or bill amount. Android uses private visibility, but there is no app-level redacted mode for all channels.

## State management, UI, accessibility, and performance

Most async UI paths use `mounted`/`context.mounted`, and analyzer found no `use_build_context_synchronously` issue. Save buttons in major forms use busy flags. Drift changes are made visible by a global revision provider and explicit invalidations.

The global revision design is also expensive: every custom write, including sync metadata and notification logging, debounces into invalidation of many broad `FutureProvider`s. AppShell polls sync every 30 seconds. Pullers then perform per-row SQL lookups/writes across up to seven parent tables and three child tables. This creates N+1 I/O, battery load, and rebuild churn.

No `integration_test/` suite or screenshot-golden suite exists. Widget/unit coverage exercises RTL-related components and many screens, but there is no systematic matrix for Arabic/English, 200% text scaling, screen readers, small screens, keyboard navigation, restoration, dark mode, and real platform dialogs/permissions.

The asset tree is about 16 MiB; two onboarding images alone are about 5.1 MiB and 2.3 MiB. `GoogleFonts.alexandria`/`ibmPlexSans` are used while the bundled font assets do not declare those families in `pubspec.yaml`, leaving runtime font fetching/fallback behavior unproven offline.

## Platform audit

### Android

- The release/main manifest lacks `android.permission.INTERNET`; only debug/profile manifests declare it.
- There is no `RECEIVE_SMS`/`READ_SMS`, SMS receiver, or durable background handler. The Dart service and background handler are no-ops.
- `hasSmsPermission()` checks `POST_NOTIFICATIONS`, so its method name/UX is false.
- ACTION_SEND messages are stored only in a static process list and destructively drained.
- `FLAG_SECURE`, biometric permission, notification receivers, boot restoration, and non-exported plugin receivers are positive.
- `allowBackup`/data-extraction rules are absent, so platform defaults can restore an encrypted DB without a usable keystore-backed key.
- No Android SDK was available to inspect a merged release manifest or exercise R8/ProGuard. No Android CI workflow is present.

### iOS

- Runner, Share Extension, and App Intent targets share `group.com.youssefsafwat.mali`; Runner release/profile use production APS and debug uses development.
- The three capture-store files are byte-identical: 570 lines each, SHA-256 `0ec28956a6fcfe69cbf9c8ae53b684cef8e5a4144357a2a4d6c4a671b30e844d`.
- The queue uses a file lock and stable payload IDs, but full-queue consumption deletes before Dart acknowledgement.
- App switcher privacy cover, Keychain-backed Flutter secure storage, Sign in with Apple entitlement, Share Extension, App Intent, and APNs channel are present.
- Privacy manifest declarations are incomplete; no associated domains/universal links or background modes are declared.
- `NSLocationWhenInUseUsageDescription` is present even though the text says the app does not use location, creating an unnecessary store/privacy declaration.
- Native compilation/tests and extension signing were environment-blocked.

## Dependencies and release readiness

Dependency resolution completed from the existing Flutter cache and reported 88 packages with newer versions incompatible with current constraints. That is not itself a defect, but there is no automated CVE/license/currentness gate, and registry access was unavailable for a definitive security audit. Runtime font fetching, platform plugin compatibility, and large assets need signed-artifact/offline validation.

`codemagic.yaml` builds/tests iOS but defaults production Supabase values to empty, has no Android release workflow, and does not gate Edge, SQL/RLS, admin, migration-chain, or old-client compatibility tests. Source contains the expected Mali production bundle identifiers and iOS signing/export structure, but actual certificates, provisioning, store declarations, environment isolation, and signed artifacts were inaccessible. No tested staged database rollout, backward-compatibility matrix, operational rollback rehearsal, or monitoring/alert threshold was found. Migrations are forward-only; reverting an app cannot revert already-applied data/schema semantics, so backend compatibility must precede client rollout.

## C. Findings table

Paths and line ranges are repository-relative. Short Dart/Swift basenames in this table were unique in the inspected tree and are accompanied by their owning module/context where needed; ranges identify the audited symbols rather than claiming live deployment parity.

| ID | Severity | Area | Exact file and symbol | What is wrong | Reproduction scenario | User impact | Data-loss / security impact | Root cause | Recommended fix | Required tests | Release blocker |
|---|---|---|---|---|---|---|---|---|---|---|---|
| MALI-001 | Critical | Consent/privacy | `app/lib/data/db/app_database.dart:429-450,650-658,1535-1545` `_enforceRequiredProcessingSettings`; `drift_user_settings_repository.dart:27-77`; `setup_screen.dart:25-34`; `app_en.arb:45-189`, `app_ar.arb:47-189` | AI consent and cloud processing default to and are repeatedly forced to true; UI makes them mandatory while strings claim data stays on-device. | Fresh install or restore; attempt to save settings with either false. Restart. | No meaningful privacy choice; misleading onboarding. | Financial SMS, merchant, amount, and sender-derived data can leave the device without revocable consent. | Product requirement was encoded as invariant instead of consent state; copy was not reconciled. | Make both explicit, granular, revocable opt-ins; gate every native/backend path; migrate without auto-consent; correct disclosures. | Fresh/upgrade/restore consent matrix; native-vs-Flutter state; revoke while queued/offline; localization assertions. | **Yes** |
| MALI-002 | Critical | Account isolation | `app/lib/core/session/app_session.dart:77-96,145-183,363-411` `_claimLocalDataOwnerIfUnclaimed`, `setIdentity`, `_reconcileSupabaseSession`; `auth_screen.dart:61-93` | A conflicting stored owner UID is neither overwritten nor used to block/wipe UI access. The DB has no row-level owner filter. | User A's session expires without sign-out; authenticate as user B; B has completed onboarding. | B can see A's Drift-backed financial UI. | Cross-account disclosure; B's background tasks can act on residual A artifacts. | Owner marker is only a backfill guard; session admission is independent of it. | Before admitting a UID, atomically compare owner and require wipe/recovery; ideally use per-user DBs or owner columns/scoped queries. | A→expired→B; killed mid-wipe; provider-cache reset; no network; capture/action remnants. | **Yes** |
| MALI-003 | Critical | Release configuration/auth | `codemagic.yaml:32-48,99-112`; `supabase_config.dart:6-12`; `bootstrap_runner.dart:87-101,214-229`; `auth_service.dart:32-73` | Release builds accept empty Supabase defines and silently select `StubAuthService` with fixed OTP `123456`. The release misconfiguration check is inside `if (kDebugMode)`, making its `kReleaseMode` branch unreachable. | Run signed workflow with missing/empty Supabase group. Enter any email and `123456`. | Production auth/cloud appears functional but is fake/local. | Authentication bypass and unauthenticated local financial use; no cloud deletion/sync guarantees. | CI defaults secrets to empty and runtime fails open. | Make production compile/startup fail closed; remove stub from release graph; CI assert nonempty production URL/key/environment. | Release-mode missing/invalid/staging define tests and built-artifact smoke login. | **Yes** |
| MALI-004 | Critical | Backend authorization | `supabase/functions/evaluate-budgets/index.ts:10-21`; `evaluate-gamification/index.ts:5-16`; `evaluate-goals/index.ts:5-16`; `cron-daily-reminders/index.ts:5-8`; `migrations/0057_engagement_webhooks.sql:149-184` | Service-role functions trust caller JSON/no caller and do not require the database webhook/service role. Public execute is not revoked from `run_cron_daily_reminders()`. | Invoke with an ordinary valid project JWT and forged `record.user_id`, or call cron RPC repeatedly. | Forged XP/budget/goal activity and notification spam. | Cross-user state mutation, APNs disclosure/spam, cost/availability abuse. | Gateway JWT verification was mistaken for webhook authorization; no signed event or role check. | Require service-only secret/signature and validate event/table/operation; revoke cron RPC from public/anon/authenticated; use idempotent event IDs. | anon/auth/userA→userB adversarial Edge/RPC tests; replay and malformed-event tests. | **Yes** |
| MALI-005 | Critical | Account deletion | `migrations/0042_account_deletion_policy.sql:17-96`; `functions/purge-scheduled-deletions/index.ts:3-82`; `privacy_screen.dart:98-141`; `migrations/0052_notification_logs.sql:22-60` | Purge worker is explicitly unwired. It purges SQL before Storage/auth; a later failure removes the discovery profile and defeats retry. Later tables/log retention and capture unlink are incomplete. | Request deletion; wait 30 days. Or manually run worker while Storage/auth deletion fails. | User is promised deletion that may never or only partly occur. | Retained auth/storage/log/device data and regulatory erasure failure. | No orchestrated durable purge state machine/cron; deletion order predates schema growth. | Schedule a monitored worker; persist per-step state; make steps idempotent; delete/revoke device first; cover all tables/log retention; retry until auth deletion succeeds. | Time-travel purge, per-step failure injection, all-table residue, Storage/auth/device checks, cancellation race. | **Yes** |
| MALI-006 | High | Android release | `app/android/app/src/main/AndroidManifest.xml:1-13`; `src/debug/AndroidManifest.xml:1-7`; `src/profile/AndroidManifest.xml:1-7` | Main/release manifest has no `INTERNET`; only debug/profile do. No audited dependency manifest adds it. | Install release APK and attempt auth, Supabase sync, Edge calls, Sentry, or remote fonts. | Production Android networking fails while debug appears healthy. | Cloud/auth/capture deletion unavailable; offline changes accumulate or are lost on sign-out. | Flutter template debug permission was never promoted to main. | Declare INTERNET in main and verify merged release manifest/network smoke tests. | Signed release APK auth/sync/capture/backup/Sentry smoke test. | **Yes** |
| MALI-007 | High | Drift/outbox atomicity | `drift_transaction_repository.dart:164-209,225-242,268-305,369-383`; `drift_goal_repository.dart:21-49`; `drift_bill_repository.dart:244-300`; `drift_account_repository.dart:107-160`; `planning_outbox_queue.dart:93-116,329-352` | Related row writes, counters, tombstones, sync-status changes, and outbox inserts use separate transactions/statements. | Kill process or inject DB failure after entity write but before outbox/counter update. | UI shows saved data that never syncs or inconsistent bill/goal balances. | Permanent data loss on sign-out/reinstall; duplicate or orphan cloud state. | Enqueue-at-write is implemented procedurally, not as one Drift transaction. | Wrap each aggregate write plus outbox/status in a single DB transaction; define crash recovery invariants. | Failure at every statement boundary; reopen/reconcile; update→delete coalescing. | **Yes** |
| MALI-008 | High | Pull completeness/tombstones | `ledger_sync_service.dart:39-62`; `accounts_pull_service.dart:36-58`; `planning_pull_service.dart:43-71`; `planning_child_sync_service.dart:44-54`; `smart_inbox_sync_service.dart:44-62` | Pulls cap at 200/500 with no cursor. Several “active” and tombstone requests fetch the same unfiltered top N then filter client-side. | Fresh device with >200 rows, or >200 recent active rows plus an older tombstone. | Older records/deletions never arrive; every poll refetches the same page. | Missing history and resurrection of deleted data. | Limit was treated as a complete snapshot; no keyset pagination/watermark. | Add server-side deleted filters and stable `(updated_at,id)` pagination with durable cursors and atomic cursor advance. | 201/501+ rows, equal timestamps, page failure, tombstone backlog, fresh device. | **Yes** |
| MALI-009 | High | Ledger merge/conflict | `ledger_sync_service.dart:163-220`; `ledger_outbox_queue.dart:146-184`; `ledger_push_service.dart:170-199,251-259` | Existing-row pull updates only sync metadata/account, never financial fields. Outbox omits `server_updated_at`, so optimistic conflict detection cannot fire; attach does not store the returned version. | Edit amount/category/note on device A, sync; pull on device B with same row. | Device B keeps stale data but records the new server timestamp, making staleness permanent. | Silent lost updates and irreconcilable multi-device divergence. | Merge implementation was optimized to avoid flicker before field parity/versioning existed. | Map all server fields, retain pending edits, send/compare version atomically, and expose resolution. | Two-device edit/edit, offline edit, clock skew, conflict resolution, remote delete vs pending edit. | **Yes** |
| MALI-010 | High | Ledger semantic parity | `ledger_outbox_queue.dart:154-190`; `ledger_push_service.dart:277-304`; `ledger_sync_service.dart:320-345,392-407`; `supabase_transaction_repository.dart:102-148` | Ledger outbox maps refund to `debit`→`expense`, withdrawal returns as payment, omits transaction status, and maps several pulled sources to unknown. | Create refund or confirm a pending relay transaction; sync; reinstall/pull. | Transaction type/status/provenance changes across devices. | Totals, review workflow, reporting, and audit history become wrong. | Legacy type encoding remained in the new outbox path despite hardened server columns. | Use canonical `transaction_type`, `direction`, `status`, and source mapping; version payload schema and migrate queued rows. | Round-trip every type/status/source including old outbox fixtures. | **Yes** |
| MALI-011 | High | Sign-out/user lifecycle | `app_session.dart:250-286`; `app_shell.dart:472-479`; `data_wipe_service.dart:21-60`; `pending_notification_actions.dart:13-50`; `notification_log_sync_service.dart:134-198` | Offline sign-out always wipes after a six-second partial flush. Child/inbox/mapping/log work is omitted. Wipe omits notification events/import runs and the plaintext pending-action file. | Make offline edits, tap a notification action, sign out, then sign in as another user. | Edits disappear; stale action/log artifacts can execute/upload under the next UID. | Data loss and cross-user metadata/action attribution. | Sign-out prioritizes immediate wipe without durable handoff or complete artifact inventory. | Offer wait/export/discard choice; flush every queue; owner-scope/delete all files/tables; make wipe atomic and verify empty. | Offline sign-out per entity; A→B pending actions/logs; kill mid-wipe. | **Yes** |
| MALI-012 | High | Capture durability | `ios/Runner/SharedCaptureStore.swift:250-291` and identical copies; `app_shell.dart:566-693`; `capture_sync_service.dart:315-370` | Native consumption deletes the entire batch before Dart ack. Auth failure requeues only the current item and breaks, losing the remaining drained batch. Transaction save, outbox, and payload marker are separate. | Drain multiple messages; kill after consume, or expire auth on the first item. | Bank transactions are silently missed or duplicated. | Irrecoverable capture loss; duplicate financial records/notifications. | Drain API has no lease/per-item ack and local import is not atomic. | Lease entries; ack/remove per payload only after atomic transaction+dedup+outbox; requeue all unprocessed entries. | Kill at every phase, multi-item auth failure, Android/iOS retry, duplicate APNs/local notifications. | **Yes** |
| MALI-013 | High | Android capture | `AndroidManifest.xml:1-88`; `MainActivity.kt:18-114`; `android_sms_capture_service.dart:1-12`; `sms_background_handler.dart:1-4` | There is no SMS permission/receiver/listener; APIs are no-ops. Shared text is process-memory-only, and `hasSmsPermission` checks notification permission. | Receive SMS with app closed, or share text then let Android kill the process before Flutter drains. | Promised automatic capture does not occur; shared messages vanish. | Missed transactions. | Platform implementation was stubbed while UI/channel naming remained. | Either implement a policy-compliant durable receiver/background path or remove/rename the promise; persist ACTION_SEND before returning. | Real-device closed/terminated/reboot/permission-denied capture tests. | **Yes** |
| MALI-014 | High | Backup/restore | `backup_snapshot_builder.dart:9-185,198-222`; `restore_backup_usecase.dart:12-46` | Snapshot omits cards, custom categories, inbox, mappings, duplicates, outboxes and new account fields; sequential reads are not one snapshot transaction; restore does not replace omitted tables. | Back up an account with credit/card/design/custom category data while writes occur; restore to a new device. | “Restore” loses or mixes user-visible data. | Silent data loss and inconsistent parent/child state. | Backup table contract lagged schema and lacks snapshot isolation/versioned field coverage. | Define versioned complete backup schema, read in one DB transaction, validate relations, and declare intentionally excluded data. | Every table/field, concurrent-write snapshot, old/new versions, large backup, interrupted restore. | **Yes** |
| MALI-015 | High | Default account sync | `drift_account_repository.dart:225-238,199-221`; `accounts_push_service.dart:92-170`; `migrations/0025_set_default_account_rpc.sql:31-70` | Normal `setDefault` queues the new default first; server may still have the old default and reject the unique index. The item is marked conflict/dropped. Deleting a default does not enqueue the successor. | Switch default on a multi-account synced user, or delete the current default. | Cloud/fresh device has no or the wrong default account. | Incorrect balances/currency context; unresolved conflict. | Atomic server RPC exists but normal local-first path bypasses it. | Represent default switch as one outbox command invoking `set_default_account`; atomically update local rows after ack. | Existing server default switch/delete, offline replay, concurrent device switch. | **Yes** |
| MALI-016 | High | Referential integrity | `drift_account_repository.dart:199-221`; `app_database.dart:239-503`; `migrations/0037_atomic_account_deletion.sql:4-67` | Deleting an account nulls only transaction references; cards, budgets, goals, and subscriptions retain the deleted account ID. Local schema has no FKs for these. | Delete an account that owns budgets/goals/bills/cards. | Related data disappears from filters or becomes ghost/inaccessible. | Orphaned financial plans and inconsistent sync references. | Account deletion contract was implemented only for ledger rows. | Define per-relation detach/reassign/delete policy and execute atomically locally and remotely. | Delete each account type with all dependent entities; restore/sync afterward. | **Yes** |
| MALI-017 | High | Card sync/feature rollout | `planning_outbox_queue.dart:17-25,247-260`; `migrations/0064_user_cards_optional_account_and_design.sql` | `kUserCardsCloudV2=false` silently leaves unassigned cards local and drops design fields while source migration 0064 exists. | Create unassigned/designed card; sign out/reinstall or use second device. | Card or customization disappears. | User data loss on lifecycle events. | Client capability is compile-time gated by unverified remote schema, without durable local-only warning/backup. | Deploy/verify schema, server-advertise capability, sync all fields, and prevent destructive wipe when unsynced unsupported data exists. | Old/new server capability, old client, no-account card, design round-trip. | **Yes** |
| MALI-018 | High | Financial totals | `drift_transaction_repository.dart:458-478,519-685`; `budgets_providers.dart:188-194` | Headline totals ignore refunds, category-specific totals subtract them, and excluded accounts remain in daily/category/merchant breakdowns. | Add expense+refund and an excluded account, then compare headline, chart, category, budget, and report. | User receives contradictory spending/budget information. | Bad financial decisions; reports are not reliable. | Aggregations duplicate filters instead of sharing one canonical signed-money predicate. | Centralize canonical flow classification/refund/exclusion filters and use it everywhere. | Cross-view fixtures for all types/statuses/refunds/excluded accounts/deletes. | **Yes** |
| MALI-019 | High | Notification policy | `migrations/0057_engagement_webhooks.sql:47-184`; `evaluate-budgets/index.ts:23-114`; `cron-daily-reminders/index.ts:13-76`; `notification_planner.dart:122-160` | Server and local engines independently send budget/goal/bill/streak alerts; server ignores `notifications_json`, quiet hours, `reminder_on`, locale, and device timezone. | Disable bill/budget notifications or enter quiet hours, then sync a transaction/bill. | Duplicate or unwanted sensitive lock-screen alerts. | Privacy preference violation and notification spam. | Preferences are local-only input while service-role functions treat all APNs devices as eligible. | Persist/enforce notification policy server-side, assign one authority per type, use stable collapse/event IDs and locale/timezone. | Opt-out, quiet hours, duplicate suppression, multi-device/timezone/DST. | **Yes** |
| MALI-020 | High | iOS privacy compliance | `ios/Runner/PrivacyInfo.xcprivacy:1-22`; all `SharedCaptureStore.swift:30-37` | Privacy manifest declares no collected data and omits UserDefaults required-reason access despite financial/profile/device data transmission and App Group UserDefaults use. | Archive/store privacy validation or compare runtime data flows with declaration. | App review rejection or inaccurate privacy label. | Regulatory privacy misrepresentation; financial data handling is undisclosed. | Compliance metadata was not updated with capture/cloud features. | Add correct accessed-API reasons and reconcile App Store privacy disclosures for financial info, identifiers, diagnostics, contact/profile data. | Archive privacy report and automated manifest/data-flow checklist for all targets/SDKs. | **Yes** |
| MALI-021 | High | Export/clipboard privacy | `features/settings/data_export.dart:13-53`; `report_file_service.dart:44-81`; `report_config_sheet.dart:233-274` | Plaintext CSV is never deleted; a share error copies the full ledger to clipboard. PDFs persist until another report run triggers a six-hour sweep. | Export/share, cancel or force share failure, inspect temp and clipboard. | Sensitive financial data persists outside encrypted DB. | Other apps/users/backups can access exported merchant/card/balance data. | Cleanup/warning lifecycle is incomplete and fallback is automatic. | Delete in `finally`, require explicit clipboard confirmation, support masking, clear clipboard where supported, sweep on startup. | Share success/cancel/error, app kill, stale sweep, masked export. | **Yes** |
| MALI-022 | High | Multi-device conflict | `planning_push_service.dart:190-215`; `planning_pull_service.dart:198-221`; `planning_child_sync_service.dart:404-453`; no feature UI for `sync_status='conflict'` | Planning upserts blindly overwrite remote rows; pull converts pending to conflict and then leaves it indefinitely. There is no conflict-resolution UI. | Edit same budget/goal/bill/plan on two offline devices, then reconnect. | One edit is lost or item remains permanently unresolved. | Multi-device financial plan corruption. | LWW lacks versions and conflict state is diagnostic-only. | Add server revision/conditional update, deterministic field/record policy, visible resolution, and retry semantics. | Concurrent edit/delete, clock skew, conflict UX and resolution sync. | **Yes** |
| MALI-023 | Medium | Retry/poison queue | `ledger_outbox_queue.dart:76-144`; `planning_outbox_queue.dart:354-427` | `attempt_count >= 5 OR ...` makes exhausted rows eligible; `markFailed` resets them to one. No dead-letter/permanent-HTTP classification exists. | Queue a schema-invalid record and leave app active. | Endless retries, battery/network churn, recurring errors. | Service load and stuck sync; later items can be delayed. | “Retry after app update” was implemented without app-version marker or terminal state. | Add capped transient backoff, permanent/dead-letter state, app-version rearm, diagnostics and user action. | 4xx/5xx/offline/auth/schema mismatch/upgrade poison tests. | No |
| MALI-024 | Medium | Gamification sync | `gamification_sync_service.dart:38-127,129-219`; `app_shell.dart:540-546` | XP/streak push occurs only when server rows are absent; every pull overwrites later local progress. Server Edge logic separately awards XP. | Create local engagement after bootstrap, then perform sync. | XP/streak changes vanish or differ by device. | Loss of non-financial progress; duplicate awards possible under unsafe replay. | Two authorities and no durable event/outbox model. | Use idempotent engagement events or one authoritative aggregate with versions; remove duplicated rules. | Offline progress, two devices, webhook replay, bootstrap merge. | No |
| MALI-025 | Medium | Notification scheduling | `local_notification_service.dart:205-220,527-588,650-670`; `notification_planner.dart:122-160`; bill form repositories | iOS 64-item limit is unmanaged; exact-alarm access is not checked; edits do not immediately reschedule. | Create >64 reminders, deny exact alarms, or edit due date while app stays open. | Reminders disappear or fire for old dates. | Missed bills or misleading reminders. | Planner assumes platform accepts every request and relies on lifecycle refresh. | Cap/prioritize iOS, detect exact-alarm capability/fallback, reschedule transactionally after CRUD. | 65+ reminders, permission transitions, edit/delete, reboot, DST/timezone. | No |
| MALI-026 | Medium | Local schema/precision | `app_database.dart:239-503,671-689,883-981,1061-1081` | Money is stored as `REAL`; multiple account/transaction/child relations lack FKs. | Import many fractional/three-decimal values or delete referenced parents. | Rounding drift and orphaned UI rows. | Financial integrity degrades with scale. | Flexible manual schema favored migration ease over fixed minor units and constraints. | Store integer minor units/decimal strings with currency scale; add validated FKs or explicit relation triggers. | Precision property tests, migration conversion, FK/orphan repair. | No |
| MALI-027 | Medium | Migration safety | `app_database.dart:39-52,97-108,596-1076` | Drift has no declared tables/migrations; manual create/ALTER/repair/user_version sequence is not atomic or schema-validated. | Kill during upgrade or ship a malformed compatibility ALTER. | Startup failure or partially upgraded behavior. | Potential local data loss after user chooses reset recovery. | Manual schema bypasses Drift's migration guarantees. | Transactional versioned migrations, schema snapshots, preflight/postflight integrity checks, rollback/recovery strategy. | Upgrade from every supported schema; power loss after each step; corrupt/key mismatch. | No |
| MALI-028 | Medium | Dates/timezones | `drift_transaction_repository.dart:469,492,531,557-564,597,637`; `report_period_resolver.dart:46-75`; `report_snapshot_builder.dart:129-143` | Inclusive `BETWEEN` conflicts with half-open report periods; SQLite localtime, device local, UTC, and Riyadh boundaries are mixed. | Transaction exactly at next-month midnight; travel timezones; DST transition. | Totals/appendix/week comparisons differ or move historically. | Financial report inaccuracy. | No shared interval/timezone contract. | Standardize half-open UTC instants derived from explicit business timezone and document week start. | Boundary microseconds, DST, travel, leap day, Saturday week. | No |
| MALI-029 | Medium | Performance/state | `app_providers.dart:121-160`; `app_shell.dart:157-162,494-546`; pull services' per-row SQL | Every DB write drives broad provider invalidation; 30-second sync runs capped snapshot queries with per-row lookups. | Use 1,000+ records while sync/log events are active. | Flicker, slow startup/resume, battery and network drain. | May increase kill windows and missed background work. | Global revision is coarse and pull algorithms are N+1. | Table-scoped streams, keyset deltas, batched SQL/upserts, adaptive sync, instrumentation/budgets. | 1k/10k records, rebuild counts, query counts, battery/background benchmarks. | No |
| MALI-030 | Medium | Reports/performance | `report_snapshot_builder.dart:58-115,129-143`; `drift_transaction_repository.dart:435-454`; `report_generation_controller.dart:115-238` | Report collection issues many sequential queries; appendix calls `getAll()` with limit `1<<30`; snapshot/bytes remain cached/in memory until controller invalidation. | Generate detailed report on a very large ledger. | Long wait, memory pressure, possible process kill. | Generated temp artifact can remain after kill. | Convenience repository APIs replace bounded/streamed snapshot queries. | Dedicated indexed report queries, paging/streaming, memory limits, immediate file lifecycle cleanup. | 10k/100k transactions, cancellation and low-memory tests. | No |
| MALI-031 | Medium | App Group secrets/privacy | `SharedCaptureStore.swift:14-39,96-174`; `capture_device_registration_service.dart` | Raw SMS, sender, backend anon key, install ID, APNs token, and device secret reside together in App Group UserDefaults without application-layer encryption. | Inspect an App Group container from another signed group target/device backup/compromised extension. | Sensitive capture data and bearer material are exposed within the group boundary. | Capture impersonation/replay until unlink/rotation; SMS disclosure. | Shared accessibility was prioritized over confidentiality. | Store secret in shared Keychain access group; encrypt queue records; minimize fields/retention; rotate on unlink. | Extension/host key access, backup extraction, rotation/replay, corrupt ciphertext. | No |
| MALI-032 | Medium | Crash telemetry | `app/lib/main.dart:17-50` `_scrubSentryEvent` | Scrubber only edits exception `value`; events without exceptions and breadcrumbs/contexts/extras/tags/messages are untouched. | Throw/log an error containing merchant/account text outside exception value. | Sensitive text can appear in crash telemetry despite “can never” comment. | PII/financial telemetry exposure. | Narrow regex and event-surface coverage. | Allowlist telemetry fields, scrub all event surfaces, avoid raw domain errors, server-side filtering/retention review. | Synthetic PII in every Sentry field and breadcrumb; release transport inspection. | No |
| MALI-033 | Medium | Android backup | `AndroidManifest.xml:14-17`; `database_key_store.dart:11-43`; `app_database.dart:72-95`; no backup-rule XML | Android backup defaults are not disabled/scoped. Restored encrypted DB may not have a compatible keystore-backed secure-storage key and recovery offers deletion. | Device/cloud restore or OEM transfer to new hardware. | App cannot open restored financial data. | Silent restore-time data loss if user resets DB. | OS backup behavior was left implicit for encrypted files/secrets. | Disable DB auto-backup or define coordinated encrypted transfer/exclusions; present explicit restore path. | Android backup/restore across device/API levels and missing-key recovery. | No |
| MALI-034 | Medium | Architecture/dead code | `app_shell.dart:49`; `dashboard_screen.dart:33,270`; `app_providers.dart:249-266`; `financial_cache_repair_service.dart:11-80`; `supabase_*_repository.dart` | One import cycle exists. Legacy Supabase-primary/“Supabase authoritative” repair paths remain alongside Drift-authoritative architecture. | Persist a legacy dirty-cache marker or maintain dashboard/AppShell code. | Harder testing; a stale repair can overwrite pending Drift data. | Potential integrity regression during upgrade/repair. | Partial migration retained old implementations/providers. | Break shell index into neutral state module; retire/version-gate legacy repair and direct repos after migration. | Legacy dirty-marker upgrade with pending local edits; import graph gate. | No |
| MALI-035 | Medium | Documentation drift | `CLAUDE.md` schema guidance; `app_database.dart:14`; `app/docs/S4_SYNC_COMPLETE.md`, `S5_CLEANUP.md`; missing `STALE_UI_ROOT_CAUSE_REPORT.md` | Architecture docs claim completed sync and schema version 4 while code is v27 with unresolved gaps; a referenced root-cause report is absent. | Follow project docs to implement migration/sync change. | Engineers make unsafe assumptions and miss entity gaps. | Higher chance of data-loss regression. | Completion docs were not converted to living invariants/gates. | Update canonical architecture, mark historical docs, generate entity/schema matrix in CI, restore/remove missing reference. | Documentation-link/schema-version consistency check. | No |
| MALI-036 | Medium | CI/release rollout | `codemagic.yaml:1-139`; no Android/staging/migration workflows | CI only builds iOS, allows empty production config, has no SQL/RLS/Edge/admin gate, no Android release gate, migration rollout compatibility gate, or automated rollback validation. | Merge schema/client change and run current workflows. | Green CI can ship broken Android/backend combinations. | Broad release blast radius and difficult rollback. | Pipeline covers Flutter/iOS happy path only. | Add config assertions, Android release, Edge/SQL/RLS/admin, old-client compatibility, migration dry run, staged rollout and rollback runbook. | Clean-install + upgrade matrix, signed artifacts, old app against new schema/new app against old schema. | **Yes** |
| MALI-037 | Medium | Dependencies | `pubspec.yaml`; `admin/package.json`; resolver output | 88 Dart packages have newer incompatible versions; several pinned stacks have major releases available. CVE audit could not reach registries. | Resolve dependencies or build against a future Flutter/platform version. | Upgrade cliffs and unassessed security/compatibility risk. | Unknown until registry audit; potentially release relevant. | Dependency renovation/security scanning is absent from gates. | Run automated CVE/license/outdated scanning, prioritize security/platform packages, test staged major upgrades. | Dependency bot PR gates and platform compatibility matrix. | No |
| MALI-038 | Low | Fonts/assets | `app_typography.dart:12-36`; `pubspec.yaml` assets; `app/assets/` | Alexandria/IBM Plex Sans are requested through Google Fonts without matching declared font families; assets total ~16 MiB with large onboarding images. | First offline launch or constrained network/device. | Font fallback/layout shift; larger install/startup I/O. | Minor privacy/network call risk if runtime fetch occurs. | Bundled assets and runtime font API are not aligned/optimized. | Bundle/declare exact fonts, disable runtime fetching, compress/resize images and measure APK/IPA. | Offline typography golden; asset-size budget. | No |
| MALI-039 | Low | Debug diagnostics | `duplicate_trace_service.dart:22-82,97-149,171-235`; `app_shell.dart:548-560` | Debug trace logs amounts, merchants, local/server IDs and account names; several SQL diagnostics interpolate DB-derived IDs directly. | Run debug build with duplicate transactions or malicious imported identifiers. | Developer logs contain financial data; diagnostic query can be malformed. | Local debug data exposure/possible local diagnostic SQL injection. | Forensics were embedded in automatic startup. | Make explicit opt-in, redact/hash data, parameterize all SQL, and expire diagnostics. | PII log snapshot and hostile import-ID test. | No |
| MALI-040 | Low | Flutter test isolation | Full `flutter test` output; multiple DB tests | Suite repeatedly warns that multiple `AppDatabase` objects share one `QueryExecutor`. | Run full suite; inspect Drift warnings. | Tests can interfere or pass for the wrong reason. | False confidence in DB behavior. | Harness creates multiple wrappers around one executor without Drift's intended isolation. | One DB owner per executor/test, close deterministically, fail CI on warnings. | Randomized order/repeat/shard suite. | No |
| MALI-041 | Low | Admin test quality | `admin/tests/admin-authorization.test.mjs:39-45`; `functions/parser-test/index.ts:57-76` | Static test assumes double quotes and fails despite auth→admin→parser ordering being correct. | `cd admin && npm run test:auth`. | Red CI noise can mask real failures. | No observed auth bypass. | Test asserts source spelling, not behavior/AST. | Invoke handler or use AST/quote-agnostic assertion; keep real normal-user denial test. | anon/user/admin behavior and service-role non-exposure. | No |
| MALI-042 | Low | Edge testability | `catalog-delta/index_test.ts:1-46`; `catalog-delta/index.ts:33` | Importing a pure predicate test also starts `Deno.serve`, requiring a listener. | Run Deno tests in a restricted worker/sandbox. | Suite becomes environment-blocked. | Security regression test may be skipped. | Handler startup and pure logic are in one import module. | Export handler/predicate from side-effect-free module and keep serve entry separate. | Restricted/offline Deno test gate. | No |
| MALI-043 | Low | Branding/store declarations | `Info.plist` display/name/Location description; `AndroidManifest.xml:15`; `ReportFileService:24-41`; product/task naming | Bundle/UI/report/strings mix Mali and Qirsh/قرش; iOS declares a location usage description that says location is unused. | Inspect store metadata, launcher, report filename, shortcut copy. | Confusing brand and privacy prompts/store review. | Compliance/support burden. | Rename/migration remains partial. | Choose canonical brand, update identifiers/copy/assets/docs, remove unused location declaration after dependency audit. | Built-artifact metadata snapshot. | No |
| MALI-044 | Low | Supabase metrics abuse | `migrations/0001_init.sql:28-36` | Authenticated users can insert arbitrary metrics with `WITH CHECK (true)` and no owner/rate binding. | Script repeated metric inserts with any user token. | Polluted analytics and storage/cost growth. | Availability/analytics-integrity abuse. | Write-only policy was treated as harmless. | Ingest through rate-limited function or bind user/install and constrain payload/quotas. | Abuse/rate/payload-size tests. | No |

## D. Risk matrix

Scores use 1 (best/least) to 5 (worst/most). Detectability 5 means difficult to detect before impact. Priority is the product of likelihood × impact × detectability × blast radius × recovery difficulty.

| ID | Likelihood | Impact | Detectability | Blast radius | Recovery difficulty | Priority |
|---|---:|---:|---:|---:|---:|---:|
| MALI-001 | 5 | 5 | 4 | 5 | 4 | 2000 |
| MALI-002 | 3 | 5 | 5 | 3 | 4 | 900 |
| MALI-003 | 3 | 5 | 3 | 5 | 4 | 900 |
| MALI-004 | 4 | 5 | 4 | 5 | 4 | 1600 |
| MALI-005 | 5 | 5 | 5 | 5 | 5 | 3125 |
| MALI-006 | 5 | 4 | 2 | 5 | 2 | 400 |
| MALI-007 | 3 | 5 | 5 | 4 | 5 | 1500 |
| MALI-008 | 4 | 5 | 5 | 4 | 5 | 2000 |
| MALI-009 | 4 | 5 | 5 | 4 | 5 | 2000 |
| MALI-010 | 4 | 4 | 5 | 4 | 4 | 1280 |
| MALI-011 | 4 | 5 | 4 | 4 | 5 | 1600 |
| MALI-012 | 3 | 5 | 5 | 4 | 5 | 1500 |
| MALI-013 | 5 | 4 | 3 | 4 | 4 | 960 |
| MALI-014 | 4 | 5 | 5 | 4 | 5 | 2000 |
| MALI-015 | 4 | 4 | 4 | 3 | 4 | 768 |
| MALI-016 | 4 | 4 | 4 | 3 | 4 | 768 |
| MALI-017 | 4 | 4 | 5 | 3 | 5 | 1200 |
| MALI-018 | 5 | 4 | 3 | 5 | 4 | 1200 |
| MALI-019 | 4 | 4 | 3 | 5 | 3 | 720 |
| MALI-020 | 4 | 5 | 2 | 5 | 3 | 600 |
| MALI-021 | 4 | 4 | 5 | 3 | 4 | 960 |
| MALI-022 | 3 | 4 | 5 | 4 | 5 | 1200 |
| MALI-023 | 4 | 3 | 3 | 4 | 3 | 432 |
| MALI-024 | 4 | 3 | 4 | 4 | 3 | 576 |
| MALI-025 | 4 | 4 | 3 | 4 | 3 | 576 |
| MALI-026 | 3 | 4 | 5 | 4 | 5 | 1200 |
| MALI-027 | 2 | 5 | 5 | 5 | 5 | 1250 |
| MALI-028 | 4 | 4 | 4 | 4 | 4 | 1024 |
| MALI-029 | 4 | 3 | 3 | 4 | 3 | 432 |
| MALI-030 | 3 | 3 | 3 | 3 | 2 | 162 |
| MALI-031 | 2 | 5 | 5 | 3 | 4 | 600 |
| MALI-032 | 3 | 4 | 5 | 4 | 4 | 960 |
| MALI-033 | 3 | 5 | 5 | 3 | 5 | 1125 |
| MALI-034 | 3 | 4 | 4 | 3 | 4 | 576 |
| MALI-035 | 5 | 3 | 4 | 4 | 4 | 960 |
| MALI-036 | 5 | 5 | 4 | 5 | 5 | 2500 |
| MALI-037 | 3 | 4 | 4 | 5 | 4 | 960 |
| MALI-038 | 4 | 2 | 2 | 4 | 2 | 128 |
| MALI-039 | 2 | 3 | 3 | 2 | 2 | 72 |
| MALI-040 | 4 | 3 | 4 | 4 | 3 | 576 |
| MALI-041 | 5 | 2 | 1 | 2 | 1 | 20 |
| MALI-042 | 5 | 2 | 2 | 2 | 1 | 40 |
| MALI-043 | 5 | 2 | 1 | 4 | 2 | 80 |
| MALI-044 | 3 | 2 | 3 | 4 | 2 | 144 |

## E. Missing-test matrix

| Behavior not adequately covered | Current evidence/gap | Minimum required test |
|---|---|---|
| Conflicting local owner on re-auth | Session unit tests do not run real A-expired→B DB/UI flow | Two real UIDs, retained encrypted DB, router/UI assertions and no A rows visible |
| Production config fail-closed | Tests use empty plain-test defines but not release mode | Build/run release with missing, staging, malformed and valid production values |
| Android release networking | No Android SDK/build test | Assert merged release manifest INTERNET and smoke auth/sync |
| Atomic write+outbox | Repository tests pass normal path | DB fault/kill after every statement; reopen and assert exactly one durable command |
| Pull pagination | Fixtures stay under caps | 201/501/10k rows with equal timestamps and multi-page failure/retry |
| Tombstone completeness | No active-heavy backlog test | >200 newer active rows with older tombstone; deletion must arrive |
| Ledger remote edit import | Existing-row tests focus metadata/flicker | Change every financial field remotely and assert exact local convergence |
| Ledger optimistic conflict | Payload never contains version | Two-device edit/edit/delete with deterministic resolution |
| Transaction semantic round trip | Mapping tests do not exercise ledger outbox worker end-to-end | Every type/direction/status/source through Drift→outbox→server fixture→pull |
| Planning conflicts | Conflict status is asserted but no resolution | Two-device budget/goal/bill/plan conflict UI and resolved push/pull |
| Default account switch/delete | Backfill RPC tests do not cover normal repo queue order | Existing remote default, offline switch/delete, replay and unique-index behavior |
| Sign-out while offline | Flush/wipe tests do not cover every entity/artifact | Pending parent/child/inbox/mapping/log/action; require explicit outcome/no cross-user residue |
| Data wipe completeness | Test mirrors the incomplete table list | Enumerate schema/user-owned artifacts dynamically, including filesystem/App Group |
| Capture queue kill safety | Native test only checks persistence-before-network/source equality | Kill after drain, after insert, after marker, before ack; multi-message auth failure |
| Capture concurrent/duplicate paths | Unit fixtures cover normal replay | Shortcut+Share+APNs+local fallback same payload under concurrency |
| Android process-death share/SMS | No Android tests | Real device terminated/background/reboot ACTION_SEND and SMS behavior |
| Backup completeness/consistency | Builder tests reflect the incomplete contract | Populate every table/new field, mutate during snapshot, restore new DB byte/semantic parity |
| Backup key/device restore | Crypto unit tests only | Android/iOS device transfer, missing secure key, wrong recovery code, interrupted restore |
| Account deletion saga | Credential-backed tests skipped | Time travel + fail each SQL/Storage/auth/device step + retry and full residue scan |
| Edge service-role authorization | No adversarial tests for engagement functions | anon/ordinary A/service webhook, forged B, replay, invalid table/op |
| RLS clean-install/upgrade | Two SQL scripts exist but could not run | Apply 0001–0064 then two-user CRUD/RPC/Storage isolation and downgrade compatibility |
| Notification preference parity | Planner tests are local only | Server APNs disabled types, quiet hours, locale, timezone, duplicate collapse |
| Platform notification limits | No real pending-center/alarm tests | iOS 65+, Android exact alarm denied/granted, reboot, DST, edit/delete |
| Financial cross-view invariants | Individual query tests exist | One fixture asserts headline/chart/category/merchant/budget/report parity for all types |
| Money precision | No minor-unit property suite | Randomized multi-currency arithmetic/rounding/import/export parity |
| Date boundaries | Riyadh tests exist, not all query consumers | UTC/local/Riyadh half-open boundary, DST/travel/leap/week start |
| Large-data performance | No benchmark gate | 1k/10k/100k startup, pull, dashboard, export, PDF; query/rebuild/memory budgets |
| Accessibility/localization | Component widgets only | Arabic/English, RTL/LTR, 200% text, screen reader semantics, small devices, keyboard |
| Native iOS functionality | Two source-inspection XCTest methods only | Build/run host, extension, App Intent, App Group locking, APNs routing, entitlements |
| Admin authorization | Static regex test; one false positive | Handler integration with anon, normal user, admin and service-role isolation |
| Edge unit isolation | `catalog-delta` starts a listener on import | Side-effect-free unit test in restricted Deno runtime |
| Dependency security | Registry audit unavailable and absent from CI | Reproducible CVE/license scan with release-blocking policy |
| Migration power-loss/recovery | Manual compatibility tests do not inject termination | Upgrade from every retained schema, kill after each DDL/repair, integrity check |
| Old/new client-server compatibility | No matrix | Old client against migrations 0060–0064 and new client against pre-0064 schema |

## Testing inventory and quality

- Flutter: 143 `*_test.dart` files, 908 passing tests in the full run.
- Edge: 8 `_test.ts` files. Thirty-one tests ran and passed before the side-effectful catalog test was blocked.
- Supabase: four Node contract/security test files plus two RLS SQL scripts; credential-backed cases skipped and SQL scripts not executed here.
- Native iOS: one `RunnerTests.swift` file with two source-level tests (stable persistence order and three-copy byte identity); not executed due environment.
- Android: no native test source.
- Admin: one four-case Node source-contract suite; three pass, one brittle false-positive failure.
- Integration/golden: no `app/integration_test/` directory and no screenshot-golden suite. `parser_quality_golden_test.dart` is parser fixture coverage, not visual golden coverage.
- No tests are explicitly skipped via Dart `skip: true`/`@Skip` in the searched test trees.

Passing unit tests currently overrepresent implementation/source-text contracts and mocked stores. The largest gaps are kill recovery, real signed artifacts, two-user/two-device behavior, live migration/RLS, platform permissions/limits, and large-data behavior.

## F. Release verdict

**Not safe.**

Do not distribute production iOS or Android artifacts and do not deploy the engagement/account-deletion backend as currently represented. Phase 0 below must be completed and verified against a disposable Supabase project and signed platform artifacts before reconsidering release. A clean analyzer and 908 passing Flutter tests do not mitigate the cross-account, authorization, erasure, consent, and durable-data defects.

## G. Remediation plan

### Remediation status log

Living record of remediation against the findings above. Updated after every completed
finding. "Done" = code landed on `feat/accounts-multicurrency`, project gates re-run green
(`flutter analyze` 0 issues + relevant suites), and committed.

| Finding | Status | Commit(s) | Notes |
|---|---|---|---|
| MALI-006 (Android INTERNET) | ✅ Done | (P0-QW1) | INTERNET restored in main manifest. |
| MALI-003 (fail-closed release config / no stub auth) | ✅ Done | (P0-QW2) | Release throws on missing/staging Supabase config; CI asserts config. |
| MALI-005 (account-deletion purge saga) | ✅ Done | (P0-QW3) | Migrations 0065/0066 + durable purge worker. **Deploy note:** set `PURGE_WORKER_SECRET` + vault secret; deploy 0065/0066. |
| MALI-004 (secure engagement Edge Functions + cron RPC) | ✅ Done | (P0-4) | `timingSafeEqual` service-role guard on all engagement fns; cron RPC revoked. |
| MALI-002 (local DB owner gate) | ✅ Done | `348f9a5a` | Owner gate before session admission + deferred bootstrap resolve. |
| MALI-001 (truthful revocable consent) | ✅ Done | `2c1d6637` | Consent persisted (no forced true); Privacy screen switches. |
| MALI-007 (atomic write + outbox) | ✅ Done | `24cd94b3` | Aggregate writes + outbox wrapped in one Drift transaction. |
| MALI-008 (keyset pagination + tombstone filters) | ✅ Done | `4e4c7d04` | Durable `sync_cursors`; keyset pagination in every puller. |
| MALI-009 / MALI-010 (ledger merge + canonical type/status) | ✅ Done | `b0b93256` | Field merge, conflict token, refund/status round-trip. |
| MALI-012 (per-item capture ack + atomic import) | ✅ Done | `a8f4eef9` | Lease/peek/ack drain; atomic import via `runAtomically`. |
| MALI-021 (export/clipboard privacy) | ✅ Done | `cfeb30f1` | Temp CSV deleted in `finally`; clipboard fallback asks first. |
| MALI-020 (iOS privacy manifests) | ✅ Done | `cfeb30f1` | Honest data-type + UserDefaults (CA92.1) declarations across targets. |
| MALI-015 (default-account sync via RPC) | ✅ Done | `3104e6c7` | `set_default_account` RPC path; successor enqueued on delete. |
| MALI-019 (server notification-preference authority) | ✅ Done | `8c20f8a9` | Edge fns honor `notifications_json` + quiet hours before push. |
| MALI-011 (sign-out flush/wipe completeness) | ✅ Done | `f878c2e0` | Adds `financial_import_runs` + `notification_log_events` to wipe; coverage-guard test. Residual: best-effort flush still drops offline-only pending writes (documented tradeoff). Full-suite confirmation folded into the post-MALI-018 run. |
| MALI-018 (canonical total filters) | ✅ Done | `193e590b` | Single `_financialAggregateSql` (refund-signed, confirmed-only, excluded-account) reused by every aggregate; cross-view invariant test. Codex-implemented, reviewed; corrected an over-broad single-account exclusion. Full suite 931 green. |
| MALI-014 (complete backup snapshot) | ✅ Done | `6f47d3b2` | v3 backup: +cards/categories (full-fidelity)/7 account cols/user-authored sender mappings; one-transaction snapshot isolation; preflight validation before any DELETE; conditional-delete keeps v2 restores safe; coverage-guard test. Format bump only — no DB migration. Full suite 942 green. |

| MALI-013 (Android capture is a no-op) | ❌ Open (blocker) | — | No SMS permission/receiver/listener; shared text process-memory-only; `hasSmsPermission` checks the wrong permission. Android-native; full verification needs the Android SDK. |
| MALI-016 (account-deletion referential integrity) | ✅ Done | `3cf40368` | FinancialAccountDeletionService: atomic per-relation policy (tx detach; cards/budgets archive; goals/subs reassign-to-compatible-successor or archive; active subs require an explicit decision) + dependency-summary UI + structured result; child changes mirror via outbox; rollback-on-failure. 8 service + 3 widget tests; full suite 953 green. |
| MALI-017 (card sync rollout / data loss) | ❌ Open (blocker) | — | `kUserCardsCloudV2=false` drops unassigned cards + design fields on sign-out/reinstall. Client guard doable; full round-trip needs the deployed 0064 server schema. |
| MALI-022 (multi-device planning conflict) | ❌ Open (blocker) | — | Blind LWW overwrite; conflicts left unresolved; no resolution UI. Needs server revision/conditional update + UI. |
| MALI-036 (CI/release gates) | ❌ Open (blocker) | — | CI builds iOS only; no Android/staging/migration/RLS/Edge gates; allows empty prod config. Priority 2500. |

**Phase-0 status: 18 of 23 release blockers done; 5 still OPEN** (MALI-013, 016, 017, 022, 036 — see rows above). A prior status note incorrectly said "all 23" — it conflated the audit's condensed 15-item remediation list with the 23 individual blockers; corrected here. Phase 0 is **not** code-complete until these five are closed, and not operationally closed until the deployment/native gates below are met. The 18 done items are each gate-verified (analyze clean + full suite 942 green).

### Phase-0 release-closure verification

Pass run on this workstation. iOS simulator available; **Android SDK and Docker/Supabase-local are not**, so those gates are recorded as external prerequisites, not failures.

**Verified here:**
- **Migrations 0065/0066 (static):** correctly ordered after 0064; idempotent (`create … if not exists`, `create or replace`, `cron.schedule` upsert-by-name, restated `revoke`/`grant`); all 24 tables `purge_user_data` deletes exist in prior migrations; prerequisites present (pg_cron 0033, Vault 0021+, pg_net created in-file). Delete order is FK-correct (children/satellites before parents; `capture_rate_limits` resolved before `capture_devices`; `profiles` last). **Not** executed against a live/staging DB.
- **Secret authorization (end-to-end logic):** purge worker guard extracted to `bearerSecretAuthorized` (pure, value-free) and covered by 6 Deno tests — invalid/missing/non-Bearer/empty-config → reject; exact match → authorize; constant-time. DB↔Edge consistency confirmed statically: cron RPC reads Vault `purge_worker_secret` and posts `Bearer`, Edge reads env `PURGE_WORKER_SECRET`. Live secret **existence** not verifiable here.
- **iOS privacy manifests (built product):** wired `ShareBankMessage` + `BankMessageShortcuts` manifests into their Xcode targets (`project.pbxproj`; `plutil -lint` + `xcodebuild -list` clean). Simulator build confirms `Runner.app/PrivacyInfo.xcprivacy` and `Runner.app/PlugIns/ShareBankMessage.appex/PrivacyInfo.xcprivacy` are packaged (compiled bplist, correct data types).
- **Native iOS smoke:** `flutter build ios --simulator` succeeded; app installed and launched on the simulator (PID alive, no crash, no crash reports).
- **Flutter gates:** `flutter analyze` 0 issues; full suite **942 passed** (one contention-induced isolation flake — MALI-040 — reproduced only under heavy load, passes in isolation; not a regression).

**Shipping architecture — App Intent / Shortcut (resolved):** the production "Process Bank SMS" flow is the `PostBankStatusIntent` App Intent + `AppShortcutsProvider` in `BankMessageShortcuts.swift`, which is **compiled into the Runner (main app) target** and indexed in the built product's `Runner.app/Metadata.appintents` (`extract.actionsdata`/`root.ssu.yaml` reference `PostBankStatusIntent`). Runner holds the `group.com.youssefsafwat.mali` App Group entitlement, so the in-app intent captures via `SharedCaptureStore`. The separate `BankMessageShortcuts.appex` **App Intents Extension was obsolete** — never embedded, duplicating the same source — and has been **removed** (target, product, build phases/configs, group, and dead sibling files deleted; the shared `BankMessageShortcuts.swift` re-homed to the Runner group). Shipping iOS targets are now exactly **Runner + ShareBankMessage**.

**Privacy manifests — target-accurate (resolved):**
- **Runner**: full set — EmailAddress/Name (Google/Apple sign-in), PhoneNumber (profile), OtherFinancialInfo, DeviceID (APNs/install id), CrashData (Sentry) + FileTimestamp (C617.1) + UserDefaults (CA92.1). Verified present in `Runner.app`.
- **ShareBankMessage**: **tailored** to what the extension actually does — it only enqueues bank-SMS text into App Group UserDefaults (`ShareViewController` → `SharedCaptureStore.enqueue`, no network, no auth/crash/file-timestamp APIs). Declares **only** `OtherFinancialInfo` (Linked, non-tracking) + `UserDefaults` (CA92.1). The inaccurate Email/Name/Phone/DeviceID/CrashData/FileTimestamp declarations were removed. Verified in the built `.appex`.

**Packaging regression guard:** `app/tools/verify_ios_packaging.sh` inspects the built `Runner.app` and asserts: main app + each embedded `.appex` carry `PrivacyInfo.xcprivacy`; every expected extension is embedded; **no obsolete extension** is embedded; exact extension count; correct bundle ids; Mach-O executables. Positive run passes; a planted obsolete `.appex` is correctly rejected. Run it after any iOS build before release.

**External release prerequisites — live evidence still required (do NOT mark done without it):**

| # | Action | Environment | Acceptance criterion | Failure signal | Rollback / recovery |
|---|---|---|---|---|---|
| 1 | Apply migrations 0065 + 0066 | Disposable/staging Supabase (Docker or hosted) | `account_purge_queue` exists + RLS on; `purge_user_data`/`run_purge_scheduled_deletions`/`run_cron_daily_reminders` execute revoked from public/anon/authenticated, granted service_role; cron job `purge-scheduled-deletions-job` scheduled `30 3 * * *` | Migration error, or `has_function_privilege('anon', …)` true, or job absent | `cron.unschedule('purge-scheduled-deletions-job')`; drop the two functions / restore prior `purge_user_data`; `drop table account_purge_queue` |
| 2 | Set + **match** `PURGE_WORKER_SECRET` (Edge secret) and Vault `purge_worker_secret`; confirm Vault `project_url` | Supabase project (secrets + Vault) | A cron-triggered POST reaches `purge-scheduled-deletions` and returns non-403; a wrong Bearer returns 403 (proven in logic by `purge_worker_auth_test.ts`) | Purge never runs; function logs "Vault secrets not configured" or 403s the cron call | Rotate both to a new matching value; re-deploy the function |
| 3 | Android build + manifest/permission/notification/boot-reschedule verification | Machine with Android SDK + emulator/device | Signed build installs; INTERNET present; notifications schedule; reschedule after reboot | Missing permission, no notifications, lost schedule after reboot | Fix manifest/receivers; rebuild |
| 4 | APNs push registration + routing | Physical iOS device + paid Apple Developer (App Groups/APNs) | Device registers a token; budget/goal/streak/bill push arrives and routes | No token / no delivery | Check entitlements, APNs env, device token upload |
| 5 | App Store archive privacy report | Signed Release archive (paid account) | Xcode "Generate Privacy Report" lists Runner + ShareBankMessage manifests with the declared types | Missing/again-inaccurate manifest in archive | Re-run `tools/verify_ios_packaging.sh` on the archived app; fix wiring |
| 6 | Interactive on-device smoke | iOS device/simulator + backend | Share-sheet capture enqueues; sign-out wipes; backup upload/download + passphrase restore round-trips | Data leak, lost data, or restore failure | Covered in logic by unit tests; fix per failing surface |

**MALI-040 (known flake, not expanded):** `local_notification_service_tracking_test.dart` failed once under heavy CPU contention (concurrent simulator build) with `LateInitializationError` on the notification plugin singleton — a test-isolation issue (multiple `AppDatabase` on one executor). It **passed in isolation (10/10)** and on a clean full re-run (942). Tracked as a Phase-1 test-isolation follow-up; not re-triggered on the clean closure run.

### Phase 0 — release blockers

1. Fail production builds closed on Supabase/environment configuration; remove stub auth from release.
2. Restore Android release INTERNET and establish a signed Android build/smoke gate.
3. Replace forced cloud/AI consent with truthful, revocable consent and align all disclosures.
4. Enforce local DB ownership before session admission; prove A→B isolation.
5. Lock down engagement/reminder Edge Functions and cron RPC; add service-only, replay-safe authorization.
6. Implement a scheduled, idempotent, monitored account-deletion saga covering DB, Storage, auth, logs, devices, and retry.
7. Make financial writes plus outbox/dedup/counter changes atomic.
8. Implement cursor/keyset pagination and server-side active/tombstone filtering for every puller.
9. Repair ledger field merge/versioning and canonical type/status/source payloads.
10. Change native capture to lease/per-item acknowledgement and atomic local import.
11. Fix default-account sync using the server RPC.
12. Prevent sign-out/wipe from destroying unsynced/unsupported data or carrying artifacts into another account.
13. Complete backup schema/transactional snapshot behavior.
14. Resolve financial-total invariants and duplicate notification authorities.
15. Correct iOS privacy manifests/store disclosures and plaintext export cleanup.

### Phase 1 — data integrity and security

- Add local ownership partitioning, FKs/relation policies, fixed-precision money representation, atomic account deletion/reassignment, and transactional migrations.
- Encrypt/minimize App Group data, move secrets to shared Keychain, rotate/revoke device credentials, and comprehensively scrub telemetry.
- Version every local/cloud/export/backup payload and provide migration/repair tooling with auditable user outcomes.
- Add a complete data inventory used by wipe, export, backup, purge, retention, and privacy declarations.

### Phase 2 — sync and reliability

- Add durable cursors, conditional revisions, idempotent event IDs, dead-letter queues, operation coalescing, and user-visible conflict recovery.
- Consolidate specialized smart-inbox/mapping/gamification/log flows onto documented reliability primitives.
- Replace blind LWW with explicit per-entity policy and cover multi-device/clock-skew/app-kill cases.
- Retire Supabase-primary legacy repositories/cache repair after a one-time, versioned migration.

### Phase 3 — UX and performance

- Table-scope Riverpod invalidation, batch SQL, eliminate N+1 pulls, adapt sync cadence, and add performance telemetry without financial PII.
- Stream/page exports and reports; cap memory and clean artifacts immediately.
- Enforce notification platform limits/capabilities, edit-time rescheduling, redacted lock-screen content, and clear offline/sync/conflict UX.
- Complete Arabic/English, RTL, accessibility, text-scaling, keyboard, small-screen, and restoration testing.

### Phase 4 — hardening and polish

- Align Mali/Qirsh branding and native/store metadata; remove unused location declaration.
- Bundle exact fonts, disable runtime font fetching, compress large assets, and set artifact-size budgets.
- Add dependency/security/license automation, Android+iOS signed pipelines, backend/migration staging, rollback rehearsals, and old-client compatibility gates.
- Convert historical audit documents into generated/live architecture and schema contracts.

## Could not verify

1. **Live Supabase schema, RLS, functions, secrets, cron, Vault, Storage, or migration parity:** no linked-project credentials/network authority were available. All database conclusions are about repository migration/function source only and are **unverified against live**.
2. **Whether migrations 0001–0064 have deployed, particularly 0064:** no claim of live parity is made.
3. **Credential-backed deletion and two-user tests:** five Node cases skipped because Supabase URL/keys were absent.
4. **SQL RLS scripts and clean migration chain:** Docker API access was denied, so `supabase start/db reset/test` could not run.
5. **iOS compilation, XCTest execution, simulator behavior, App Intent/Share signing, APNs delivery, and App Store archive privacy report:** Flutter global cache/CoreSimulator access was blocked by the sandbox.
6. **Android merged manifests, compilation, R8/ProGuard, exact alarms, boot behavior, SMS policy, backup/restore, and real device behavior:** Android SDK was not installed.
7. **Live APNs, Gemini, Sentry ingestion/scrubbing, OAuth provider consoles, deep-link redirect allowlists, and Google/Apple signing configuration:** external service credentials/consoles were unavailable.
8. **Admin deployed middleware/cookies/service-role environment and live allowlist:** source was inspected; no deployed instance was accessed. A local `.env.local` exists but is not Git-tracked; values were not reported.
9. **Registry CVEs/licenses and definitive current package status:** registry DNS was unavailable. Only resolver-reported version lag was observed.
10. **Production signing, store privacy questionnaires, universal-link domain files, Play exact-alarm policy approval, TestFlight/Play rollout, monitoring dashboards, backup retention, and rollback execution:** these are external operational states.
11. **Coverage percentage:** no coverage run/configured threshold was requested or available from the completed full-suite output.
12. **The known `widget_test.dart` timer leak:** it was explicitly checked but did not reproduce in the full suite or isolated run; therefore it is not reported as a current failure.
13. **Pixel-perfect visual/accessibility behavior on all device sizes/locales:** source/widget tests were reviewed, but native builds and a full device matrix were unavailable.

## Verified architecture invariants and positive controls

- UI financial reads are routed to Drift, not normal Supabase repository reads.
- Remote catalog is content; parser/categorization business logic remains in Dart.
- Parser isolate has a two-second timeout/termination path.
- Feature rollout bucketing uses SHA-256 rather than `hashCode`.
- Category keys are stable strings and sync maps keys across devices.
- Drift schema version is centralized in `app_database.dart` (value 27).
- No global HMAC secret was found embedded in the client.
- SQLCipher availability is verified before use and the app refuses plaintext fallback.
- Main ledger/planning engines perform push before pull.
- Core financial RLS migration text is owner-scoped.
- iOS shared capture store copies are byte-identical.
- Notification IDs use deterministic SHA-derived values rather than runtime hashes.
- Backend capture acknowledgement normally follows local import, and server capture identity/fingerprint tests cover important replay races.

These controls should be preserved while remediating the release blockers.
