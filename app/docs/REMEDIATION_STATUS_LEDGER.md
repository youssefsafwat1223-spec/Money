# Mali — Remediation Status Ledger

Single source of truth for the state of every finding from `FULL_APP_AUDIT.md`
(MALI-001…044) and `FINAL_FULL_PRODUCTION_AUDIT.md` (MALI-045n…077n). **No finding
is ever removed from this ledger.** Updated at the end of every phase.

- **Baseline HEAD:** `e2679d0e` (feat/phase1-data-integrity)
- **Last updated:** **Phase 5 Batch 6 closure correction — 2026-08-05.** The Batch-6
  documentation surfaced four production-code defects INSIDE Phase-5 scope; they
  were fixed (not deferred): (1) MALI-019 — `evaluate-gamification` push now
  policy/quiet-hours/privacy gated; (2) MALI-061n — goals/achievements coordinated,
  streak/bill server cron retired, text-derived captureLight/budget ids removed;
  (3) MALI-060n — `process-ios-sms` server-consent + bounded-body hardened. analyze
  0, full suite 1258, deno 76/0/2-ignored, node 21/0 (+23 credential-gated skips),
  migration lint PASS, ci_gates PASS. Prior Batch-6 was **documentation, reconciliation,
  external-gate inventory, formal closure** — documentation & verification only; no
  production code changed. Authoritative Phase-5 contract spec created:
  `PHASE_5_SECURITY_PRIVACY_NOTIFICATIONS.md` (native storage, Android, telemetry,
  exports, AI-endpoint matrix, notification authority/terminology/scheduling,
  backend security, gamification 8-layer authority + the 0074 atomic-award
  contract). Verdict: **Phase 5 code complete — locally verified; signed-device,
  Android, APNs, store-policy, and live-PostgreSQL verification pending.**
  Migrations 0068–0074 undeployed; `kServerRevisionCas=false`; migration 0070
  authority inactive. Prior — **Phase 5 Batch 5 (backend, RLS, SECURITY DEFINER,
  metrics, purge, gamification, endpoint hardening) Code complete · Locally
  verified — 2026-08-05.** MALI-075n (SD search_path — dead handle_new_user dropped, prune
  fixed; owner-bound rate-limited `record_metric` RPC replacing `with check
  (true)`; purge coverage extended to AI-idempotency/engagement/metrics-quota),
  MALI-044 (dead merchant-feedback retired — auth + 410), MALI-024 backend
  confirmation (dormant record_engagement_event hardening asserted; activation
  gate documented). Migration 0072 (additive, undeployed, lint PASS).
  `4e927db5`/`6ddd5aaa`/`975af849`. analyze 0, flutter suite green, deno 68/0
  (+2 ignored), 9 backend contract tests. Live RLS/RPC/purge under real Postgres
  external. **Batch-5 closure reconciliation (2026-08-05):** gamification gap
  found & fixed — 0062 owner aggregate-writes let clients forge their own
  XP/streak/achievements; **0073** makes the aggregates read-only to clients
  (server-only authoritative writer). **Idempotency closure (2026-08-05):** the
  first fix claimed the ledger row and mutated XP in SEPARATE Edge calls (separate
  transactions) — a crash between them LOST the award. **0074** folds the claim +
  XP/level/achievement/eligibility into ONE Postgres transaction (SECURITY DEFINER
  `award_gamification_for_transaction`, server-role only, ownership-checked) →
  exactly-once AUTHORITATIVE mutation; APNs delivery is after commit with a stable
  collapse id (idempotent, retryable). Client verified pull-only; engagement
  submission already bounded. `9fdd30e7`/`c4f2aea0`. Batch 6 not started.
  Prior — **Phase 5 Batch 4 (notification authority, policy,
  deduplication, lock-screen privacy, scheduling limits, Android receiver tail)
  Code complete · Locally verified — 2026-08-05.** MALI-061n (stable event
  identity off display text; budget local-primary/server-fallback coordination),
  MALI-019 (lock-screen privacy contract + log-leak fix; honest delivery states),
  MALI-025 (iOS pending-capacity + rolling-window scheduler), MALI-068n (Android
  receiver native-epoch timestamp authority + inexact alarms + durable clear),
  and the Batch-3 Android consent-propagation tail. `1e2d88f4`/`1e217ce3`/
  `224394fd`/`9128589e`/`8337202e`/`5b2c771b`. analyze 0, flutter suite green,
  deno 68/0 (+2 ignored). Native Android compile/receiver/alarm/device external.
  **Batch-4 closure reconciliation (2026-08-05):** three contracts proven with
  behavioral tests + two gaps fixed — the silent-`now` timestamp default
  (`d72e5785`), the sign-out reminder-cancel gap (`f7cbe727`), plus the explicit
  capture-notification authority (`c3ffc673`). See the `[B4-closure]` notes on
  MALI-019/061n/068n. Batches 5–6 not started.
  Prior — **Phase 5 Batch 3 (AI endpoint authentication, verified
  identity, consent, rate limiting, abuse controls) — 2026-08-05.** MALI-060n: parse-sms/bank-discovery/enrich-merchant
  now require a server-verified identity (device secret or user JWT, never
  caller install_id), enforce consent server-side (fail-closed), rate-limit +
  idempotency on the verified identity, bounded payloads, upstream timeouts, and
  a typed error envelope; migration 0071 (consent cols + idempotency RPCs, NOT
  deployed) + set-device-consent + client wiring. Endpoint matrix in the master
  plan. deno 67/0 (+2 credential-gated real-backend ignored), migration-lint
  PASS. Live migration apply + RPC concurrency + Android consent-push external.
  Batches 4–6 not started.
  Prior — **Phase 5 Batch 2 (telemetry, logging, temp files, export
  privacy, merchant logos) — 2026-08-05.**
  MALI-032 (allowlist telemetry boundary `bff0f1d8`), MALI-065n (managed
  temp-export lifecycle `2d1072f6`, iOS simulator build), MALI-071n (merchant-
  logo consent gate `08e7ca0d`), and the logging/privacy portions of MALI-039 +
  MALI-075n (central redacting `debugPrint` sink + `Diag` `0010b037`; merchant
  edge functions reviewed — no sensitive logging). analyze 0, targeted suites
  green. Batches 3–6 of Phase 5 not started.
  Prior — **Phase 5 Batch 1 (native storage + Android backup) — 2026-08-04:**
  MALI-033/031 + the native-storage portion of MALI-068n: Android Auto Backup
  disabled + durable capture-queue writes (`5c88417c`); iOS shared-Keychain
  secrets + AES-encrypted capture queue + aux-queue locking (`30b4f3fc`, iOS
  simulator build + `xcodebuild test` 6/6).
  **Phase 4 CLOSED (locally verified)** — spec `PHASE_4_FINANCIAL_SEMANTICS.md`
  (analyze 0, full suite 1181). Phase 3: `PHASE_3_SYNC_CLOSURE.md`.

> **Phase 2 note — bug found & fixed during implementation (not a new finding):**
> `drift_repository_support.dart` `userSettingsFromRow` hard-coded both consent
> flags to `true`, so runtime consent was ALWAYS ON and revocation was a no-op
> (the re-audit's MALI-001 verdict under-counted this). Fixed as part of the
> MALI-001/059n remediation (the read now reflects the persisted versioned state).

### Approved product decisions
- **MALI-059n (consent default) — APPROVED 2026-07-30:** Cloud processing and AI
  processing both **default OFF**; they are **separate explicit opt-ins**; the
  local/offline app is fully usable without either; consent is **never inferred**
  from onboarding completion, authentication, restore, migration, or previous
  default values; existing installs that never made an explicit choice **migrate
  to OFF**; revocation takes effect **immediately and fails closed**. A versioned
  consent schema distinguishes unset / explicitly-accepted / explicitly-declined
  (not a default-true boolean).
- **Plan scope (MALI-048n) — APPROVED 2026-08-04:** an empty stored plan scope
  permanently means the documented `allExpenses` mode. There is deliberately NO
  separate `unconfigured` state, NO `scope_mode` column, and NO new UI for the
  distinction — this **preserves the existing approved product contract**, it is
  not deferred work. (Supersedes the Batch-3 "deferred product decision" note.)
- **MALI-046n — CLOSED (locally verified):** on-device production-path
  confirmation remains part of external gate 6 (per Phase-1 approval).
- **MALI-045n — Code complete · Locally verified:** final closure requires the
  on-device backup→restore round-trip in external gate 6.

**Status vocabulary:** Not started · In progress · Code complete · Locally verified ·
External verification pending · Closed · Decision required · Blocked.

**Classification (actionable scope):** C=Code · T=Test · D=Docs · P=Product/policy ·
X=External-only · DUP=Duplicate · AF=Already-fixed (fresh evidence). VC findings from
the re-audit are recorded Closed (local) with any external tail tracked separately.

## Legend for "Phase"
P1 migrations/restore · P2 lifecycle/consent · P3 sync · P4 financial · P5 security/notif/native ·
P6 backup/DB/reliability · P7 CI/test/arch/docs · P8 MALI-026 · P9 external validation · — none.

## Master ledger

| Finding | Sev | Class | Phase | Status | Subsumed-by / Notes |
|---|---|---|---|---|---|
| MALI-001 | Crit | C+P | P2 | Code complete · Locally verified | explicit versioned default-OFF consent; read-clamp bug fixed; `89db9f09` |
| MALI-002 | Crit | X | P9 | Locally verified | on-device 2-user smoke = gate 6; legacy-null-owner window = MALI-070n |
| MALI-003 | Crit | X | P9 | Locally verified | release-binary fail-closed proof = gate 3/10 |
| MALI-004 | Crit | X | P9 | Locally verified | live Edge adversarial = gate 12 |
| MALI-005 | Crit | X | P9 | Locally verified | live purge time-travel = gates 1/2/12; purge coverage lows = MALI-075n |
| MALI-006 | High | X | P9 | Code complete (device pending) | merged-manifest+smoke = gate 3 |
| MALI-007 | High | — | — | Closed | atomic write+outbox re-verified |
| MALI-008 | High | C | P3 | Code complete · Locally verified | periphery closed via MALI-072n durable sender-mapping sync (keyset + tombstones + typed errors); `96993c5e` (batch 5) |
| MALI-009 | High | C | P3 | Code complete · Locally verified | versioned canonical payload preserves type/direction/status/source; base-token round-trip; `124fd83b` (batch 4); live 2-device = external |
| MALI-010 | High | C | P3 | Code complete · Locally verified | withdrawal/refund/unknown/source round-trip via canonical metadata (no lossy debit/credit collapse); `124fd83b` (batch 4) |
| MALI-011 | High | C | P2 | Code complete · Locally verified | atomic wipe + unsynced inventory (flush→re-check→discard); `374560ff` |
| MALI-012 | High | X | P9 | Locally verified | on-device kill = gate 6/9 |
| MALI-013 | High | C+X | P5/P9 | Code complete (device pending) | apply()-in-receiver = MALI-068n; gates 9/10/11 |
| MALI-014 | High | C | **P1** | Code complete · Locally verified | closed by MALI-045n fix; on-device round-trip = gate 6 |
| MALI-015 | High | — | — | Closed | RPC path re-verified (client+server) |
| MALI-016 | High | — | — | Closed | atomic per-relation deletion re-verified |
| MALI-017 | High | C | P2 | Code complete · Locally verified | local-only cards in the inventory guard (interactive path); delete/reset gate behind explicit confirmation; remote/cross-UID wipe for isolation; `374560ff` |
| MALI-018 | High | C+T | P4 | **Closed · locally verified** | provider tier complete across repository/header/Home/plan/budget-ring/budget-detail/budget-history/report/bill/subscription/card/account-detail/installment; dormant Supabase aggregate tier retired; locked by the cross-surface invariant suite. Spec: `PHASE_4_FINANCIAL_SEMANTICS.md`. Live two-device/device = external |
| MALI-019 | High | C | P5 | Code complete · Locally verified (device external) | server-side preference enforcement (edge `notification_policy.ts`, per-type + quiet hours) already present; Batch-4 added the lock-screen privacy contract (hideLockScreenContent pref, `redactedContentFor` generic content per type, in-app inbox keeps real content), removed a title-logging leak (§9), and honest delivery states confirmed (notification_logs has NO 'delivered'). `224394fd` (P5-B4). [B4-closure] Closure: sign-out reminder-cancel gap FIXED (`cancelScheduledReminders` wired to the residue purge; `f7cbe727`); reconciliation (edit keeps stable id→OS-replace, disable/delete plan nothing) + quiet-hours boundary/midnight-crossing + managed-reminder-id tests. **[B6-closure]** gamification push gap FIXED: `evaluate-gamification` now routes the post-award push through `loadNotificationPolicy`/`isPushAllowed('achievement')` (per-type + quiet hours) + `hideLockScreenContent` redaction + valid-token/ownership + coordinated fallback; eligibility stays exactly-once in the 0074 RPC, delivery best-effort after commit. deno gamification-policy tests + static contract. Device lock-screen render external |
| MALI-020 | High | X | P9 | Locally verified | archive privacy report = gate 5 |
| MALI-021 | High | C | P6/P7 | Not started (scope Closed) | dead file + PDF sweep = MALI-076n/065n |
| MALI-022 | High | C | P3 | Code complete · Locally verified · **live CAS external-pending** | server revision CAS migration 0068 `4a2da692` + universal resolver all 12 `de672bc0` + client CAS plumbing gated OFF `0e52da68` (batch 3); activation blocked on 0068 staging verification |
| MALI-023 | Med | C | P3 | Code complete · Locally verified | typed failure classes + dead-letter + bounded backoff + re-arm; `d6820285` (batch 2) |
| MALI-024 | Med | C | P3 | Code complete · Locally verified | server-authoritative idempotent engagement events (migration 0070 + locked-down record_engagement_event RPC); client aggregate-total upload removed (tamper vector gone); durable event outbox + exactly-once + projection; `bc0e0ddb` (batch 5). **P5-B5 confirmation:** contract tests assert record_engagement_event derives owner from auth.uid(), rejects unauthenticated/unknown-type/unsupported-version, server-fixed CASE award (no client XP), idempotent (ON CONFLICT DO NOTHING), SD + fixed search_path; the path is EFFECTIVELY DORMANT via 0070 undeployed (client enqueues+submits but the RPC 404s → no award; the legacy transaction-triggered authority is the sole active award path). **Batch-5 closure — gap found & fixed:** the earlier report wrongly accepted 0062's owner aggregate-writes; a normal client could forge its own XP/level/streak/achievements. **0073** removes the owner insert/update policies + revokes write grants (aggregates read-only to clients; server service-role is the sole authoritative writer); the client is pull-only (verified). Legacy award made **exactly-once as a single-transaction authoritative mutation**: the first fix (`9fdd30e7`) claimed the ledger row and mutated XP in SEPARATE Edge calls (separate transactions) — a crash after the claim committed but before the XP update LOST the award permanently; **0074** (`c4f2aea0`) folds the claim + XP/level/achievement/notification-eligibility into ONE Postgres transaction (`award_gamification_for_transaction`, SECURITY DEFINER, fixed search_path, ownership-verified, service_role-only), so a crash rolls the claim back with the award, a lost-response/duplicate/concurrent retry reconstructs the stored canonical result, and no partial state is possible. APNs delivery happens AFTER commit, keyed by a stable per-transaction collapse id (best-effort, idempotent, retryable — a send failure never rolls back or re-awards). Ledger purge-covered. Client engagement submission already bounded (retry→dead-letter, projection preserves progress, pull reconciles). Activation gate (deploy 0070 + disable legacy in the SAME release, else double-award) documented. Live RLS/concurrency = external |
| MALI-025 | Med | C | P5 | Code complete · Locally verified (device external) | NotificationCapacityPlanner (pure): internal cap below iOS's ~64 max, immediate-alert reserve, importance-then-nearest-due, past-due drop, rolling window over app-managed ids only; schedulePlannedNotifications reads the live pending set, applies {schedule,cancel}, and verifies the actual pending set (safe count only). 5 planner tests. `9128589e` (P5-B4). On-device 64-limit behavior external |
| MALI-026 | Med | C | **P8** | Not started | separate financial-storage project |
| MALI-027 | Med | C | **P1** | Code complete · Locally verified | closed by MALI-046n fix |
| MALI-028 | Med | C | P4 | **Closed · locally verified** | half-open `[from, to)` for every Phase-4 interval (repo aggregates, budget/plan/report periods, transactions/dashboard lists, appendix, comparison); no epsilon/`23:59:59`/inclusive-last-instant anywhere; boundary rule enforced for every new/changed caller. Spec §F. Live device = external |
| MALI-029 | Med | C | P7 | Not started | global invalidation breadth |
| MALI-030 | Med | C | P7 | Not started | streamed reports/memory |
| MALI-031 | Med | C | P5 | Code complete · Locally verified (device-external) | secret material (device secret + capture-queue key) moved to a shared Keychain access group; capture queue AES-GCM encrypted at rest (legacy-plaintext migration, corrupt fail-closed no-delete); device secret invalidated on wipe; flutter_secure_storage default group preserved. `30b4f3fc` (P5-B1). iOS simulator: build + `xcodebuild test` 6/6 incl. behavioral encryption/secret/purge tests. External: shared-Keychain cross-process app↔extension under a real provisioning profile + `keychain-access-groups` entitlement |
| MALI-032 | Med | C+T | P5 | Code complete · Locally verified | allowlist telemetry boundary — beforeSend AND beforeBreadcrumb drop all free-form text (exception messages, breadcrumbs, threads, request, user), keeping only allowlisted tags/extra/contexts + exception class name + stack frames (vars stripped) + structured `TelemetryCodes`; native auto-breadcrumbs disabled (the Dart boundary cannot scrub native-SDK crashes — documented residual); behavioral canary tests inject every sensitive class through message/cause/stack-vars/breadcrumb/tag/context/extra/URL/db-error and assert none survive the serialized event. `bff0f1d8` (P5-B2). Native-SDK scrubbing parity external |
| MALI-033 | Med | C | P5 | Code complete · Locally verified (device-external) | Android Auto Backup + device-transfer disabled (`allowBackup="false"`, `fullBackupContent="false"`) — the Keystore-bound DB + raw-SMS queue + secrets would restore incoherent; recovery is via the app's own encrypted backup. `5c88417c` (P5-B1); manifest static-verified (`android_backup_policy_test`). External: on-device restore attempt confirms exclusion |
| MALI-034 | Med | C | P7 | Not started | import cycle + legacy repair retirement |
| MALI-035 | Med | D | P7 | Not started | CLAUDE.md drift (incl. dangerous "all optional") |
| MALI-036 | Med | X+C | P7/P9 | Code complete (limits) | CI wiring = MALI-066n; hosted run = gate 8 |
| MALI-037 | Med | C | P7 | Not started | CVE/license gate |
| MALI-038 | Low | C+T | P7 | Not started | font bundling (+ test MALI-067n) |
| MALI-039 | Low | C | P5/P7 | Code complete · Locally verified | central redacting diagnostic sink — `main()` rewires the global `debugPrint` to redact (shared `PrivacyRedactor`) + length-bound every line (all call sites, plugins, future code) in debug AND release; `Diag.error`/`Diag.log` sanctioned structured API; SQL already parameterized (custom SQL interpolates only fixed table identifiers, never values). `0010b037` (P5-B2) |
| MALI-040 | Low | T | P7 | Not started | test isolation (subsumed by MALI-067n) |
| MALI-041 | Low | T | P7 | Not started | admin auth test (subsumed by MALI-066n/067n) |
| MALI-042 | Low | T | P7 | Not started | Edge unit isolation (MALI-066n) |
| MALI-043 | Low | P+D | P7 | Decision required | canonical brand name (Mali vs Qirsh) |
| MALI-044 | Low | C | P5 | Code complete · Locally verified (live-backend external) | dead/no-op endpoint retired: merchant-feedback (never-implemented `TODO`, anonymous, fake-success) now requires a bearer token and returns an explicit 410 `retired` → `enrich-merchant`, with a reuse guard; its unwired client (`flushIfReady` never called) noted. The metrics `with check (true)` policy is removed under MALI-075n (0072). `6ddd5aaa` (P5-B5) |
| MALI-045n | High | C | **P1** | Code complete · Locally verified | FK-safe restore (full parents + suspend-correctly + sanitize + verify); 5 regression tests; on-device round-trip = gate 6 |
| MALI-046n | High | C | **P1** | Closed · locally verified | `enableMigrations:false` → pipeline owns user_version; 5 regression tests; on-device path = gate 6 |
| MALI-047n | High | C | P4 | Code complete · Locally verified | header total now canonical net expense over the complete dataset (`transactionsPeriodTotalProvider`), pagination-independent, confirmed-only, refund-netted, single-currency; bespoke `TransactionsView` folds removed; `2052687d` (Batch 2). Device UI spot-check external |
| MALI-048n | High | C | P4 | Code complete · Locally verified | canonical plan spending: half-open window, plan-currency isolation (no cross-currency sum, incl. linked rows), refund netting (no raw SUM), confirmed-only, excluded-account policy for all-expenses scope, UNION account/card membership, blank-currency fail-closed, list==total; empty scope preserved as documented all-expenses; `4fa413a9` (Batch 3). Device UI spot-check + unconfigured-scope product decision external |
| MALI-049n | High | C | P4 | Code complete · Locally verified | dashboard ring uses the budget's OWN stored period (not the dashboard filter) via one canonical resolver shared with budget detail/reports/alerts; genuine half-open Saturday week; ring == detail == repo consumption; refund/excluded/currency identical; `4dc0d190` (Batch 3). Device UI spot-check external |
| MALI-050n | High | C | P4 | Code complete · Locally verified | Home category totals sourced from canonical `categoryBreakdown` (refund netting, status, excluded-account, half-open month); cannot disagree with the adjacent budget chip for the same scope; bespoke `getAll()` fold removed; `2052687d` (Batch 2). Provider is not currently UI-wired (dropped by the Calm-Capital redesign) — closed at the provider tier to hold the invariant. Device UI spot-check external |
| MALI-051n | High | C | P3 | Code complete · Locally verified | durable parked_child_rows + drain; cursor never skips; `acf9ca99` (batch 1) |
| MALI-052n | High | C | P3 | Code complete · Locally verified | outbox coalescing/re-basing `d6820285` (batch 2) + universal conflict policy/resolver for all 12 entities `de672bc0` (batch 3); live 2-device = external |
| MALI-053n | High | C | P2 | Code complete · Locally verified | flush now covers child + smart-inbox + notif-log + sender-mapping outboxes; `374560ff` |
| MALI-054n | High | C | P2 | Code complete · Locally verified | native+file residue purge on every destructive path; fail-closed admission; `374560ff`. Device execution = gate 6/9 (external) |
| MALI-055n | Med | C | P3 | Code complete · Locally verified | dedicated default-account command (no broad rewrite; stale device can't roll back fields) + guarded accounts update (base token now carried); `58614ad4` (batch 4) |
| MALI-056n | Med | C | P3 | Code complete · Locally verified | versioned canonical payload (v2) + documented compatibility + future-version dead-letter; `124fd83b` (batch 4) |
| MALI-057n | Med | C | P3 | Code complete · Locally verified · **live CAS external-pending** | pull/push base compare + universal per-entity policy; `de672bc0`/`0e52da68` (batch 3) |
| MALI-058n | Med | C | P6 | Not started | SQLCipher key in DB + backup |
| MALI-059n | Med | P+C | P2 | Code complete · Locally verified | decision implemented (default OFF, separate opt-ins, migrate-to-OFF, versioned state, device-local, restore resets); `89db9f09` |
| MALI-060n | Med | C | P5 | Code complete · Locally verified (live-backend external) | AI/paid endpoints (parse-sms, bank-discovery, enrich-merchant) no longer trust a caller-supplied install_id. Shared `_shared/ai_endpoint.ts`: server-verified identity (device secret via `verifyDevice`, else real user JWT; install_id alone → `authentication_required`), fail-closed server-side consent (AI for parse/discovery, cloud for enrich), atomic rate limit keyed on the verified identity (`bump_capture_rate_limit`), typed 13-code error envelope (no raw message/upstream body), bounded bodies + text-length caps, upstream timeouts (AbortController) + classified upstream errors, and request idempotency (0071 `claim_ai_idempotency`, payload HASH only) so a retry never double-pays. enrich-merchant merchant-name leak removed; bank-discovery logs via `safeLog`. Migration 0071 (consent cols + revoked_at + idempotency ledger + locked-down RPCs) + `set-device-consent` write path. Client sends device_secret + stable request_id + schema_version and pushes consent (iOS syncNativeState); degrades to local parse on failure. `b6c990f8`/`9bf26554`/`2aa29d60`/`3316c154`/`8dd5f1b1` (P5-B3). deno 67/0/2-ignored; migration lint PASS. **[B6-closure]** `process-ios-sms` (the legacy iOS path that predated the boundary) brought onto it: AI now gated by the SERVER-owned `ai_consent_granted` (fail-closed; `allowAi` compat-only, never overrides OFF; revoked blocks AI); body via `readBoundedJsonBody` (16KB, ignores Content-Length, UTF-8-byte-aware) + SMS/sender/schema-version limits; gate ordering (body→schema→auth→ownership→consent→quota→idempotency) before any Gemini call; metadata-only logs. `readBoundedJsonBody` deno tests + static ordering + credential-gated real-backend gates. External: live migration apply + RPC concurrency + Android consent-push + live process-ios-sms consent under 0071 |
| MALI-061n | Med | C | P5 | Code complete · Locally verified | notification identity now derives from a stable business key (`notificationEventId`/`achievementNotificationId`), not mutable display text/hashCode (achievement + review ids fixed); gamification/capture already route through `_show` (the local policy gate: per-type enabled + quiet hours). Budget dual-authority coordinated: local app is primary; evaluate-budgets advances the notified watermark but pushes only as a fallback when no device is recently active (`anyDeviceRecentlyActive`). Phase-3 gamification authority preserved; 0070 engagement authority stays dormant. `1e217ce3`/`5b2c771b` (P5-B4). [B4-closure] Closure: explicit `CaptureNotificationAuthority.shouldShowLocalReview` (payload-id identity; APNs-sent suppresses local; lost APNs response never suppresses both; replay/owner-invalid blocked) wired into the drain + 5 behavioral tests (`c3ffc673`). **[B6-closure]** authority matrix completed: goals + achievements now local-primary/server-fallback (server pushes only via `anyDeviceRecentlyActive`); streak + bill server cron push RETIRED (scheduled-local is the sole authority — `anyDeviceRecentlyActive` can't coordinate a scheduled notification); captureLight id now from a generated-before-notify stable key (txn id or immutable content fingerprint) via `notificationEventId`; budget `showBudgetAlert` `notifId` now REQUIRED (text-hash fallback removed); `_safeId` orphan removed. No type is "may duplicate". 6 stable-id tests + coordinated-fallback contracts. Live two-path device delivery + two-device fallback timing external |
| MALI-062n | Med | C | P4 | **Closed · locally verified** | Saturday-week fixed (B1); the three divergent weekly/budget-period resolvers unified into one canonical resolver + Saturday-anchored history (B3); the per-period history transaction LIST nets to its total (B4). Week definitions, budget periods, and history list-vs-total parity all verified. Device UI spot-check external |
| MALI-063n | Med | C | P4 | Code complete · Locally verified | PDF donut center/slices/appendix scoped to the primary currency (per-currency `categoryBreakdown`), never a cross-currency sum; exponent formatter (0/2/3); dormant 0030 RPCs + Supabase-summary flags retired (no switch to re-enable pre-canonical totals); `989f6614`/`174ed4c3` (Batch 4). Live PDF render spot-check external |
| MALI-064n | Med | C | P4 | Code complete · Locally verified | one attribution contract — `bill_payments` authoritative, a linked payment counts once (double-count gone), fuzzy match demoted to a non-authoritative link suggestion; one canonical `monthlyEquivalent`/`annualEquivalent`/`subscriptionMonthlyTotal` unifying the three divergent formulas; `d5d1605b` (Batch 4). Device UI spot-check external |
| MALI-065n | Med | C | P5 | Code complete · Locally verified (device-external) | one `ManagedExportStore` for every export temp file (report PDF / CSV / full-data package): opaque, data-free on-disk names; iOS `NSFileProtectionComplete` + backup-exclusion via a new `mali/export_protection` channel (Android no-op — FBE + `allowBackup=false`); delete on success/cancel/failure (idempotent + retry); startup delete-all + resume bounded-lease sweep (corrupt-metadata / orphan-sidecar tolerant); NO clipboard fallback for full ledger/package (dead `data_export.dart` removed); 9 behavioral filesystem tests + iOS simulator build. `2d1072f6` (P5-B2). Device file-protection/backup-exclusion attributes external |
| MALI-066n | Med | C | P7 | Not started | unexecuted-gate cluster |
| MALI-067n | Med | T | P7 | Not started | source-text tests, no-close, warning suppression |
| MALI-068n | Med | C | P5 | Code complete · Locally verified (device external) | native-storage portion done (P5-B1): Android durable-queue writes synchronous (`commit()`, enqueue/ack durable before return) `5c88417c`; iOS aux notification-route/log queues now under the shared `withQueueLock` cross-process lock `30b4f3fc`. Batch-4 native tail (P5-B4 `8337202e`): SMS receiver stamps the SMS's native `timestampMillis` (not receiver-run time), Item carries authoritative `receivedAtEpochMs`, corruption clear now `commit()`; Dart `resolveCapturedReceivedAt` prefers epoch, ISO string legacy-only, unknown→null (never `now`); exact-alarm permissions removed (reminders use inexact). Static-reviewed + Dart/manifest-contract tests. EXTERNAL: Android compile, receiver process-death replay, alarm delivery, on-device timestampMillis + reboot | [B4-closure] Closure: silent-`now` gap FIXED — `CapturedMessage.receivedAt` nullable, drain no longer stamps `now`; behavioral tests (real Drift occurredAt: SMS-date authority, real receivedAt used, null→documented fallback) + file-backed native-queue LEASE test (peek≠ack, failed-handle-retries-after-restart, crash-after-commit idempotent) (`d72e5785`). Ack-failure idempotent-replay already in capture_sync_service_test |
| MALI-069n | Med | C | P6 | Not started | conn leak + second-instance busy_timeout |
| MALI-070n | Low | C | P2 | Code complete · Locally verified | pending-actions file purged on destructive paths; `374560ff`. Announcement-dismissal residue = minor, remains backlog |
| MALI-071n | Low | C | P5 | Code complete · Locally verified | merchant logos gated on cloud-processing consent (fail-closed while loading/errored/unset) — OFF/revoked = ZERO outbound requests (bundled SVG or letter placeholder only); data-minimization ladder made explicit: bundled SVG → (consented) catalog `logoUrl` → logo.dev by verified PUBLIC DOMAIN (never raw merchant text) → placeholder; no prefetch path (`registerBrandLogos` is asset-only); `BrandMark`→`ConsumerWidget`; 4 widget tests assert no `Image` widget with consent OFF even given a `logoUrl`. `08e7ca0d` (P5-B2) |
| MALI-072n | Low | C | P3 | Code complete · Locally verified | durable sender-mapping sync: keyset pagination + server-authoritative updated_at + durable cursor + tombstone deletion propagation + LWW (pending-safe) + typed error classification (no string-match); soft-delete replaces hard delete; `96993c5e` (batch 5). Live two-device = external |
| MALI-073n | Low | C | P6 | Not started | missing account_id/category_id indexes |
| MALI-074n | Low | C | P4 | Code complete · Locally verified | report decimals (B4); exact account ownership (no null-account-by-currency), per-currency net-spend card summaries (refund-netted, income-only, exponent formatter), authoritative installment paid-count from the ledger (B5 `a25a75c7`/`0f86fb7c`/`1fc89450`). Device UI spot-check external |
| MALI-075n | Low | C | P5 | Code complete · Locally verified (live-backend external) | logging/privacy portion (P5-B2 `0010b037`) + backend lows (P5-B5, migration 0072, undeployed): (a) SD search_path — the only two functions lacking a fixed path fixed (dead `handle_new_user` dropped; `prune_processed_captures` recreated with search_path + re-locked); a precise per-function audit confirms all others already had one. (b) Metrics ingestion — `with check (true)` free-for-all authenticated insert removed + INSERT revoked; owner-bound (auth.uid()) `record_metric` RPC with event allowlist, length bounds, atomic per-user daily quota (deny-all `metrics_rate_limits`), no PII stored; client routes through the RPC. (c) Purge coverage — `purge_user_data` extended to AI idempotency (owner_key), engagement, and metrics-quota rows in FK-safe order. `4e927db5`/`975af849` (P5-B5). Live RLS/RPC/purge under real Postgres external |
| MALI-076n | Low | C | P6 | Not started | backup lows (trim, blob version, hasRemoteBackup, dead export) |
| MALI-077n | Low | C+P | P7 | Not started | ops lows (keystore name, email, dead API, package path) |

## Phase roll-up

| Phase | Findings | Status |
|---|---|---|
| P1 migrations/restore | MALI-046n/027, MALI-045n/014 | **Code complete · Locally verified** (full suite 1003; awaiting approval) |
| P2 lifecycle/consent | 053n,054n,070n,011,017,001,059n | **Code complete · Locally verified** (full suite 1015; commits 374560ff + 89db9f09; awaiting approval) |
| P3 sync | 051n,052n,055n,056n,057n,008,009,010,022,023,024,072n | **LOCALLY COMPLETE** (live/2-device pending) — all 6 batches committed: B1 051n (acf9ca99), B2 052n/023 (d6820285), B3 022/057n/052n revision-CAS+resolver (4a2da692/de672bc0/0e52da68, **live CAS external-pending**), B4 055n/056n/009/010 (58614ad4/124fd83b), B5 072n/008 + 024 (96993c5e/74a77398), B6 closure docs. MALI-023 Closed-LV; all others CC-LV (external tail). Gamification single-authority overlap proof: no overlap (Edge active, RPC dormant) — see `PHASE_3_SYNC_CLOSURE.md` §2. |
| P4 financial | 047n,048n,049n,050n,062n,063n,064n,074n,018,028 | **CLOSED · locally verified** — B1–B6 complete. 018/028/062n Closed · LV; 047n/048n/049n/050n/063n/064n/074n Code complete · LV (documented device spot-checks remain). Spec `PHASE_4_FINANCIAL_SEMANTICS.md`. Full suite 1179; analyze 0. Verdict: code+automated closed locally, device/PDF/UI external-pending |
| P5 security/notif/native | 031,032,033,060n,061n,065n,068n,071n,075n,019,025,044,039 | **Phase 5 code complete — locally verified; external verification pending.** All 6 batches committed: B1 native storage (031/033/068n `5c88417c`/`30b4f3fc`), B2 telemetry/logging/exports/logos (032/065n/071n/039/075n-logging `bff0f1d8`/`2d1072f6`/`08e7ca0d`/`0010b037`), B3 AI endpoint auth (060n `b6c990f8`+), B4 notification authority (061n/019/025/068n-tail `1e217ce3`/`224394fd`/`9128589e`/`8337202e` + closure `f7cbe727`/`c3ffc673`/`d72e5785`), B5 backend/RLS/metrics/purge/gamification (075n/044/024 `4e927db5`/`6ddd5aaa`/`975af849` + closures `9fdd30e7`/`c4f2aea0`/`ae1f967b`), B6 closure docs. MALI-071n Closed·LV; all others Code complete·LV (external tail). Authoritative spec: `PHASE_5_SECURITY_PRIVACY_NOTIFICATIONS.md`. Migrations 0068–0074 undeployed; `kServerRevisionCas=false`; 0070 authority inactive. External: signed-device, Android, APNs, store-policy, live-Postgres |
| P6 backup/DB/reliability | 058n,069n,073n,076n | Not started |
| P7 CI/test/arch/docs | 066n,067n,029,030,034,035,037,038,040,041,042,043,077n,036-limits,021-deadfile | Not started |
| P8 MALI-026 | 026 | Not started (blocked on P1) |
| P9 external validation | 12 gates (002,003,004,005,006,012,013,017,019,020,022,036) | Not started |

Decision-required (await explicit product approval): **MALI-059n** (consent default),
**MALI-043** (canonical brand name). These are surfaced, never silently decided.

## Batch 4 delivered contracts (MALI-055n / 056n / 009 / 010)

### Account default-command contract (MALI-055n)
- Changing the default is ONE dedicated command — `account_default_command`
  (outbox entity type), payload `{target_local_id, operation_id}`, NO account
  field payload — resolved on push to the atomic `set_default_account` RPC
  (demote old + promote new in one server transaction).
- A default switch queues **zero** account field rows, so a stale device can
  never roll back an unrelated remote rename/type/currency edit.
- Successive switches coalesce to one command (singleton key `__current__`);
  latest target wins. Create-as-default and delete-successor route through the
  same command. Create/update no longer apply the default via `is_default`.
- Delete additionally queues a **guarded** update of the successor only (so it
  exists server-side for the command to resolve); guarded (Batch 3C) → conflicts
  instead of clobbering.
- Push order: field syncs before commands (target established first); an unsynced
  target defers (`missingDependency`). RPC is idempotent → replay/crash-after-
  acceptance safe; concurrent switches = deterministic last-RPC-wins; exactly one
  active default after every path; capability OFF and ON both resolve via the RPC.

### Versioned canonical ledger payload (MALI-056n / 009 / 010)
- `payload_version = 2` (`lib/features/capture/services/ledger_payload.dart`).
- Outbox payload carries `payload_version` + `canonical_type/source/direction`
  (legacy `type` retained for downgrade safety).
- Push writes the coarse server columns AND round-trips the exact client
  type/source/direction through the server `metadata` JSONB.
- Pull recovers the exact meaning from canonical metadata (authoritative);
  older rows use the documented compatibility rule below.

**Enum mapping table**

| client type | server transaction_type | server direction (derived) | pull recovery (v2 canonical / v1 coarse) |
|---|---|---|---|
| payment    | expense  | debit   | canonical→payment / expense→payment |
| withdrawal | expense  | debit   | canonical→withdrawal / (v1 indistinguishable → payment) |
| income     | income   | credit  | income→income |
| refund     | refund   | credit  | refund→refund |
| transfer   | transfer | unknown | transfer→transfer |
| unknown    | unknown  | unknown | canonical→unknown / adjustment·unknown·future→unknown (**never payment**) |

- **Historical compatibility:** a payload with no `payload_version` is treated as
  v1 and pushes via the legacy `type` mapping. A pulled server row without
  canonical metadata uses the coarse rule above — legacy `expense`→payment, and
  any unmapped/future category → `unknown`, never silently payment/expense.
- **Future safety:** a payload written by a newer app (`payload_version` beyond
  this build) dead-letters as `unsupportedSchema` (re-armable after upgrade); an
  unrecognised canonical enum NAME falls back to the coarse column, never trusted
  verbatim.

### Local verification (Batch 4)
`flutter analyze` clean; new tests: account_default_command_test (10),
ledger_payload_test (21), ledger_roundtrip_test (18). Full suite green (see
Batch-4 report). No schema/backend change in Batch 4; capability `kServerRevisionCas`
stays **false**.

## Batch 5 delivered contracts (MALI-072n / 008 / 024)

### Sender-mapping sync contract (MALI-072n / 008)
- **Pagination:** stable keyset by `(updated_at, id)` with a durable cursor
  advanced atomically per page; `updated_at` is server-authoritative (0069
  trigger) so it is monotonic across devices and the keyset never skips a row.
- **Tombstones:** `deleted_at` (local + server, migration 0069) propagates
  deletions both ways; a hard delete is replaced by a soft-delete; re-suggesting
  a sender un-tombstones it (explicit recreate).
- **Conflict policy:** server-authoritative-timestamp LWW that never overwrites a
  locally pending change (it is pushed and wins) and never applies an older
  remote snapshot.
- **Typed errors:** `classifyOutboxError` replaces string-matching. A natural-key
  duplicate is resolved by the upsert; any error reaching the handler (unrelated
  unique-constraint, validation, auth, server, unsupported schema, network) marks
  the item failed for bounded retry and never falsely resolves it.

### Gamification single-authority contract (MALI-024)
- **Server authority:** migration 0070 adds `user_engagement_events`
  (owner-bound idempotency: `UNIQUE(user_id, event_id)` + partial unique
  `(user_id, business_key)`) and the locked-down `record_engagement_event` RPC
  (SECURITY DEFINER, fixed search_path, revoked from PUBLIC / granted
  authenticated, `user_id` from `auth.uid()`). The server validates the event
  type + version and decides the award; the client cannot submit an XP total.
- **Idempotency:** duplicate `event_id`/`business_key` awards nothing; the
  aggregate UPSERT is row-locked so concurrent events cannot lose an increment.
- **Client:** durable `engagement_events` outbox (event_id idempotency, bounded
  retry/dead-letter, business-key dedup); exactly-once submit; the client
  aggregate-total upload is REMOVED (tamper vector gone) — `GamificationSyncService`
  is pull-only. Displayed state = acknowledged server aggregate + projection of
  pending events (unknown types project 0 — no invented award).
- **Event schema:** `{event_id, event_type, occurred_at, business_key?,
  event_version}`; supported types → award: transaction_confirmed 10,
  goal_contribution 15, budget_action 5, bill_payment 5, streak_activity 2;
  unknown/future type or version → rejected (dead-letter), never awarded.
- **Compatibility:** additive migration; transaction-driven awards continue via
  the existing evaluate-gamification Edge Function; per-domain-action event
  enqueue is added as each action migrates off that path (avoids double-award).

### Batch 5 local verification
`flutter analyze` clean; new tests: sender_bank_mapping_sync_service (11),
engagement_event_service (12), gamification_sync_service (rewritten, pull-only);
migration lint PASS (70 files, 14 SECURITY DEFINER); node contract 5 pass / 13
skip / 0 fail. Full suite green.

### Batch 5 external / two-device acceptance (still pending)
- Live two-device sender-mapping keyset/tombstone round-trip on a real backend.
- Live `record_engagement_event` RPC verification: idempotency, ownership
  (`auth.uid()`), atomic concurrent increments, unknown-type/version rejection,
  unauthenticated rejection (credential-gated node contract test).

## Batch 4 external / two-device acceptance criteria (still pending)
- Live `set_default_account` RPC round-trip on a real backend; two-device
  concurrent default switch converges to one default with no field rollback.
- Two-device ledger round-trip on a real backend confirming withdrawal/refund/
  unknown/source/status survive without conversion.
- Live revision-CAS activation (MALI-022) remains blocked on migration 0068
  staging apply + real Postgres concurrency tests before `kServerRevisionCas` may
  be flipped.

## Phase 4 Batch 2 delivered contracts (MALI-047n / 050n / 018-provider / 028-boundary)

### Canonical aggregate APIs
- No new repository methods or signatures. The two surfaces route through the
  existing canonical aggregates (`expenseTotalBetween`, `incomeTotalBetween`,
  `categoryBreakdown`, `currencyTotalsBetween`) — production UI always reads the
  Drift-routed repository.
- **Date boundary (MALI-028):** all seven canonical aggregate methods now use
  half-open `[from, to)` (`occurred_at >= from AND occurred_at < to`) instead of
  inclusive `BETWEEN`, applied once in the shared aggregate SQL. The boundary
  instant belongs to the next window, never both. Boundary-safe for every
  existing caller (dashboard/reports/budgets pass an inclusive last-instant `to`
  — `now`, `end − 1ms/1s/1μs` — where no real row sits, so no live number
  changes); the fix only bites for callers passing a clean period boundary. The
  dormant Supabase summary tier keeps inclusive `BETWEEN` (flag-off, tracked
  under MALI-063n) and is out of Batch-2 scope.
- **Currency scope:** expressed through account scope (each account carries one
  currency). The all-accounts case uses per-currency `currencyTotalsBetween` and
  is never a cross-currency sum.

### Transactions-header metric contract (MALI-047n)
- `transactionsPeriodTotalProvider` → canonical **net expense**
  (payment + withdrawal − refund), **confirmed-only**, over the COMPLETE dataset
  for the visible **period × active-account** scope. Pagination-independent
  (set-based Drift, not a page fold). Transfer/unknown excluded; refund never
  counted as income; excluded-account policy applies only in the all-accounts
  case. Single-currency (the active account fixes the currency); no active
  account → base currency's own total via per-currency grouping. Free-text
  search and the list kind/category filters do **not** change it — the header
  claims the *period* expense, not the filtered subset. The amount is labelled
  with the scope's own currency.
- Not covered by this contract (unchanged, visible-list affordances, documented):
  `pendingCount` and `transactionsCount` reflect the loaded/visible list, and the
  confirm-all action operates on that list.

### Home-category metric contract (MALI-050n)
- `monthlyExpenseGroupsProvider` group totals come from canonical
  `categoryBreakdown` over the half-open current month — same refund netting,
  status contract, excluded-account policy and account/currency scope as the
  budget chip beside them (which reuses the same canonical budget math), so a
  category amount and its adjacent budget metric cannot disagree for the same
  scope. Uncategorized rows are not shown as a group (consistent with the
  Reports category ranking, which uses the same aggregate). `MonthlyCategoryGroup`
  drops the unused per-group transactions list and carries the canonical `count`.
- **UI-wiring status:** the provider is not currently rendered by any screen
  (the Calm-Capital redesign, `88475da8`, dropped its consumer). It is closed at
  the provider tier to hold the cross-surface invariant; re-wiring it to a Home
  section is a UI decision outside Batch-2 scope.

### Currency behaviour
- Grouped by currency (via account scope or `currencyTotalsBetween`); a single
  currency label is never attached to a multi-currency sum. No exchange-rate
  conversion in this batch. Batch-1 `formatMoneyAmount` remains available for
  exponent-correct display (the two headers still use `Formatters.amount`; the
  scope currency is single so this is presentation-consistent).

### Local verification (Batch 2)
- `flutter analyze` clean (0 issues); full Flutter suite **1131** (baseline 1121
  + 10 new). New tests: `financial_aggregate_boundary_test` (3 — half-open at
  exact from/before-to/exactly-to, category half-open, currency isolation);
  `financial_cross_surface_invariant_test` (7 — one-fixture agreement across
  repo/header/breakdown/Home/budget; excluded account; multi-currency isolation;
  501-row completeness; type matrix; empty; alias→stable key). Existing
  `home_sections_providers_test`/`financial_totals_invariant_test`/
  `exclude_from_totals_test`/`repository_test` remain green.
- No schema, migration, backend, or capability change; `kServerRevisionCas`
  stays **false**; migrations 0068–0070 remain undeployed.

### Batch 2 external / device acceptance (still pending)
- On-device spot-check that the Transactions header and (once/if re-wired) the
  Home category groups render the canonical values with the scope currency.

## Phase 4 Batch 3 delivered contracts (MALI-048n / 049n / 018-provider / 028-062n budget-period)

### Plan scope model (MALI-048n)
- Two explicit modes (`lib/domain/finance/plan_scope.dart`, `PlanScopeMode`):
  **allExpenses** (no account/card selected) and **selected** (one or more
  accounts/cards). All-expenses is the DOCUMENTED plan-form contract shown to
  the user ("if you don't choose an account or card, the plan counts all
  expenses in the period"), named in one place instead of scattered `isEmpty`
  checks — not an accidental empty-means-all.
- **Empty vs all-expenses:** the current data model has NO separate stored
  "unconfigured/zero" state; an empty selection has always meant all-expenses.
  This meaning is preserved exactly — no user data is reinterpreted. A distinct
  unconfigured state (empty → zero + configuration prompt) would change every
  existing empty-scope plan and requires an additive `scope_mode` column + UI;
  it is surfaced as a **deferred product decision**, not invented.
- **Membership: UNION.** A transaction counts if it matches the plan's window +
  currency + status + net-expense type AND (its account ∈ selected accounts OR
  its card ∈ selected cards OR it is manually linked). The same membership backs
  `spentForPlan` and `transactionsForPlan`, so the displayed list nets to the
  displayed total. Applies to plan progress, the plan transaction list, and any
  future notification.
- **Plan currency policy:** every candidate row (including manually-linked ones)
  must match the plan's currency — a SAR plan never sums an EGP/USD/KWD amount;
  no exchange-rate conversion. A blank currency is an invalid configuration and
  **fails closed to zero** consumption / an empty list.
- **Semantics:** net expense (payment + withdrawal − refund) via the shared
  `FinancialSql` signed sum (no raw `SUM(amount)`), confirmed-only, genuine
  half-open `[startDate, endExclusive)` window where `endExclusive` is the start
  of the day after the plan's last day (derived from the legacy `23:59:59`
  endDate with no epsilon), and the excluded-from-totals account policy for the
  all-expenses scope (an explicitly-selected account overrides it).

### Budget period + scope contract (MALI-049n / 028 / 062n)
- **One resolver:** `resolveBudgetPeriod(budget, now)` (`budget_period.dart`)
  returns a genuine half-open `[from, to)` window via `FinancialPeriod` —
  Saturday-anchored week, calendar month/year, NO epsilon end. Used by the
  dashboard ring, budget detail (`budgetsViewProvider`), the reports/alerts
  use-case (`BudgetProgressUseCase`), and the Saturday-anchored budgets-screen
  history. The yearly `−1ms` and the three previously-divergent weekly
  definitions are gone.
- **One consumption:** `budgetSpent(repo, budget, period, {fallbackAccountId})`
  — all-expenses budgets net across categories, category budgets scope to their
  category, both through the canonical aggregate (refund netting, confirmed-only,
  excluded-account policy). A budget with its own account stays account-scoped; a
  global budget falls back to the surface's active account, so the dashboard ring
  and budget detail agree for the same scope.
- **No filter leakage:** the dashboard transaction filter no longer feeds any
  budget-consumption query. A monthly budget stays monthly under a "last 90 days"
  filter; the ring equals budget detail equals the repository aggregate.
- **Boundary rule:** all new/changed budget/plan callers pass a genuine
  `toExclusive` boundary; no `end − 1ms/1μs`, `23:59:59`, or inclusive last
  instant is introduced or relied upon. The dormant Supabase summary batch-fetch
  path (flag-off) is left untouched (MALI-063n).

### Local verification (Batch 3)
- `flutter analyze` clean (0 issues); full Flutter suite **1150** (baseline 1131
  + 19 new). New tests: `plan_spending_canonical_test` (11), 
  `budget_consumption_canonical_test` (7 — resolver genuine half-open incl. leap
  day; budget detail == canonical repo and filter-invariant; excluded account);
  `financial_cross_surface_invariant_test` extended (+1 — repo == header ==
  budget detail == plan progress on one all-expenses month fixture, all 400 after
  a refund). Existing plan/budget/report/alert tests remain green.
- No schema, migration, backend, or capability change; `kServerRevisionCas`
  stays **false**; migrations 0068–0070 remain undeployed.

### Batch 3 external / product tail (still pending)
- On-device spot-check of plan progress and dashboard rings.
- **Product decision — RESOLVED 2026-08-04 (Batch 5):** empty plan scope stays
  `allExpenses`; no `unconfigured` state / `scope_mode` column / UI is added.
  Recorded under Approved product decisions above.
- Budget-history per-period transaction LIST vs net-total refund reconciliation
  (MALI-062n tail — delivered in Batch 4) and bill/subscription/PDF surfaces
  (Batch 4).

## Phase 4 Batch 4 delivered contracts (MALI-063n / 064n / 062n-tail / 074n-report / 018 / 028 + legacy retirement)

### Report currency + interval policy (MALI-063n / 074n / 028)
- The PDF report picks a **primary currency**; every currency-scoped figure — the
  donut center, slices, slice-percentage denominator, summary tiles, cash-flow,
  comparison — uses only that currency's own data. `categoryBreakdown` gained an
  optional `currency` scope; the snapshot carries `categoryBreakdownByCurrency`
  (one query per currency present), and the composer feeds the donut the primary
  currency's breakdown + `currencyTotals[primary].expense`. A single currency
  label is **never** attached to a cross-currency sum; no FX conversion.
- The appendix applies the excluded-from-totals account policy in the combined
  view, so appendix rows net to the displayed per-currency totals.
- Intervals are genuine half-open `[fromInclusive, toExclusive)`; a transaction
  at `toExclusive` is in neither totals nor appendix, one before it is in both.
  The reports-screen + dashboard previous-period bounds are genuine exclusive
  (no `−1s`/`+1µs` epsilon).
- Report money uses the Batch-1 `currencyDecimalDigits` (0/2/3 fraction digits).

### Bill-payment attribution contract (MALI-064n)
- `bill_payments` is the authoritative settled-payment ledger: **one real
  payment counts exactly once**, no matter how many representations exist
  (transaction, relation row, manual amount). `billPaidTotal` = Σ recorded
  payments + the legacy-manual residual (`max(0, manual − recorded)`). Fuzzy
  merchant-name matched transactions are **never** summed authoritatively — they
  are shown only as "suggested to link"; `linkedTransactionIds` keeps an
  already-linked transaction out of that list. The bill-details `totalPaid`
  double-count (fuzzy transactions + recorded payments) is gone.
- Refunds: reconciled by removing/reducing the corresponding `bill_payments`
  row (the ledger is authoritative); a fuzzy refund transaction is not
  auto-netted (documented).

### Subscription monthly-metric definitions (MALI-064n)
- **`monthlyEquivalent(bill)`** = the projected MONTHLY recurring obligation,
  frequency-normalized; **`annualEquivalent(bill)`** = monthlyEquivalent × 12
  exactly (weekly ×52, monthly ×12, yearly ×1, custom ×365/days). One
  normalization ended the three divergent "monthly total" formulas
  (frequency-normalized-30-day vs raw un-normalized sum) and the two annual
  conventions. **`subscriptionMonthlyTotal`** = Σ monthlyEquivalent over ACTIVE
  subscriptions, single-currency (paused/cancelled/installment excluded). The
  transactions screen and subscriptions screen now agree on this metric. The
  dashboard's auto-detected "recurring candidates" total is a **different**
  metric (heuristic detection, not saved subscriptions) and is left as-is.

### Budget-history list vs total (MALI-062n tail)
- The per-period budget transaction list mirrors the canonical consumption
  exactly (confirmed-only, net-expense types with refunds INCLUDED, half-open,
  account/category scope, excluded-account policy for global budgets), so its
  signed sum equals the net total shown beside it; refund rows are visible.

### Legacy aggregation retirement (Outcome B)
- The two hardcoded-false summary flags, the `supabaseFinancialSummaryService`
  provider, and every `useSupabaseSummary` branch (dashboard, reports,
  budget-progress) were removed — all financial surfaces compute from the
  canonical Drift aggregates; no switch remains to re-enable the pre-canonical
  0030 tier. `SupabaseFinancialSummaryService` + `SupabaseTransactionRepository`
  aggregates are documented RETIRED/DORMANT (the latter kept live only for
  `repairLocalCache()` + credential-gated contract tests). Migration 0030 is
  marked HISTORICAL (not deleted — deployed); its flag stays OFF.

### Local verification (Batch 4)
- `flutter analyze` clean; full Flutter suite (see report) with new tests:
  `budget_history_reconciliation_test` (2), `report_multicurrency_test` (3),
  `bill_metrics_test` (7), cross-surface invariant extended (+1: report snapshot/composer
  tie-in on the shared fixture). No schema/migration/backend change beyond the 0030
  historical comment; `kServerRevisionCas` stays **false**; migrations 0068–0070
  undeployed.

### Batch 4 external / device acceptance (still pending)
- Live PDF render spot-check of a multi-currency report (donut labelled per
  currency; 0/2/3-decimal). On-device bill-details paid total + subscription
  monthly metric. No live-backend dependency (the retired path is gone).

## Phase 4 Batch 5 delivered contracts (MALI-074n / 018-provider / 028-list)

### NULL-account attribution contract (MALI-074n)
- A specific account's scope is EXACT ownership (`account_id = ?`). An
  unassigned (`account_id IS NULL`) transaction belongs to no account and is
  never attributed to one because its currency matches — it appears only in the
  all-accounts scope (`accountId == null`). Fixed at the source (`_accountClause`
  → every Drift aggregate) plus the transactions list scoping and the report
  "largest transactions" builder. Assigning an orphan to an account (incl. the
  dashboard's one-time currency reconciliation) moves it exactly once; it then
  appears there because it is assigned, not by a read-time currency match. Both
  lists and totals share the exact-ownership rule so they cannot disagree.

### Account-detail contract (MALI-018)
- Account detail reads the same canonical account-scoped aggregates as the
  dashboard/transactions/reports (exact ownership, confirmed-only, refund-netted,
  excluded-account policy affects only combined totals, half-open, full-dataset
  set-based, exponent formatter). No separate account-detail fold exists.

### Card financial-metric contract (MALI-074n)
- Per (last4, currency): `totalOut` = **net spend** (payment + withdrawal −
  refund), `totalIn` = **income only** (a refund is netted into spend, never
  ordinary income), confirmed-only, transfers excluded, set-based
  (pagination-independent). `CardSummary`/`CardAccountBreakdownRow` carry
  `currency`; the grouper keys by (last4, currency) so two currencies on one card
  never merge. The card UI shows the summary's own currency with the exponent
  formatter (0/2/3 digits). Card net-spend equals the account's net expense for
  the same scope (cross-surface invariant).

### Installment paid-count contract (MALI-074n)
- The authoritative paid count is the number of DISTINCT settled installments in
  the `bill_payments` ledger for the bill's own currency
  (`COUNT(DISTINCT installment_index)` for indexed rows + one per null-indexed
  row, non-deleted, capped at totalInstallments), recomputed after every settle
  and delete — never `MAX(installment_index)` and never a monotonic counter.
  Duplicate-index rows collapse to one; deleted / foreign-currency payments never
  count; paying installment 5 alone = 1; out-of-order is safe; a payment linked
  to a transaction is one ledger row = one count.

### Remaining-fold disposition (MALI-018)
- Removed: dead `BillsView.totalDue` (raw cross-frequency/currency fold, no
  consumer). Made half-open: transactions list + dashboard recent-list date
  filters. Left as intentionally-different metrics with distinct labels: the
  dashboard "قيد المراجعة" gross pending sum (pending-review affordance), the
  dashboard auto-detected recurring-candidates total (heuristic, not saved
  subscriptions), the subscriptions "إجمالي مديونية الأقساط" remaining-debt
  projection (built on the corrected paid-count). No mixed-currency raw sum, no
  page-dependent total, and no direction-inferred expense remains on a
  user-facing Phase-4 financial total.

### Approved plan-scope decision (recorded)
- Empty plan scope permanently means `allExpenses`; no `unconfigured` state /
  `scope_mode` column / UI (Approved product decisions, above).

### Local verification (Batch 5)
- `flutter analyze` clean; full Flutter suite **1179** (B4 1163 + 16 new). New
  tests: `null_account_attribution_test` (4), `card_summary_canonical_test` (4),
  `installment_paid_count_test` (7), cross-surface invariant +1 (card tie-in);
  `repository_test` updated to the exact-ownership contract; card constructors
  carry currency. No schema/migration/backend change; `kServerRevisionCas`
  stays **false**; migrations 0068–0070 undeployed.

### Batch 5 external / device acceptance (still pending)
- On-device spot-check of account detail (unassigned rows only under
  all-accounts), card in/out/net per currency, and installment "X of N".

## Phase 4 closure reconciliation (Batch 6)

Canonical spec: `PHASE_4_FINANCIAL_SEMANTICS.md`. Phase-4 commits (17):
`71dc2534` `c4b6df97` `2052687d` `161f669f` `4fa413a9` `4dc0d190` `76423f1b`
`b702669c` `989f6614` `d5d1605b` `174ed4c3` `9e819ee0` `d2b911da` `a25a75c7`
`0f86fb7c` `1fc89450` `acb079a3` (+ this Batch-6 closure commit).

Per-finding reconciliation (defect → root cause → remediation → commits → tests →
status). "External" = a device/PDF/UI spot-check with no automated proxy; never
marked done without captured evidence.

- **MALI-047n — Code complete · Locally verified.** Defect: Transactions header
  folded loaded pages (counted pending, refund-as-income, page-dependent). Root
  cause: a second Dart aggregation tier. Remediation: `transactionsPeriodTotalProvider`
  → canonical `expenseTotalBetween`, confirmed-only, refund-netted, single-currency,
  pagination-independent. Commits `2052687d`. Tests: cross-surface invariant (501-row,
  types, statuses, boundaries). External: header render spot-check.
- **MALI-048n — Code complete · Locally verified.** Defect: plan `SUM(amount)` with
  no refund/currency/half-open. Remediation: canonical membership (half-open window,
  plan currency isolation incl. linked rows, net-expense signed sum, UNION account/card,
  fail-closed currency, list==total). Commit `4fa413a9`. Tests: `plan_spending_canonical_test`
  (11). External: plan progress spot-check. Empty scope = `allExpenses` (approved).
- **MALI-049n — Code complete · Locally verified.** Defect: dashboard ring used the
  screen filter as the budget window; ring ≠ detail. Remediation: `resolveBudgetPeriod`
  + `budgetSpent` shared by ring/detail/reports/alerts; genuine Saturday-week half-open.
  Commit `4dc0d190`. Tests: `budget_consumption_canonical_test` (filter-invariant),
  cross-surface. External: ring render spot-check.
- **MALI-050n — Code complete · Locally verified.** Defect: Home category fold, no
  refund netting, disagreed with the budget chip. Remediation: `categoryBreakdown`
  (canonical). Commit `2052687d`. Tests: cross-surface (Home==breakdown==budget).
  Provider not UI-wired (Calm-Capital redesign) — closed at the provider tier.
  External: n/a until re-wired.
- **MALI-062n — Closed · locally verified.** Defect: three weekly definitions; history
  list ≠ total. Remediation: Saturday-week (`71dc2534`); one resolver + Saturday history
  (`4dc0d190`); history list nets to total (`b702669c`). Tests: `budget_history_reconciliation_test`,
  `budget_consumption_canonical_test`.
- **MALI-063n — Code complete · Locally verified.** Defect: PDF donut cross-currency sum;
  dormant 0030 tier. Remediation: per-currency `categoryBreakdown` + primary-currency
  donut/slices/appendix; exponent formatter; retired the 0030/Supabase-summary switches.
  Commits `989f6614`/`174ed4c3`. Tests: `report_multicurrency_test`. External: on-device
  PDF render.
- **MALI-064n — Code complete · Locally verified.** Defect: bill paid double-count
  (fuzzy + recorded + manual); three monthly formulas. Remediation: `bill_payments`
  authoritative `billPaidTotal` (fuzzy = suggestion); one `monthlyEquivalent`/`annualEquivalent`/
  `subscriptionMonthlyTotal`. Commit `d5d1605b`. Tests: `bill_metrics_test`. External:
  bill-details + subscription metric spot-check.
- **MALI-074n — Code complete · Locally verified.** Defect: card gross/refund-as-income,
  cross-currency card sums, null-account-by-currency, `MAX(installment_index)`. Remediation:
  exact account ownership; per-currency net card summaries; ledger-based distinct
  installment count; report decimals. Commits `989f6614`/`a25a75c7`/`0f86fb7c`. Tests:
  `null_account_attribution_test`, `card_summary_canonical_test`, `installment_paid_count_test`.
  External: card/account/installment device spot-check.
- **MALI-018 — Closed · locally verified.** Defect: a second Dart aggregation tier
  contradicted the canonical repo predicate on multiple surfaces. Remediation: every
  provider/report/bill/card/account tier routed through the canonical aggregate/helper;
  dormant Supabase tier retired; locked by the cross-surface invariant suite (B2–B5).
- **MALI-028 — Closed · locally verified.** Defect: inclusive `BETWEEN` / epsilon ends.
  Remediation: half-open `[from, to)` for every Phase-4 interval; boundary rule enforced.
  Tests: `financial_aggregate_boundary_test` + every canonical test.

**Phase-4 closure verdict: Code complete — external verification pending.**
Phase-4 production code and all automated (Drift/provider/domain) invariants are
**closed locally**; the only remaining acceptance is device/PDF/UI spot-checks
(listed per finding above, and per batch). This item is closed; the wider program
(Phases 5–9, MALI-026, live revision-CAS activation, external validation) remains
open. `kServerRevisionCas` stays **false**; migrations 0068–0070 remain
undeployed; engagement-event authority not activated.
