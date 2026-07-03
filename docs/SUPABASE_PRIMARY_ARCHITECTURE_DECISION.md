# ADR: Local-First (Drift) vs Supabase-Primary Architecture

Status: **Phase F complete — Smart Inbox pull-sync implemented (all flags OFF by default).**
Date: 2026-07-03 · Author: architecture review on branch `feat/accounts-multicurrency`
Updated: 2026-07-03 · Phase F done — `SmartInboxSyncService` (pull-only) wired behind `smart_inbox_pull_sync` flag.

### Current state (Phase F)
- Drift writes (create/update/delete) queue to `ledger_sync_outbox` when signed-in + `ledger_push_sync` ON.
- `LedgerSyncEngine.sync()` runs on cold start + resume: push outbox → pull remote, in that order.
- `SmartInboxSyncService.pull()` runs after `LedgerSyncEngine.sync()`, pulling `user_smart_inbox` rows into `smart_inbox_items` Drift table.
- Smart Inbox pull is guarded by `smart_inbox_pull_sync` flag (OFF by default).
- Drift remains the sole source of truth for all UI reads. No direct Supabase reads in widgets.
- `processed_captures` relay untouched. Android SMS flow unchanged.
- Drift schema version 17: added `ledger_sync_outbox` (v16) and `smart_inbox_items` (v17) tables.

### Migration phases status
| Phase | Description | Status |
|-------|-------------|--------|
| A | Server ledger schema (dark launch) | ✅ Done — `0014_user_ledger.sql` |
| B | Dual-write in `process-ios-sms` (signed-in users) | ✅ Done — `ledger_dual_write` flag (OFF) |
| C | Pull sync: `user_transactions` → Drift (flag OFF) | ✅ Done — `ledger_pull_sync` flag (OFF) |
| D | Local outbox: Drift writes → Supabase push (flag OFF) | ✅ Done — `ledger_push_sync` flag (OFF) |
| E | Bidirectional `LedgerSyncEngine` (push→pull unified) | ✅ Done — single `_runLedgerSync()` in AppShell |
| F | Smart Inbox sync | ✅ Done — `smart_inbox_pull_sync` flag (OFF), `smart_inbox_items` Drift table (v17) |
| G | Planning data (budgets/categories/etc.) | ⬜ Plan only |
| H | processed_captures retirement | ⬜ Plan only |

---

## 0. Inventory (inspected, not assumed)

**Drift tables (31)** — client, SQLCipher-encrypted:
- **Ledger (the contested core):** `transactions`, `accounts`, `suspected_duplicates`, `dedup_hashes`
- **Planning:** `budgets`, `goals`, `goal_contributions`, `plans`, `plan_transaction_links`, `subscriptions`, `bill_payments`
- **Personalization:** `user_settings`, `merchants`, `merchant_category_map`, `categories`, `pending_merchant_feedback`, `sender_bank_mappings`
- **Gamification:** `achievements`, `streaks`, `xp_levels`
- **Catalog mirrors (already server-sourced):** `remote_banks/parsers/currencies/countries/categories/feature_flags/announcements/growth_campaigns/merchant_keywords`, `catalog_metadata`, `parsing_rules`

**Supabase tables (20):** `profiles`, `backups` (E2E blobs), `metrics`, `bank_rules`, catalog set (`banks`, `sms_parsers`, `currencies`, `countries`, `categories`, `catalog_versions`), `feature_flags`, `announcements`, `growth_campaigns`, `merchant_keywords`, `ai_rate_limits`, `sender_bank_mappings`, **Phase 1/2:** `capture_devices` (+APNs cols), `processed_captures` (relay), `capture_fingerprints`, `capture_rate_limits`.

**Edge functions (14):** catalog-delta/-flags/-versions/-announcements/-campaigns, parse-sms, enrich-merchant, bank-discovery, merchant-feedback, parser-test, **process-ios-sms, register-device, register-push-token, sync-captures**.

Reading of the inventory: **Qirsh is already a hybrid.** Catalog, flags, campaigns, merchant intelligence, AI, capture relay, push — all Supabase-primary today. The only thing that is local-primary is the **financial ledger + planning data**, i.e. exactly the data the product promises stays on-device (`pubspec: "Arabic-first, on-device"`).

---

## 1. The two options

### Option A — Current: Local-First ledger + Supabase relay
Drift = source of truth. `processed_captures` = ephemeral relay (ack→delete). Backend never holds a lasting ledger.

### Option B — Supabase-Primary ledger
Postgres = source of truth for transactions/Smart Inbox (later budgets etc.). Drift = offline cache/mirror. Push carries real server row IDs.

---

## 2. Detailed comparison

| # | Dimension | A: Local-First (current) | B: Supabase-Primary |
|---|---|---|---|
| 1 | **iOS Shortcut SMS** | Works today (Phase 1/2): backend processes → relay row → push → app syncs into Drift. Sync/ack/delete choreography is the cost. | Marginally simpler server-side (write final row, no relay/ack), but the app STILL needs pull-into-cache for offline reads — the choreography moves, it doesn't disappear. |
| 2 | **APNs** | Push already carries payloadId/type; tap works after import (implemented). | Push carries permanent server IDs; tap can deep-link before local sync. Nicer, not transformative. |
| 3 | **Offline** | Perfect: every feature works offline forever; capture falls back to local engine. | Reads OK from cache. **Writes offline require an outbox + replay + conflict resolution engine** — you must build the hardest part of local-first anyway, now with two authorities. In Qirsh's target markets offline is not an edge case. |
| 4 | **Privacy & consent** | Financial data on device (SQLCipher) + E2E backups; server sees only sanitized capture relay (opt-in, TTL). Matches brand promise. | Full plaintext ledger server-side (RLS-protected but operator-readable). Consent copy, privacy policy, and the "on-device" positioning must all be rewritten. Guest mode becomes second-class (auth required for RLS). |
| 5 | **Security & RLS** | Small server surface; RLS on backups/profiles only; capture relay is service-role + device-secret. | RLS needed on every ledger table; anon/guest access impossible safely → forced accounts; service-role writes from process-ios-sms must be user-scoped; a single RLS mistake = cross-user financial leak. |
| 6 | **Multi-device** | Weak: manual E2E backup/restore. This is A's real gap. | Strong: login → data. The one dimension where B clearly wins. |
| 7 | **Backup/restore** | Already solved (E2E encrypted, tested). | "Free" (server is the backup) but plaintext; E2E property lost unless a separate encrypted export is kept. |
| 8 | **Smart Inbox** | Local queries on Drift; instant, offline. | Server table + realtime or poll; slower cold path; needs cache anyway. |
| 9 | **Budgets/categories/subs** | Local, instant, offline; budget alerts computed on-device already. | Needs server schema + sync for data whose queries are per-frame UI reads; highest effort/least benefit group. |
| 10 | **Duplicate detection** | Layered and done: payloadId + fingerprints (server) + field detector (Drift import). | Server-only detector is authoritative and simpler conceptually, but Android local capture still writes locally → cross-source dedup still needs the client layer. |
| 11 | **AI processing** | Server-side already (consent-gated, sanitized, rate-limited). Identical in both. | Same. Non-differentiator. |
| 12 | **Sync complexity** | One-directional import + ack (implemented, ~small). | Bidirectional sync + conflict resolution + outbox + tombstones + migration backfill: the single biggest engineering object in the app's history. |
| 13 | **Cost/scale** | Server load ≈ captures + catalog + AI. Near-flat per user. | Every read/write/realtime channel hits Postgres; egress + connection limits; free tier exits quickly with growth. |
| 14 | **Migration effort** | Zero. | Ledger backfill for existing installs, dual-write period, guest→account migration, E2E-backup semantics change; months, not weeks. |
| 15 | **Risk to Phase 1/2** | None. | process-ios-sms/sync-captures/APNs payloads all change (relay → ledger rows); high regression surface on the newest, least-hardened code. |
| 16 | **App Store/privacy label** | "Data not collected" (capture relay is ephemeral + opt-in). | Financial info **collected & linked to identity** → label change, privacy-policy rewrite, higher review scrutiny, GDPR-ish obligations (export/delete flows server-side). |
| 17 | **Fit for Qirsh today** | Matches promise, markets, guest-first onboarding, current team size. | Right architecture **only if** multi-device/web becomes a committed product goal. |

---

## 3. Classification of data (what goes where)

| Category | Verdict |
|---|---|
| Stays **local-only** | gamification (achievements/streaks/xp), user_settings UI prefs, dedup_hashes, drafts, biometric/lock state |
| Already **server-primary** (keep) | catalog set, feature flags, announcements, campaigns, merchant_keywords, sender_bank_mappings sync, AI, capture relay, push tokens, E2E backups, metrics |
| **Hybrid** (relay/cache, keep as is) | processed_captures ⇄ Drift import; merchant feedback queue |
| Would need **server equivalents under B** | transactions, accounts, suspected_duplicates (Smart Inbox), budgets, goals(+contributions), plans(+links), subscriptions, bill_payments, merchants/merchant_category_map — **10–12 new tables**, each with RLS (`user_id = auth.uid()`), updated_at/tombstone columns, and indexes mirroring the ~15 Drift indexes |
| New **edge functions under B** | transactions-crud (or PostgREST+RLS direct), sync-pull/push (delta by updated_at), migrate-ledger (initial upload), account-merge (guest→user), export/delete-my-data |
| Flutter changes under B | every `Drift*Repository` gains a server twin + sync layer; `app_providers.dart` rewires ~20 providers; CaptureSyncService becomes bidirectional SyncEngine; auth becomes mandatory gate |

---

## 4. Phased migration plan (defined now, executed only on trigger — see §5)

> **Trigger to start Phase A:** multi-device sync or a web dashboard becomes a committed roadmap item — not before.

**Phase A — server ledger schema only (dark launch)**
- Goal: `user_transactions` + `user_smart_inbox` tables exist, zero traffic.
- Files: `supabase/migrations/0014_user_ledger.sql` only.
- Tables: user_transactions, user_smart_inbox (user_id FK auth.users, RLS owner-only, updated_at, deleted_at).
- Functions: none. Flutter: none.
- Risks: none (unused schema). Tests: RLS probe tests (anon/other-user denied). Rollback: drop tables.

**Phase B — dual-write for iOS captures (signed-in users only)**
- Goal: process-ios-sms writes relay row AND user_transactions row when a real auth user exists; app still imports from relay exactly as today.
- Files: `process-ios-sms/index.ts`, `_shared/ledger.ts`, Deno tests.
- Risks: double-accounting if client later also pushes the same tx (guard: server rows carry payload_id; client sync must upsert by payload_id).
- Tests: idempotency across both tables; guest path unchanged. Rollback: feature-flag `ledger_dual_write` off.

**Phase C — Smart Inbox + history reads go server-first (auth users, online)**
- Goal: inbox/list screens read a synced cache that pulls deltas from user_* tables; Drift rows become mirror rows (server_id column).
- Files: new `SyncEngine` service, transactions/smart-inbox providers, Drift migration (server_id, synced_at columns), sync-pull function or PostgREST.
- Risks: cache staleness, pagination, ordering vs local rows from Android path (merge by payload_id/server_id).
- Tests: offline read, delta sync, merge dedup. Rollback: provider flag back to Drift-native queries (mirror columns are additive).

**Phase D — budgets/categories/subscriptions/goals server-side**
- Goal: planning data moves; alerts computed server-side (cron) or stay client (recommended: stay client).
- Files: migrations for 6–8 tables + repositories + sync mappers; NotificationPlanner untouched (reads cache).
- Risks: widest UI blast radius; conflict semantics (budget edited on two devices). Tests: per-repo sync round-trip. Rollback: same flag pattern per table.

**Phase E — Drift demoted to cache + conflict resolution**
- Goal: outbox for offline writes; last-write-wins with updated_at + per-field merge for budgets; tombstones.
- Files: SyncEngine (outbox/replay), all write paths route through it.
- Risks: THE hard phase — data-loss bugs live here; needs soak time on TestFlight.
- Tests: property-style conflict tests, airplane-mode write/replay matrix. Rollback: outbox is additive; disable replay → app behaves like C/D.

**Phase F — retire relay (`processed_captures`)**
- Goal: iOS capture writes ledger directly; relay + sync-captures deleted; APNs carries transactionId only.
- Files: process-ios-sms, sync-captures (delete), Swift intent response handling, CaptureSyncService removal.
- Risks: guests still need the relay (no user_id!) → **relay can only be retired if guest mode is retired or guests keep a device-scoped ledger** — flagged as an open product decision.
- Tests: full manual matrix from Phase 1/2 doc rerun. Rollback: keep relay code path behind flag for one release.

Each phase ships alone, gates green (`flutter analyze`, `flutter test`, Deno tests, xcodebuild for the extension), with a changed-files report.

---

## 5. Decision (updated 2026-07-03)

**Gradual Supabase-primary migration approved. Phase A started.**

The original recommendation was to stay local-first. That recommendation was reviewed and the decision was changed:
- Qirsh will gradually migrate toward Supabase-primary for the financial ledger.
- Migration is incremental, phase-by-phase, with no big-bang rewrite.
- Drift stays as source of truth and offline cache until Phase C+.
- Phase 1/2 iOS capture relay is untouched.

**Known trade-offs accepted:**
- RLS correctness becomes critical (a mistake = cross-user financial data leak).
- Offline writes require an outbox/replay/conflict engine (Phase E).
- App Store privacy label will need updating when ledger data is collected.
- Guest mode path must be clarified before Phase F (relay retirement).

**Constraints (must remain in effect across all phases):**
- No big-bang rewrite. One phase at a time.
- Phase 1/2 iOS capture + APNs system must stay working throughout.
- Drift not removed until Phase E is fully validated.
- `processed_captures` relay not retired until Phase F.
- Budgets/categories/subscriptions/goals not touched until Phase D.
- No commits without explicit user request.

**Decision:** Supabase-primary gradual migration ✅ · Phase A done · See phase status table at top of this document.
