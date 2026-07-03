# ADR: Local-First (Drift) vs Supabase-Primary Architecture

Status: **Phases A-F + I-J implemented — all sync flags OFF by default. Phases G-H are plan-only.**
Date: 2026-07-03 · Author: architecture review on branch `feat/accounts-multicurrency`
Updated: 2026-07-04 · ADR wording clarified to separate implemented phases from plan-only phases.

### Current implemented state
- Drift writes (create/update/delete) queue to `ledger_sync_outbox` when signed-in + `ledger_push_sync` ON.
- `LedgerSyncEngine.sync()` runs on cold start + resume: push outbox → pull remote, in that order.
- `SmartInboxSyncService.pull()` runs after `LedgerSyncEngine.sync()`, pulling `user_smart_inbox` rows into `smart_inbox_items` Drift table.
- Smart Inbox pull is guarded by `smart_inbox_pull_sync` flag (OFF by default).
- Supabase environment selection supports local/staging/production; production remains the default unless explicitly overridden.
- Per-user feature flag overrides exist and can safely enable dark-launched sync flags for individual signed-in testers.
- Drift remains the sole source of truth for all UI reads. No direct Supabase reads in widgets.
- `processed_captures` relay untouched. Android SMS flow unchanged.
- Drift schema version 17: added `ledger_sync_outbox` (v16) and `smart_inbox_items` (v17) tables.

### Implemented phases
| Phase | Description | Status |
|-------|-------------|--------|
| A | `user_transactions` / `user_smart_inbox` schema | ✅ Implemented |
| B | `ledger_dual_write` foundation | ✅ Implemented, flag OFF |
| C | `user_transactions` pull sync into Drift | ✅ Implemented, flag OFF |
| D | Local outbox | ✅ Implemented, flag OFF |
| E | Bidirectional `LedgerSyncEngine` | ✅ Implemented, sync flags OFF |
| F | Smart Inbox pull sync | ✅ Implemented, flag OFF |
| I | Staging/prod/local Supabase config | ✅ Implemented |
| J | Per-user feature flag overrides | ✅ Implemented |

### Plan-only phases, not missing code
| Phase | Description | Status |
|-------|-------------|--------|
| G | Planning data sync for accounts/budgets/subscriptions/goals/plans | ⬜ Plan only — intentionally not implemented |
| H | `processed_captures` retirement | ⬜ Plan only — intentionally not implemented |

Phase G and Phase H are future architecture options. They should not be treated as incomplete implementation work in the current codebase.

### Blocked / decision needed
- Android SMS capture is not active. Product/Play policy decision needed: restore SMS capture, or keep Android local/share/manual only.
- `processed_captures` cannot be retired until guest strategy is decided.
- Production sync flags cannot be enabled until staging/manual validation passes.

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

## 4. Remaining plan-only phases

The implemented sync foundation stops at Phases A-F plus I-J. The following phases are intentionally plan-only and should not be reported as missing code.

**Phase G — planning data sync**
- Scope: accounts, budgets, subscriptions, goals, plans, and related planning data.
- Status: plan only / not implemented.
- Trigger: only after ledger sync is validated on staging/manual devices and product confirms multi-device planning sync is needed.
- Risk: wide UI and business-logic blast radius; conflict semantics are harder than transaction pull/push.

**Phase H — `processed_captures` retirement**
- Scope: remove the iOS capture relay path and let backend-processed captures become durable ledger rows directly.
- Status: plan only / not implemented.
- Blocker: guest strategy must be decided first. Guests currently cannot safely write user-scoped ledger rows, so `processed_captures` remains required as a relay.
- Constraint: do not remove `processed_captures`, `sync-captures`, or the Drift import/ack path until Phase H is explicitly approved.

Each future phase must ship alone, keep gates green (`flutter analyze`, `flutter test`, Deno checks when available, xcodebuild for iOS targets), and include a changed-files report.

---

## 5. Decision (updated 2026-07-04)

**Gradual Supabase-primary migration foundation approved and implemented through Phases A-F plus I-J. Phase G/H remain plan-only.**

The original recommendation was to stay local-first. That recommendation was reviewed and the decision was changed:
- Qirsh will gradually migrate toward Supabase-primary for the financial ledger.
- Migration is incremental, phase-by-phase, with no big-bang rewrite.
- Drift stays the source of truth for UI reads while sync flags remain OFF.
- Phase 1/2 iOS capture relay is untouched.

**Known trade-offs accepted:**
- RLS correctness becomes critical (a mistake = cross-user financial data leak).
- Offline writes require an outbox/replay/conflict engine.
- App Store privacy label will need updating when ledger data is collected.
- Guest mode path must be clarified before Phase H (`processed_captures` retirement).

**Constraints (must remain in effect across all phases):**
- No big-bang rewrite. One phase at a time.
- Phase 1/2 iOS capture + APNs system must stay working throughout.
- Drift remains authoritative for UI reads until staging/manual validation proves otherwise.
- `processed_captures` relay not retired until Phase H is explicitly approved.
- Accounts/budgets/subscriptions/goals/plans not synced until Phase G is explicitly approved.
- Production flags remain OFF until staging/manual validation passes.
- Android SMS capture remains a separate product/Google Play policy decision.
- No commits without explicit user request.

**Decision:** Supabase-primary gradual migration foundation ✅ · Implemented phases A-F/I-J · Plan-only phases G/H · See phase status tables at top of this document.
