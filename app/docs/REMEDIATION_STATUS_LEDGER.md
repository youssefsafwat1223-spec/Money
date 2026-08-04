# Mali — Remediation Status Ledger

Single source of truth for the state of every finding from `FULL_APP_AUDIT.md`
(MALI-001…044) and `FINAL_FULL_PRODUCTION_AUDIT.md` (MALI-045n…077n). **No finding
is ever removed from this ledger.** Updated at the end of every phase.

- **Baseline HEAD:** `e2679d0e` (feat/phase1-data-integrity)
- **Last updated:** Phase 4 Batch 3 (Plans + Dashboard budget rings) Code complete · Locally verified — 2026-08-04. Batch 1 `71dc2534`; Batch 2 `c4b6df97`/`2052687d`; Batch 3 `4fa413a9` (plan/budget domain + plan spending) + `4dc0d190` (dashboard rings + budget detail). Batches 4–5 (bills/subscriptions, PDF, card) not started. Phase 3 reconciliation: `PHASE_3_SYNC_CLOSURE.md`.

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
| MALI-018 | High | C+T | P4 | In progress | canonical repo predicate Closed; provider tier: transactions header + Home category (Batch 2 `2052687d`), plan spending + dashboard budget rings + budget detail (Batch 3 `4fa413a9`/`4dc0d190`) all routed through the canonical contract with a cross-surface invariant test; bill/subscription monthly folds + PDF donut remain (Batches 4–5) |
| MALI-019 | High | C | P5 | Not started | subsumed by MALI-061n |
| MALI-020 | High | X | P9 | Locally verified | archive privacy report = gate 5 |
| MALI-021 | High | C | P6/P7 | Not started (scope Closed) | dead file + PDF sweep = MALI-076n/065n |
| MALI-022 | High | C | P3 | Code complete · Locally verified · **live CAS external-pending** | server revision CAS migration 0068 `4a2da692` + universal resolver all 12 `de672bc0` + client CAS plumbing gated OFF `0e52da68` (batch 3); activation blocked on 0068 staging verification |
| MALI-023 | Med | C | P3 | Code complete · Locally verified | typed failure classes + dead-letter + bounded backoff + re-arm; `d6820285` (batch 2) |
| MALI-024 | Med | C | P3 | Code complete · Locally verified | server-authoritative idempotent engagement events (migration 0070 + locked-down record_engagement_event RPC); client aggregate-total upload removed (tamper vector gone); durable event outbox + exactly-once + projection; `bc0e0ddb` (batch 5). Live concurrency/ownership = external |
| MALI-025 | Med | C | P5 | Not started | iOS 64-limit, redaction |
| MALI-026 | Med | C | **P8** | Not started | separate financial-storage project |
| MALI-027 | Med | C | **P1** | Code complete · Locally verified | closed by MALI-046n fix |
| MALI-028 | Med | C | P4 | In progress | half-open `[from, to)` for the canonical repo aggregates (Batch 2 `c4b6df97`); genuine half-open budget + plan periods with no epsilon end (Batch 3 `4fa413a9`/`4dc0d190`); boundary rule enforced for all new callers. Report-boundary + dormant-Supabase standardization remains |
| MALI-029 | Med | C | P7 | Not started | global invalidation breadth |
| MALI-030 | Med | C | P7 | Not started | streamed reports/memory |
| MALI-031 | Med | C | P5 | Not started | App Group encryption/Keychain |
| MALI-032 | Med | C+T | P5 | Not started | telemetry scrub coverage |
| MALI-033 | Med | C | P5 | Not started | Android backup rules (now covers SMS queue) |
| MALI-034 | Med | C | P7 | Not started | import cycle + legacy repair retirement |
| MALI-035 | Med | D | P7 | Not started | CLAUDE.md drift (incl. dangerous "all optional") |
| MALI-036 | Med | X+C | P7/P9 | Code complete (limits) | CI wiring = MALI-066n; hosted run = gate 8 |
| MALI-037 | Med | C | P7 | Not started | CVE/license gate |
| MALI-038 | Low | C+T | P7 | Not started | font bundling (+ test MALI-067n) |
| MALI-039 | Low | C | P5/P7 | Not started | debug diagnostics redaction (debug-only) |
| MALI-040 | Low | T | P7 | Not started | test isolation (subsumed by MALI-067n) |
| MALI-041 | Low | T | P7 | Not started | admin auth test (subsumed by MALI-066n/067n) |
| MALI-042 | Low | T | P7 | Not started | Edge unit isolation (MALI-066n) |
| MALI-043 | Low | P+D | P7 | Decision required | canonical brand name (Mali vs Qirsh) |
| MALI-044 | Low | C | P5 | Not started | metrics WITH CHECK(true) |
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
| MALI-060n | Med | C | P5 | Not started | anon-key AI unmetered |
| MALI-061n | Med | C | P5 | Not started | gamification bypasses policy; budget dual-authority |
| MALI-062n | Med | C | P4 | In progress | Saturday-week fixed in Batch 1 (`RiyadhTime.startOfWeek`); the three divergent weekly/budget-period resolvers unified into one canonical resolver used by ring/detail/reports/alerts + Saturday-anchored history weeks (Batch 3 `4dc0d190`). Per-budget history transaction-LIST vs net-total refund mismatch remains a documented tail |
| MALI-063n | Med | C | P4 | Not started | PDF multi-currency; latent 0030 RPCs |
| MALI-064n | Med | C | P4 | Not started | bill paid double-count; monthly formula |
| MALI-065n | Med | C | P5 | Not started | report PDF tmp lifecycle |
| MALI-066n | Med | C | P7 | Not started | unexecuted-gate cluster |
| MALI-067n | Med | T | P7 | Not started | source-text tests, no-close, warning suppression |
| MALI-068n | Med | C | P5 | Not started | native durability (apply/locks/timestamp) |
| MALI-069n | Med | C | P6 | Not started | conn leak + second-instance busy_timeout |
| MALI-070n | Low | C | P2 | Code complete · Locally verified | pending-actions file purged on destructive paths; `374560ff`. Announcement-dismissal residue = minor, remains backlog |
| MALI-071n | Low | C | P5 | Not started | logo.dev consent gating |
| MALI-072n | Low | C | P3 | Code complete · Locally verified | durable sender-mapping sync: keyset pagination + server-authoritative updated_at + durable cursor + tombstone deletion propagation + LWW (pending-safe) + typed error classification (no string-match); soft-delete replaces hard delete; `96993c5e` (batch 5). Live two-device = external |
| MALI-073n | Low | C | P6 | Not started | missing account_id/category_id indexes |
| MALI-074n | Low | C | P4 | Not started | card refund gross, NULL-account attribution, decimals |
| MALI-075n | Low | C | P5 | Not started | backend lows (search_path, gamification writable, purge coverage) |
| MALI-076n | Low | C | P6 | Not started | backup lows (trim, blob version, hasRemoteBackup, dead export) |
| MALI-077n | Low | C+P | P7 | Not started | ops lows (keystore name, email, dead API, package path) |

## Phase roll-up

| Phase | Findings | Status |
|---|---|---|
| P1 migrations/restore | MALI-046n/027, MALI-045n/014 | **Code complete · Locally verified** (full suite 1003; awaiting approval) |
| P2 lifecycle/consent | 053n,054n,070n,011,017,001,059n | **Code complete · Locally verified** (full suite 1015; commits 374560ff + 89db9f09; awaiting approval) |
| P3 sync | 051n,052n,055n,056n,057n,008,009,010,022,023,024,072n | **LOCALLY COMPLETE** (live/2-device pending) — all 6 batches committed: B1 051n (acf9ca99), B2 052n/023 (d6820285), B3 022/057n/052n revision-CAS+resolver (4a2da692/de672bc0/0e52da68, **live CAS external-pending**), B4 055n/056n/009/010 (58614ad4/124fd83b), B5 072n/008 + 024 (96993c5e/74a77398), B6 closure docs. MALI-023 Closed-LV; all others CC-LV (external tail). Gamification single-authority overlap proof: no overlap (Edge active, RPC dormant) — see `PHASE_3_SYNC_CLOSURE.md` §2. |
| P4 financial | 047n,048n,049n,050n,062n,063n,064n,074n,018,028 | **In progress** — B1 contract (`71dc2534`); B2 047n/050n (`c4b6df97`/`2052687d`); B3 048n/049n + budget-period 028/062n (`4fa413a9`/`4dc0d190`). Batches 4–5 (064n bills, 063n PDF, 074n card) not started. Full suite 1150; analyze 0 |
| P5 security/notif/native | 031,032,033,060n,061n,065n,068n,071n,075n,019,025,044,039 | Not started |
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
- **Product decision:** whether to add a distinct "unconfigured" plan scope
  (empty → zero + prompt) separate from the documented all-expenses default —
  needs an additive `scope_mode` column + UI; not started.
- Budget-history per-period transaction LIST vs net-total refund reconciliation
  (MALI-062n tail) and bill/subscription/PDF surfaces (Batches 4–5).
