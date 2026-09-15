# V1 Audit Reconciliation

Disposition of the inherited audit against **current HEAD (`5edfdb6e`)**.

Source: `~/.qirsh-qa/audit/merged.json` — 1,052 invariants merged from 18
subsystem audits, each adversarially verified against source.

**The audit is not a task list.** 1,052 invariants describe what must never be
wrong. Most are already satisfied by the code; the release question is only
*what proves it*, and *which ones are actually broken*.

---

## 1. The numbers that decide scope

| Severity | Count | VERIFIED | MOCKS | **UNVERIFIED** | BLOCKED |
|---|---|---|---|---|---|
| P0 | 134 | 38 | 41 | **45** | 10 |
| P1 | 338 | — | — | — | — |
| P2 | 434 | — | — | — | — |
| P3 | 146 | — | — | — | — |
| **All** | **1,052** | **284** | **134** | **614** | **20** |

Release-blocking by the register's own rule: **526**.

### The scoping decision

An **UNVERIFIED** invariant is an *evidence* gap, not automatically a *defect*.
Treating all 614 as release blockers would guarantee failure inside 24–48 hours
and is not what the charter asks for.

V1 blocking scope is therefore:

1. **Every P0 whose invariant is actually violated** — a real defect. Fix it.
2. **Every P0 that is UNVERIFIED *and* whose violation would be silent** —
   money corruption, cross-user exposure, data loss, privacy egress. These get
   real proof, because "no test" and "no failure report" are indistinguishable
   for exactly this class.
3. P0s already VERIFIED or credibly TESTED WITH MOCKS — accept, record evidence.
4. P0s BLOCKED BY EXTERNAL QA — record truthfully, do not fake.
5. P1 — fix real defects; evidence gaps only where a critical journey breaks.
6. P2 / P3 — out of V1 blocking scope unless App Store compliance needs them.

**45 P0 + UNVERIFIED is the primary work list.**

## 2. P0 concentration by subsystem

| Subsystem | P0 |
|---|---|
| auth-tenant | 32 |
| consent-privacy | 29 |
| security-baseline | 22 |
| database | 16 |
| capture | 14 |
| backup-restore | 11 |
| backend | 9 |
| money-model | 8 |

Authorization + privacy + security carry **83 of 134 P0s**. That, not the UI, is
where this release is won or lost.

## 3. Findings requiring disposition against current HEAD

Each is reconciled in V1_RISK_REGISTER.md with a current-HEAD verdict. The
audit's own verifiers already struck 14 reader claims as REFUTED and downgraded
160 severities; those corrections are carried, not re-litigated.

Classification vocabulary used: `VALID P0 BLOCKER` · `VALID P1 BLOCKER` ·
`VALID NON-BLOCKER` · `ALREADY FIXED` · `STALE` · `DUPLICATE` ·
`EVIDENCE GAP ONLY` · `INTENTIONALLY DEFERRED BY V1 CONTRACT`.

## 4. Already fixed during the preceding QA effort (uncommitted at HEAD)

| Finding | Fix | State |
|---|---|---|
| Transaction rows inert on `/card/:last4` and `/account/:id` — `TransactionRow` wraps in `InkWell` unconditionally, both call sites omitted `onTap` | `onTap` → `TransactionDetailsScreen.showSheet` | in working tree |
| Goal edit/delete unreachable on the full-screen `/goals/:id` route — both gated behind `if (sheetMode)` while the add-contribution FAB is not | render edit/delete in both modes | in working tree |
| Sweep harness scored working switches DEAD-TAP (durable write not counted as an effect) | `attributableWrite` signal | in working tree |
| Sweep harness charged background `synced_at` churn to innocent controls | `BACKGROUND-CHURN` class, bookkeeping-column rule, 6 guard tests | in working tree |
| Sweep harness halted a route on an unrestorable log table | `_unrestorableTables` — compared, never restored, never a halt | in working tree |

Three product defects, all latent: reachable only by direct navigation, which is
why ordinary use never surfaced them.

## 5. Audit-of-the-audit: what the verifiers corrected

Carried as calibration, because it governs how much of the register to trust:

- 622 of 865 reader claims CONFIRMED (72%); 229 WEAKENED; 14 REFUTED
- **146 invariants were added by verifiers** — 17% of the real findings came
  from the second pass, not the first
- 160 severity downgrades; 115 status downgrades
- 10 handbook citations were fabricated and were struck

Worst over-claiming: `migration-0077` (14 of 50 confirmed, 28 severity
downgrades) — the subsystem nobody can settle without a server is exactly the one
the reader inflated most. `parser` was most accurate (92/98) but still had 24
severity downgrades: its failures are wrong-value/missed-capture, which is P1,
not P0.
