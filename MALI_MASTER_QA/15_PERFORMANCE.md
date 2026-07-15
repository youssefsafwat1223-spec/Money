# 15 — Performance

Related: [11_TEST_MATRIX.md](11_TEST_MATRIX.md) `PERF-*`, [16_STRESS_TESTING.md](16_STRESS_TESTING.md).

## 1. Performance philosophy

Mali runs on-device SQL over a growing local database and, increasingly, remote Postgres queries gated by feature flags. Performance work must account for **both** backing stores giving comparable user-perceived latency, since a flag flip should not be user-visible as a performance regression.

## 2. Budgets (targets, to be measured against a mid-tier reference device — not the fastest available)

| Scenario | Budget | Notes |
|---|---|---|
| Cold start → interactive dashboard | < 2.5s | Includes DB open (SQLCipher key retrieval + decrypt), catalog sync kickoff (non-blocking), first paint |
| Warm resume → interactive | < 500ms | Excludes network-bound catalog/capture sync, which run in the background without blocking the UI |
| Transaction list scroll (5,000+ rows) | 60fps sustained, no dropped-frame warnings in profile | Requires proper list virtualization — never a fully materialized widget tree for the full dataset |
| Report aggregation query (10,000+ transactions) | < 300ms (Drift, on-device SQL) / < 500ms (Supabase RPC, network round-trip included) | See [30_ROADMAP.md](30_ROADMAP.md) for the RPC-based reports migration |
| SMS parse (deterministic, on-device isolate) | < 2s hard timeout (enforced), typically < 100ms | The 2s isolate timeout is a correctness bound (never block the UI thread indefinitely on a pathological regex), not a typical-case target |
| `process-ios-sms` end-to-end | < 8s (App Intent's own client timeout) | See [13_NOTIFICATION_PIPELINE.md](13_NOTIFICATION_PIPELINE.md) §3 for the bounded-timeout design keeping this achievable |
| Catalog delta sync | < 1s typical, non-blocking to first paint | Runs on cold start and resume, `await`ed before flag resolution but the UI itself doesn't wait on it further than necessary |

## 3. Where performance work has historically mattered

- **Transaction list and report queries**: as a user's transaction count grows into the thousands (a realistic 1-2 year usage horizon for an active user), unindexed or full-table-scan queries degrade visibly. Every financial query added must be checked against `EXPLAIN`/`EXPLAIN ANALYZE` (Postgres) or Drift's query plan for an unindexed scan.
- **Pagination**: Supabase-primary reads use `.range()` with a page size of 500 (safely under PostgREST's default 1000-row cap) and a stable tiebreak ordering (`occurred_at, id`) to avoid skip/duplicate across pages — see [11_TEST_MATRIX.md](11_TEST_MATRIX.md) `TXN-010`. A missing tiebreak column is the most common cause of a subtle pagination correctness bug that also happens to look like a performance non-issue (it doesn't crash, it just silently returns wrong data).
- **Isolate-based parsing**: the deterministic SMS parser runs in a Dart isolate specifically so a pathological/slow regex on a malformed or adversarial SMS body cannot block the main UI thread — this is a resilience measure as much as a performance one.
- **Debounced/aggregated writes**: budget/engagement checks run once per capture-sync cycle, not once per individual message within a batch, to avoid N redundant aggregate queries when N messages import in one drain cycle.

## 4. Profiling method

```bash
flutter run --profile -d "Mali-iPhone"
```

Use Flutter DevTools' Performance view for frame-timing analysis, and the Network/Timeline views for backend round-trip latency. For Postgres-side query performance, use `EXPLAIN ANALYZE` via the Management API SQL endpoint (see [12_DATABASE_VALIDATION.md](12_DATABASE_VALIDATION.md) §1) against representative seeded data volumes, never against a near-empty table (which will always look fast regardless of whether the query is properly indexed).

## 5. Known non-goals for performance work right now

- No effort has been invested in supporting offline-first conflict-free replicated data types (CRDTs) — the current conflict model (see [11_TEST_MATRIX.md](11_TEST_MATRIX.md) `CONF-*`) relies on targeted single-column updates and server-side atomicity (RPCs) rather than a general-purpose merge algorithm. This is a scale/complexity tradeoff, not an oversight — revisit only if multi-device concurrent-edit conflicts become a measured real problem.
- No client-side query result caching layer beyond Riverpod's own provider caching exists yet; every provider re-fetch is a fresh query. This is acceptable at current usage volumes; revisit if profiling shows it as a bottleneck, not preemptively.

## 6. Regression prevention

Any change to a hot-path query (transaction list, dashboard totals, report aggregations) should be accompanied by a note in the PR description of the query plan before/after, especially if a `WHERE` clause, index usage, or pagination approach changed. See [18_REGRESSION.md](18_REGRESSION.md) for the standing regression suite this feeds into over time.
