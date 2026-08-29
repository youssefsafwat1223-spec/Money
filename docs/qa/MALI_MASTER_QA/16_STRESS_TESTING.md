# 16 — Stress Testing

Related: [15_PERFORMANCE.md](15_PERFORMANCE.md), [11_TEST_MATRIX.md](11_TEST_MATRIX.md).

## 1. Purpose

Stress testing here means deliberately pushing the system past normal single-user, single-request assumptions to surface concurrency bugs, rate-limit edge cases, and resource-exhaustion behavior — distinct from performance testing (§[15_PERFORMANCE.md](15_PERFORMANCE.md)), which measures normal-load latency.

## 2. Capture pipeline burst scenarios

### `STRESS-CAP-001` — Rapid-fire identical SMS (automation misfire simulation)
Setup: send the same `payloadId`-equivalent request 5–10 times in under a second (simulating a Shortcuts automation that double-fires).
Expected: exactly one `processed_captures` row, exactly one APNs push (collapsed via `apns-collapse-id`), no duplicate transaction.
Verify: concurrent-insert 23505 recovery path in `process-ios-sms` (see [18_REGRESSION.md](18_REGRESSION.md) `REG-015`) returns an idempotent response for every loser request, not a 500.

### `STRESS-CAP-002` — Rate-limit boundary under concurrency
Setup: fire 300+ requests from one `install_id_hash` within one day, with several arriving concurrently near the 300th call.
Expected: exactly the requests up to the limit succeed; the atomic `bump_capture_rate_limit()` RPC (migration `0033`) prevents undercounting from a read-then-write race — verify the final `call_count` accurately reflects the number of attempts, not fewer due to lost increments.
Regression context: the pre-hardening read-then-upsert implementation could undercount under concurrent calls; this scenario is the direct stress-test analog of that fix.

### `STRESS-CAP-003` — Concurrent `sync()` storm
Setup: trigger `CaptureSyncService.sync()` from multiple near-simultaneous callers (app resume + notification-tap handler + a manually-triggered pull-to-refresh, if such exists) with 10+ pending relay captures.
Expected: exactly one network round-trip actually executes per burst (in-flight-future guard), all captures imported exactly once, all acked exactly once.
Regression context: see [18_REGRESSION.md](18_REGRESSION.md) `REG-006`.

### `STRESS-CAP-004` — Large relay backlog (50+ unacked captures)
Setup: a device that has been offline/unopened for a long period accumulates more than `sync-captures`'s per-call limit (50) of unacked relay rows.
Expected: the app drains 50 per call and correctly continues draining across multiple sync cycles until the backlog clears, with no message lost and no duplicate import across cycles.

## 3. Financial-data volume scenarios

### `STRESS-DATA-001` — 10,000+ transaction account
Setup: seed a QA account with 10,000+ transactions spanning multiple years and currencies.
Expected: transaction list, dashboard totals, and every report chart remain correct (cross-check against a raw SQL reference query) and within the budgets in [15_PERFORMANCE.md](15_PERFORMANCE.md).

### `STRESS-DATA-002` — Pagination correctness at scale with clustered timestamps
Setup: seed 2,000+ transactions where many share the exact same `occurred_at` (e.g., a bulk-imported test fixture).
Expected: paginated reads (`.range()`, page size 500) return every row exactly once, in a stable order, with the `occurred_at, id` tiebreak preventing skip/duplicate at page boundaries.

### `STRESS-DATA-003` — Many accounts, many currencies
Setup: seed 20+ accounts across 8+ supported currencies for one user.
Expected: the dashboard currency switcher and per-currency totals remain correct and responsive; no currency's total is accidentally merged into another's due to a case-sensitivity or whitespace bug in currency-code comparison (verify `.trim().toUpperCase()` is applied consistently everywhere currency codes are compared).

## 4. Multi-device / multi-session scenarios

### `STRESS-MULTI-001` — Same user, three devices, concurrent writes
Setup: sign in as one QA user on three separate app instances/devices, all with `transactions_supabase_primary` ON, and perform overlapping writes (different transactions) from all three within a short window.
Expected: no lost writes, no corrupted rows, RLS scoping never leaks a write to the wrong user (trivially true here since it's the same user, but confirms the concurrency path doesn't accidentally cross wires).

### `STRESS-MULTI-002` — Rapid flag toggling across resume cycles
Setup: toggle a Supabase-primary override on/off/on for a QA user across several rapid app resume cycles.
Expected: `AppShell._handleSupabasePrimaryFlagTransition()` correctly invalidates providers and resets `activeAccountIdProvider` on every genuine transition, with no crash or stuck-stale-provider state, even under rapid toggling.

## 5. Failure-injection scenarios

### `STRESS-FAIL-001` — Backend down entirely during a capture burst
Setup: disable/block the Supabase project's reachability (or simulate via a network-level block) while multiple SMS captures arrive.
Expected: every capture falls back to the local/native path cleanly (no crash, no stuck queue), and all of them import correctly once the app is later opened while backend connectivity is restored — see [11_TEST_MATRIX.md](11_TEST_MATRIX.md) `CAP` scenarios D and L.

### `STRESS-FAIL-002` — Drift database corruption/mismatched key recovery
Setup: intentionally corrupt or mismatch the local SQLCipher key (e.g., by manipulating the Keychain-stored key in a test environment) and relaunch the app.
Expected: the app's own recovery screen ("تعذّر فتح بياناتك") is shown rather than crashing; the documented recovery path (equivalent to the in-app "Reset Data" button: delete the `.sqlite`/`-wal`/`-shm` files and relaunch) restores a functioning, empty local database.
Caution: this scenario is destructive to local data by construction — only ever perform it against a QA device/account, never against a device holding real user data.

### `STRESS-FAIL-003` — Mirror-write failure during a Supabase-primary write burst
Setup: force the local Drift mirror write to fail (e.g., simulate a disk-full or locked-database condition) immediately after several successful Supabase writes.
Expected: every user-visible operation still reports success (Supabase is authoritative); `financial_cache_health` is marked dirty for the affected entity type; a later successful resume triggers `FinancialCacheRepairService` and clears the dirty flag without data loss.

## 6. Reporting stress-test results

Stress tests are not part of the standard per-PR gate suite (see [10_TEST_STRATEGY.md](10_TEST_STRATEGY.md) §3) — they are run deliberately before a significant rollout milestone (e.g., before raising a flag's global `rollout_percent` above 0 for the first time) and their results are recorded in the release's report (see [20_FINAL_REPORT_TEMPLATE.md](20_FINAL_REPORT_TEMPLATE.md) and [19_RELEASE_GUIDE.md](19_RELEASE_GUIDE.md)).
