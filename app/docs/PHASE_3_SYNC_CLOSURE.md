# Phase 3 — Sync & Multi-Device Correctness — Closure

Status as of 2026-08-04, branch `feat/phase1-data-integrity`. Phase 3 is
**locally complete**; live-backend and two-device verification remain **external
and pending**. This document reconciles every Phase-3 finding, proves the
gamification single-authority invariant, and records the architecture, entity
contracts, migration/capability posture, external verification plan, and test
inventory. It does **not** declare Phase 3 fully externally closed.

Historical audit reports (`FULL_APP_AUDIT.md`, `FINAL_FULL_PRODUCTION_AUDIT.md`)
are untouched.

Batch commits: B1 `acf9ca99` · B2 `d6820285` · B3 `4a2da692`/`de672bc0`/`0e52da68`
· B4 `58614ad4`/`124fd83b` · B5 `96993c5e`/`74a77398`.

---

## 1. Phase-3 finding reconciliation

Statuses: **Closed-LV** = Closed, locally verified · **CC-LV** = Code complete,
locally verified, external verification pending · **Superseded**.

| Finding | Status | Evidence / note |
|---|---|---|
| MALI-051n | CC-LV | Durable `parked_child_rows` + drain; cursor never skips a missing-parent child. Local tests only; two-device replay is external. `acf9ca99` |
| MALI-052n | CC-LV | Outbox coalescing/re-basing (`d6820285`) + universal conflict policy/resolver for all 12 entities (`de672bc0`). Two-device edit/edit external. |
| MALI-055n | CC-LV | Dedicated `account_default_command` (no broad rewrite) + guarded accounts update. Live default-switch + field-preservation external. `58614ad4` |
| MALI-056n | CC-LV | Versioned canonical ledger payload (v2) + compatibility + future dead-letter. Live round-trip external. `124fd83b` |
| MALI-057n | CC-LV | Pull/push base compare + universal per-entity policy. Folds into 052n. `de672bc0`/`0e52da68` |
| MALI-072n | CC-LV | Durable sender-mapping sync: keyset + tombstones + typed errors. Live two-device external. `96993c5e` |
| MALI-008 (periphery) | CC-LV | Closed via 072n durable sync + typed `_isConflict` replacement. Live backend external. `96993c5e` |
| MALI-009 | CC-LV | Versioned canonical payload preserves type/direction/status/source + base-token round-trip. Live 2-device external. `124fd83b` |
| MALI-010 | CC-LV | withdrawal/refund/unknown/source round-trip via canonical metadata (no lossy debit/credit collapse). `124fd83b` |
| MALI-022 | CC-LV · **live CAS external-pending** | Server revision CAS migration 0068 + universal resolver + dormant client CAS plumbing gated OFF. Activation blocked on staging concurrency tests. `4a2da692`/`de672bc0`/`0e52da68` |
| MALI-023 | Closed-LV | Typed failure classes + dead-letter + bounded backoff + re-arm. Deterministic + fully unit-tested. `d6820285` |
| MALI-024 | CC-LV | Server-authoritative idempotent engagement events (0070 + locked RPC); client aggregate-total upload removed. Live RPC concurrency/security + authority-overlap (§2) confirmed no overlap. `74a77398` |

No finding is Still-open or Partially-complete. MALI-057n is effectively a facet
of the 052n/022 conflict contract (documented, not separately superseded).

Nothing live (Supabase, two devices) is marked Closed without evidence — the
only Closed-LV item (MALI-023) is a purely local retry/dead-letter mechanism.

---

## 2. Gamification authority-overlap proof (invariant: exactly one active award authority per business event)

**Current active authority = the legacy Edge path only. The new RPC/event path
is present, wired, and tested, but DORMANT — no production code enqueues an
engagement event.** Therefore no business event can be awarded twice.

Evidence at HEAD:
- `grep -rn '\.enqueue(' app/lib | grep engagement` → **none**. The only
  production caller of the engagement service is `app_shell.dart` `push()`, which
  drains pending events — of which there are none.
- Legacy: `evaluate_gamification_trigger` `AFTER INSERT ON user_transactions`
  (migration 0057) → the `evaluate-gamification` Edge Function (10 XP + 1st/10th/
  100th-transaction achievements). A transaction inserts once (idempotent by
  `client_request_id` upsert on `user_transactions`), so a replay does not
  re-fire the trigger → no double award and no duplicate notification-trigger row.

### Event-authority matrix

| Business action | Flutter/domain source | Legacy Edge trigger | New event enqueue path | **Active authority** | Idempotency key | XP/streak/achievement | Notification source | Migration | Rollout |
|---|---|---|---|---|---|---|---|---|---|
| Transaction creation/insert | ledger outbox → `user_transactions` | `evaluate_gamification_trigger` (AFTER INSERT) | — (not enqueued) | **Edge** | `client_request_id` (row) | +10 XP; 1/10/100 achievements | Edge Function | 0057 | active |
| Transaction confirmation | confirm flow (no new insert) | — (insert-only trigger) | — | **none** (no re-award) | n/a | none | — | — | n/a |
| Budget activity | budgets outbox | `evaluate_budgets_trigger` (evaluation/notify, not XP) | — | **none for XP** | n/a | none | Edge (evaluation) | 0057 | n/a |
| Goal creation/progress/contribution | goals + goal_contributions | — | — (RPC type `goal_contribution` defined, not enqueued) | **none active** | event_id/business_key (when activated) | +15 (when activated) | — | 0070 (dormant) | inactive |
| Bill payment | bill_payments | — | — (RPC type `bill_payment` defined, not enqueued) | **none active** | event_id/business_key | +5 (when activated) | — | 0070 (dormant) | inactive |
| Plan activity | plans | — | — | **none** | n/a | none | — | — | n/a |
| Streak-eligible activity | app activity | — | — (RPC type `streak_activity` defined, not enqueued) | **none active** | event_id | +2 (when activated) | — | 0070 (dormant) | inactive |
| Achievement unlock | server evaluation | Edge (transaction achievements) | — | **Edge** | `(user_id, achievement_key)` unique | achievement row | Edge → pull notify | 0056/0057 | active |
| Onboarding/bootstrap award | — | — | — (client upload REMOVED) | **none** (no client authority) | n/a | none | — | — | n/a |
| Manual/background gamification | — | — | — | **none** | n/a | none | — | — | n/a |

### Proven invariants
- **No action calls both paths.** The Edge path is trigger-bound to transaction
  insert; the RPC path has zero production enqueue callers.
- **Duplicate delivery is idempotent on the chosen path.** Edge: transaction
  `client_request_id` upsert → single insert → single trigger. RPC (tests):
  `UNIQUE(user_id, event_id)` + business_key → single award.
- **Bootstrap cannot upload aggregate totals.** The client aggregate-upload was
  removed (`GamificationSyncService` is pull-only); the aggregate tables have no
  client write policy.
- **Pull cannot erase pending-event projection.** The pull writes only the
  acknowledged aggregate; the projection = acknowledged + pending, computed for
  display, never persisted over pending events.
- **No cross-path double-award over time.** Because the RPC path is dormant, no
  event has been awarded by the Edge path and could be re-awarded by the RPC. See
  the activation constraint below.

### Activation constraint (for the future migration that turns the RPC path on)
Before any production code enqueues an engagement event for an action the Edge
path already awards (today: transaction insert), that action MUST be removed from
the Edge award path (or the RPC award for that type disabled) in the SAME change,
so the "exactly one active authority" invariant is preserved. This is a Phase-4+
migration constraint, recorded here; it is not a current overlap.

**Conclusion: no overlap exists at HEAD. Not a Batch-5 regression.**

---

## 3. Phase-3 sync architecture

```
Local domain write
  → Drift transaction (atomic with any child/event write)
  → durable + coalesced outbox row  OR  immutable append-only event
  → bounded retry / typed dead-letter (OutboxFailureClass)
  → capability-aware push (kServerRevisionCas gate; guarded fallback)
  → server idempotency (client_request_id / event_id) · revision CAS · atomic RPC
  → acknowledgement: store server updated_at + revision (base tokens)
  → keyset pull (updated_at, id) with a durable cursor
  → atomic local apply + cursor advance (per page, in one transaction)
  → conflict resolution (interactive) OR deterministic per-entity policy
```

Entity families:
- **Mutable revision-CAS entities** (transactions, accounts, budgets,
  subscriptions, goals, plans, cards, settings, categories): server `revision`
  compare-and-set (0068, gated OFF); guarded `updated_at` compare in the OFF
  path; universal conflict policy (interactive for financial, deterministic
  prefer-remote for config).
- **Immutable append-only children** (goal_contributions, bill_payments,
  plan_transaction_links): idempotent keyed insert + tombstone; no revision;
  cannot conflict.
- **Dedicated account-default command**: a single `account_default_command`
  resolved to the atomic `set_default_account` RPC; rewrites no account fields.
- **Sender mappings**: keyset + tombstones + server-authoritative `updated_at`
  (0069) + pending-safe LWW + typed errors.
- **Engagement events**: durable local outbox → locked-down server RPC (0070)
  that decides the award idempotently; client shows acknowledged + projection.
- **Parked children**: missing-parent rows parked durably; cursor never advances
  past them.
- **Dead-letter recovery**: typed permanent vs transient; bounded backoff;
  `reArmDeadLetter()` after a compatible app upgrade.

---

## 4. Entity contract matrix

Legend: rev = revision-CAS; LWW = last-write-wins; — = n/a. Capability gate
`kServerRevisionCas` is OFF for all; the OFF path is the guarded `updated_at`
compare (never a blind overwrite).

| Entity | Local SoT | Outbox/event | Ops | Coalescing | Idempotency key | Base rev | Server mutation | Conflict policy | Tombstone | Pull pagination | Cursor | Retry/DL | Sign-out flush | Backup | Capability gate | External verify |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| accounts | `accounts` | planning_sync_outbox | c/u/d | per-entity | local_id | server_revision | upsert / guarded CAS | interactive | deleted_at | keyset | planning | yes | yes | included | rev (OFF) | 2-device |
| account default | — | account_default_command | cmd | singleton latest | operation_id | — | `set_default_account` RPC | last-RPC-wins | — | — | — | missingDep defer | yes | excluded | — | live RPC |
| transactions | `transactions` | ledger_sync_outbox | c/u/d | per-entity | client_request_id | server_revision | upsert / guarded CAS | interactive | hard-delete (local) | keyset | ledger | yes | yes | included | rev (OFF) | 2-device |
| budgets | `budgets` | planning_sync_outbox | c/u/d | per-entity | local_id | server_revision | upsert / guarded CAS | interactive | deleted_at | keyset | planning | yes | yes | included | rev (OFF) | 2-device |
| goals | `goals` | planning_sync_outbox | c/u/d | per-entity | local_id | server_revision | upsert / guarded CAS | interactive | deleted_at | keyset | planning | yes | yes | included | rev (OFF) | 2-device |
| subscriptions/bills | `subscriptions` | planning_sync_outbox | c/u/d | per-entity | local_id | server_revision | upsert / guarded CAS | interactive | deleted_at | keyset | planning | yes | yes | included | rev (OFF) | 2-device |
| plans | `plans` | planning_sync_outbox | c/u/d | per-entity | local_id | server_revision | upsert / guarded CAS | interactive | deleted_at | keyset | planning | yes | yes | included | rev (OFF) | 2-device |
| cards | `cards` | planning_sync_outbox | c/u/d | per-entity | local_id | server_revision | upsert / guarded CAS | deterministic→server | deleted_at | keyset | planning | yes | yes | included | rev (OFF) | 2-device |
| user settings | `user_settings` | planning_sync_outbox | u | per-entity | local_id | server_revision | upsert / guarded CAS | deterministic→server | — (singleton) | singleton | planning | yes | yes | partial (no secrets) | rev (OFF) | 2-device |
| custom categories | `categories` | planning_sync_outbox | c/u/d | per-entity | local_id | server_revision | upsert / guarded CAS | deterministic→server | deleted_at | keyset | planning | yes | yes | included | rev (OFF) | 2-device |
| goal contributions | `goal_contributions` | planning_sync_outbox | c/d | append-only | client id | — | idempotent insert + tombstone | none | deleted_at | keyset | planning-child | yes | yes | included | 2-device |
| bill payments | `bill_payments` | planning_sync_outbox | c/d | append-only | client id | — | idempotent insert + tombstone | none | deleted_at | keyset | planning-child | yes | yes | included | 2-device |
| plan links | `plan_transaction_links` | planning_sync_outbox | c/d | append-only | client id | — | idempotent insert + tombstone | none | deleted_at | keyset | planning-child | yes | yes | included | 2-device |
| smart inbox | `smart_inbox_items` | (server-authored) | status push | — | server_id | — | status update | dismissed-wins | deleted_at (server) | keyset | smart_inbox | best-effort | yes | excluded | — | 2-device |
| sender mappings | `sender_bank_mappings` | (pending_sync + tombstone) | c/u/d | — | normalized_sender_id | — (updated_at LWW) | upsert + tombstone | pending-safe LWW | deleted_at (0069) | keyset | sender cursor | typed retry | yes | excluded | live 2-device |
| notification logs | local | (device-local) | — | — | — | — | — | — | — | — | — | yes (MALI-053n) | excluded | — | — |
| engagement events | `engagement_events` | engagement_events | append | dedup by business_key | event_id/business_key | — | `record_engagement_event` RPC | server idempotent | — | (no pull) | — | typed retry/DL | yes | excluded | live RPC |

Every synced entity is represented; specialized-service entities (smart inbox,
sender mappings, engagement events) are included.

---

## 5. Migration & capability ledger

| | 0068 revision CAS | 0069 sender-mapping durability | 0070 engagement events |
|---|---|---|---|
| Schema | `revision` col on 9 mutable tables | `deleted_at` + keyset index on `sender_bank_mappings` | `user_engagement_events` table |
| Functions/triggers | `bump_revision()` INVOKER + BEFORE UPDATE triggers | `set_updated_at` BEFORE UPDATE trigger | `record_engagement_event` RPC |
| RLS/grants | existing owner RLS (unchanged) | owner RLS from 0008 (unchanged) | owner SELECT only; no client write policy |
| SECURITY DEFINER | none (trigger fn is INVOKER) | none (trigger fn is INVOKER) | RPC is DEFINER — fixed search_path, revoked PUBLIC, granted authenticated, auth.uid() ownership |
| Old-client compat | additive; old clients ignore `revision` | additive; old clients ignore `deleted_at` | additive; RPC unused by old clients |
| New-client-before-deploy | CAS gated OFF → guarded updated_at path | keyset/tombstone code paths tolerate absent column (nulls) | event outbox accumulates; push fails safe until RPC exists |
| Capability flag | `kServerRevisionCas = false` | none (behavioral) | none (dormant — no enqueue) |
| Staging activation | apply 0068 → run node CAS contract → flip flag | apply 0069 → 2-device sender test | apply 0070 → run node engagement contract |
| Rollback | drop triggers + column | drop trigger + index + column | drop RPC + table |
| Required live tests | §6 CAS + two-device | §6 two-device sender | §6 gamification |

Explicit statements:
- **`kServerRevisionCas = false`** (`app/lib/core/sync/sync_capabilities.dart`).
- **No source file proves live deployment.** Migrations 0068–0070 are authored,
  lint-clean, and NOT deployed.
- **0068 activation is blocked** until staging apply + real-Postgres concurrency
  tests pass.
- **0069 and 0070 also require real-backend verification** before their
  live-dependent findings (MALI-072n/008/024 live tails) are fully closed.

---

## 6. External verification plan (Phase-3 checklist)

### A. Migration apply (evidence: psql/CLI logs)
- [ ] Clean staging apply of 0068, 0069, 0070 (in order).
- [ ] Upgrade path from 0067 (no data loss).
- [ ] RLS policies + grants present as authored (\d+ + pg_policies).
- [ ] RPC EXECUTE granted to authenticated, revoked from PUBLIC/anon.
- [ ] Triggers present (bump_revision, set_updated_at, evaluate_gamification).
- [ ] Keyset/revision indexes present.
- [ ] PostgREST schema cache refreshed.

### B. Revision CAS (evidence: node contract + SQL)
- [ ] Exactly one of two concurrent updates succeeds; the other → typed conflict.
- [ ] A stale revision returns 0 rows → typed conflict (no overwrite).
- [ ] Cross-user mutation fails (RLS).
- [ ] Retry after a lost response is idempotent.
- [ ] `kServerRevisionCas` flipped ON only after all the above pass.

### C. Two-device (evidence: device recordings + DB dumps)
- [ ] Consecutive edits; edit/edit; edit/delete.
- [ ] Conflict keep-local / keep-remote.
- [ ] Default switch vs concurrent account rename (no field rollback).
- [ ] Child-before-parent ordering; parked-child replay.
- [ ] Sender-mapping tombstone propagation A→B.
- [ ] Ledger withdrawal/refund/source/status round-trip.

### D. Gamification (evidence: node contract + parallel RPC)
- [ ] Duplicate event awards once.
- [ ] Two concurrent events do not lose an increment.
- [ ] User A cannot submit for user B (auth.uid()).
- [ ] Arbitrary XP cannot be supplied (no XP parameter).
- [ ] Unknown type / unsupported version rejected.
- [ ] Response-loss retry returns the original result.
- [ ] Pending local projection reconciles exactly once.
- [ ] No overlap with the legacy award path (see §2 activation constraint).

---

## 7. Phase-3 test inventory

Grouped; counts are local Dart/Node tests. "Local" = proven with in-memory
Drift / fakes; "External" = needs real Postgres or two devices.

| Group | Files | Proven locally | Unproven without real PG / 2 devices |
|---|---|---|---|
| Child parking | `child_pull_parking_test` (6) | park/drain/no-skip-cursor | 2-device replay ordering |
| Outbox coalescing | `outbox_coalesce_retry_test` (coalesce cases) | matrix folding, per-entity | — |
| Retry/dead-letter | `outbox_coalesce_retry_test` (retry cases) | typed classes, backoff, re-arm | — |
| CAS | `revision_cas_test` (planning, 6), `ledger_revision_cas_test` (2), `revision_cas_node_test.mjs` (3, gated) | OFF/ON/null/stale/unsupported decision + fail-safe | live 0-row CAS, concurrency, RLS |
| Conflicts | `conflict_resolver_test` (8), `planning_conflicts_sheet_test` | policy for all 12, keep-local/remote, auto-resolve | 2-device collisions |
| Accounts / default | `account_default_command_test` (10) | no broad rewrite, coalescing, idempotent, deterministic winner | live RPC + 2-device |
| Ledger payload | `ledger_payload_test` (~21), `ledger_roundtrip_test` (~18) | mapping table, round-trip every type/source, compat, future | 2-device round-trip |
| Sender mappings | `sender_bank_mapping_sync_service_test` (11) | keyset, tombstones, LWW, typed errors, crash/restart | live 2-device |
| Gamification events | `engagement_event_service_test` (12), `gamification_sync_service_test` (pull-only), `engagement_events_node_test.mjs` (5, gated) | offline, projection, idempotency, dead-letter, tamper-impossible | live RPC concurrency/ownership |

---

## 8. Conclusion

Phase 3 is **locally complete** across all twelve findings. The gamification
single-authority invariant holds at HEAD (§2). Live-backend verification
(migrations 0068–0070, CAS, RPC concurrency/security) and two-device verification
remain **external and pending** — Phase 3 is **not** declared fully externally
closed. `kServerRevisionCas` remains `false`; nothing is deployed or pushed.
