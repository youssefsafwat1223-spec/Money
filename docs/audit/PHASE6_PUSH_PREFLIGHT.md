<!-- PROVENANCE: copied from `demo-docker/PHASE6_PUSH_PREFLIGHT.md`, which is an untracked local
     demo/working directory. Phase-6 push preflight evidence.
     Tracked here so the authoritative artifact survives loss of that
     directory. The original is left in place; this copy is the one of
     record. -->

# PHASE 2 / PHASE 6 — FINANCIAL PUSH PREFLIGHT INVENTORY

**Status: INVENTORY INCOMPLETE — two hard blockers. No push enabled. Nothing mutated.**

Date: 2026-08-26 · Environment: local Docker `qirsh-demo` only · Main/Audit untouched.

---

## 0. Executive result

The requested read-only inventory **cannot be completed** on the current device build. Two
independent blockers stand between here and the first controlled push test, and one of them changes
the shape of the test itself.

| # | Blocker | Status |
|---|---|---|
| **A** | Drift is SQLCipher-encrypted; the outbox cannot be enumerated | unresolved — probe needs a rebuild, disk **4.21 GiB** vs the `START_MIN_GIB = 8` floor |
| **B** | No push-direction exactness proof exists — only a pull proof | unresolved — would have to be authored |
| **C** | Enabling the push capability is **inherently a bulk flush**, not an isolated write | design fact, see §5 |

---

## 1. What is PROVEN (no Drift read required)

### 1.1 Server baseline — unchanged all session

```
user_transactions        57   last updated 2026-08-25 17:16:29  (seed)
user_budgets              3   2026-08-25 17:16:29  (seed)
user_goals                2   2026-08-25 17:16:29  (seed)
user_goal_contributions   5   2026-08-25 17:16:29  (seed)
user_subscriptions        4   2026-08-25 17:16:29  (seed)
user_bill_payments        7   (seed)
user_accounts             4   2026-08-26 12:27:45  ← only table that moved
```

**No money-bearing row has ever been written by the device.** Parking held throughout
(D-003 evidence: `shouldParkExactMoneyWrite(canonical, unknown) == true`).

### 1.2 The non-money push chain is ALIVE and drains continuously — PROVEN

`acc-rajhi` r32→33 and `acc-mada` r33→34 moved **together** at `2026-08-26 12:27:45`, the signature
of the atomic `set_default_account` RPC. This is F-020 firing during navigation.

Consequences, both useful:

1. **There is no backlog of account-default commands.** They enqueue, push, `markSuccess`, and clear.
   The `accountDefaultCommandType` queue is empty in steady state.
2. **The full chain UI → Drift → outbox → PUSH → Docker → ACK is already demonstrably working** for
   non-money commands. Transport, auth, service-role path and RPC are all live. Only the
   money-bearing half is parked.

### 1.3 Conflicts — 3, PROVEN by observation

| account | conflicted |
|---|---|
| `acc-cash` نقداً | **yes** |
| `acc-mada` مدى | **yes** |
| `acc-rajhi` الراجحي | **yes** |
| `acc-stcpay` STC Pay | no |

Per **F-021**, "conflict" here means only that the local row carried `sync_status = 'pending'` when a
pull page contained it. **No divergence was ever tested.** These are financial rows (accounts) and
they count toward `pendingUserDataCount`, so they would block a clean sign-out.

### 1.4 Local-only rows — 1 PROVEN

**«الحساب الرئيسي»** — `kDefaultAccountLocalId = 'default_account'`. Rendered in the Accounts list
(shot P03) and **absent from `user_accounts`** on the server (which holds only `acc-rajhi`,
`acc-mada`, `acc-cash`, `acc-stcpay`). Auto-seeded by `app_database.dart:2655` whenever the accounts
table is empty, and deliberately reseeded after every sign-out.

Classification: `unprovenFinancialRows` — an active financial row with no `server_id`.

---

## 2. What is UNKNOWN — requires the probe

Every item below needs a Drift read and cannot be inferred:

| item | why it matters |
|---|---|
| `ledger_sync_outbox` rows — count, operation, status | the money queue itself |
| `planning_sync_outbox` rows — entity_type, operation, status | accounts/budgets/goals/subscriptions/plans |
| which rows are `parked` vs `pending` vs `failed` | parked rows re-arm on capability flip (§5) |
| `unprovenFinancialRows` beyond `default_account` | rows with no `server_id` and no outbox entry |
| `localOnlyCards` | cloud-unrepresentable cards, lost on wipe |
| **any queued DELETE** | **deletes bypass parking entirely** — see §4 |
| local `server_revision` per row | the CAS base a push would send |

---

## 3. Requested buckets

### SAFE CANDIDATES FOR CONTROLLED PUSH TEST

**One candidate qualifies today, and it needs neither blocker resolved.**

**PUSH-01 — set default account** (on the user's own test list)

| | |
|---|---|
| operation | `set_default_account` RPC via `accountDefaultCommandType` outbox |
| money-bearing | **no** — the RPC rewrites no account fields |
| needs push capability | **no** — dispatched outside `_processItem`, never reaches the parking gate |
| currently happening | **yes**, already, on every account switch (F-020) |
| reversible | **yes** — switch back |
| exact Docker mutation if approved | demote current default, promote target, **both rows' `revision` +1**, `updated_at` set. E.g. `acc-mada` 34→35 (`is_default` t→f) and `acc-rajhi` 33→34 (f→t). **No other column on any row changes. No `user_transactions` row is touched.** |

This is the only isolated, reversible, observable financial-adjacent mutation available without
unblocking A and B.

### DO NOT PUSH / NEED REVIEW

Everything money-bearing: create account, edit account, create transaction, edit transaction,
edit category. All require:

1. the inventory (Blocker A) — otherwise the flush contents are unknown, and
2. a push-direction exactness proof (Blocker B) — otherwise capability is *asserted*, not proven,
   which is exactly what §14 forbids.

### CONFLICTED

`acc-cash`, `acc-mada`, `acc-rajhi` — see §1.3. **Do not resolve.** Both resolution buttons write,
and «نسخة الجهاز الآخر» would discard a local change that was merely never uploaded (F-021).

### LOCAL-ONLY

`default_account` («الحساب الرئيسي») — see §1.4. If push were enabled, the accounts backfill would
attempt to create it on the server as a **fifth account**. The stable sentinel id exists precisely to
keep that idempotent, but it has never been exercised against this backend.

### DELETE / SPECIAL COMMANDS

- **Account-default commands:** draining continuously, no backlog (§1.2).
- **DELETEs:** count **unknown**. This is the single most important unknown, because —

---

## 4. DELETE bypasses exact-money parking — PROVEN

`ledger_push_service.dart:173` and `accounts_push_service.dart:350`:

```dart
if (item.operation != OutboxOperation.delete &&
    shouldParkExactMoneyWrite(cutoverState: …, pushCapability: …)) {
  await _queue.park(item.id, exactMoneyTransportUnverifiedReason);
```

The rationale is stated in the code — deletes carry no money. But a queued financial DELETE would be
**transmitted on the next push cycle regardless of the parked capability**, and would remove a row
from `user_transactions` on Docker.

Circumstantial evidence that the count is zero: every write test has been deferred, no delete was
performed during QA, and the server still reads 57 transactions. **This is not proof.**

---

## 5. Enabling the capability is a BULK FLUSH by construction

`ledger_push_service.dart:107` (and `accounts_push_service.dart:268`):

```dart
if (_pushCapability() == ExactTransportCapability.verifiedExact) {
  await _queue.reArmParked();
}
final items = await _queue.pendingItems();
```

The moment `exactPushTransportCapabilityProvider` returns `verifiedExact`, **every parked row is
re-armed and the whole queue drains on that same cycle.**

**There is no such thing as "one isolated money push" via the capability flag.** Isolation requires
knowing the queue is empty first — which is Blocker A. The two blockers are therefore ordered:
**A must be resolved before B is even useful.**

---

## 6. Blocker B in detail — the proof is pull-only

`tools/verify_local_exact_transport.py` header:

```
Reads a PostgREST JSON array on stdin.
--mode adversarial : assert the five adversarial probe rows round-trip EXACTLY.
--mode shape       : assert every `*_text` money projection on real rows is a JSON string
```

Both modes verify **reads**. There is no write-direction test: no decimal-string → `NUMERIC`
round-trip, no post-write `::text` re-read comparison.

`demo_local_capability.dart:105` states the posture explicitly:

```dart
// NOTE: exactPushTransportCapabilityProvider is intentionally absent.
```

and `exact_transport_capability.dart:1`:

```dart
// Push and pull are intentionally tracked independently: proving one
// direction says nothing about the other.
```

Enabling push today would assert a capability nothing has demonstrated.

---

## 7. Path to unblock (not executed)

1. **Free disk to ≥ 8 GiB** (currently 4.21). Only regenerable caches.
2. **Build the read-only DEMO_LOCAL inventory probe** — calls the existing
   `UnsyncedInventoryService.collect()` plus detail `SELECT`s, writes JSON to `Documents/`, retrieved
   with the already-proven `xcrun devicectl device copy from`. Zero writes.
3. **Read the inventory.** Confirm the money queue is empty (or enumerate it) and confirm **zero**
   queued DELETEs.
4. **Author a push-direction exactness proof** — write adversarial decimal strings through PostgREST,
   re-read via `::text`, assert byte-identity. Gate `DEMO_EXACT_PUSH_VERIFIED` on it, mirroring the
   pull gate.
5. **Then** enable the capability, knowing exactly what will drain.

**PUSH-01 (set default account) requires none of the above** and can proceed on approval alone.

---

## 8. Compliance

No push enabled · no Drift mutation · no Docker mutation · no conflict resolved · no sign-out ·
no flush · `exactPushTransportCapabilityProvider` untouched · Main/Audit untouched ·
no remote project contacted.

---

# PUSH-01 — NON-MONEY PUSH PATH — **VERIFIED** ✅

Executed 2026-08-26 13:33:11 UTC. Single UI action: account picker → «الراجحي — الحساب الجاري».

## Result — exactly as predicted, nothing more

```diff
- acc-mada  |…|-1240.50|0.00|…|f|1|t|34|created 17:16:29|updated 2026-08-26 12:27:45|{}
+ acc-mada  |…|-1240.50|0.00|…|f|1|f|35|created 17:16:29|updated 2026-08-26 13:33:11|{}

- acc-rajhi |…|18450.75|15000.00|…|f|0|f|33|created 17:16:29|updated 2026-08-26 12:27:45|{}
+ acc-rajhi |…|18450.75|15000.00|…|f|0|t|34|created 17:16:29|updated 2026-08-26 13:33:11|{}
```

| assertion | result |
|---|---|
| `is_default` flipped on exactly two rows | ✅ mada t→f, rajhi f→t |
| `revision` incremented on exactly those two | ✅ 34→35, 33→34 |
| `updated_at` set | ✅ **identical timestamp on both** → one atomic transaction |
| `acc-cash`, `acc-stcpay` untouched | ✅ **absent from the diff entirely** (revisions still 13 and 11) |
| every other column unchanged | ✅ name · type · currency · `current_balance` (−1240.50 / 18450.75) · `initial_balance` · `credit_limit` · `available_credit` · `bank_account_number` · `wallet_provider` · `exclude_from_totals` · `sort_order` · `created_at` · `deleted_at` · `metadata` |
| money-bearing tables | ✅ **byte-identical diff — zero writes** |

Money fingerprint before and after, unchanged:

```
user_transactions        57 rows  Σ 58,431.65  max_rev 2  max_updated 2026-08-25 22:23:59
user_budgets              3 rows  Σ  4,600.00
user_goals                2 rows  Σ 22,800.00
user_goal_contributions   5 rows  Σ 22,800.00
user_subscriptions        4 rows  Σ  1,163.25
user_bill_payments        7 rows  Σ  2,746.25
```

## What this proves

The complete push chain is live and correct for the non-money path:

**UI action → Drift → `planning_sync_outbox` (`accountDefaultCommandType`) → PUSH →
`set_default_account` RPC on local Docker → ACK → `markSuccess` → outbox cleared.**

Transport, authentication, the service-role path, RPC atomicity and outbox lifecycle are all
demonstrably working. **Only the money-bearing half remains parked** — and it stayed parked
throughout, exactly as designed.

The RPC's atomicity is proven by the shared `updated_at`: demote and promote committed in one
transaction, and the two uninvolved accounts were never rewritten. This is the MALI-055n design
working as documented ("the server RPC demotes the old default + promotes the target atomically, so
a stale device can never roll back unrelated fields").

## Compliance

`exactPushTransportCapabilityProvider` **not touched** · no outbox unparked · no transaction,
budget, goal, subscription or plan written · Main/Audit untouched · local Docker only.

**STATUS: NON-MONEY PUSH PATH — VERIFIED.** Financial mutation testing stops here pending the
inventory probe and a push-direction exactness proof.

---

# BLOCKER B — RESOLVED: PUSH EXACT TRANSPORT — **VERIFIED** ✅

`tools/verify_local_exact_push.sh` (new). Run 2026-08-26 against local Docker only.

## Method — the app's real write path, not a simulation

The canonical push encodes money as a **JSON string**, never a number
(`money_transport.dart`):

```dart
Object amountWire(Money m) =>
    canonical ? moneyToNumericText(m) : moneyToLegacyJsonNumber(m);
String moneyToNumericText(Money m) => m.toDecimalString();
```

The proof uses exactly that shape, over the same authenticated PostgREST path the app uses
(signed in as `demo.user@qirsh.test` with the anon key + user JWT — **not** service-role), upserted
into `public.user_transactions`, keyed on `client_request_id` — the app's own identity column
(`ledger_push_service.dart`: `onConflict: 'user_id,client_request_id'`).

Read back through the **identical projection the pull uses**
(`ledger_sync_service.dart:36`):

```
*,amount_text:amount::text,balance_after_text:balance_after::text,foreign_amount_text:foreign_amount::text
```

## Result — 40/40 assertions byte-for-byte EXACT

| probe | case | sent → read back |
|---|---|---|
| 01 | **> 2^53 minor units**, scale 2 | `99999999999999.99` · bal `88888888888888.88` ✅ |
| 02 | **scale 0** currency (JPY) | `12345` · bal `67890` ✅ |
| 03 | scale 2 baseline (SAR) | `1234.56` · bal `9876.54` ✅ |
| 04 | **scale 3** currency (KWD) | `1234.567` · bal `7654.321` ✅ |
| 05 | **negative** `balance_after` | `-98765.43` ✅ *(`amount` has `CHECK (amount > 0)`, so the domain expresses sign via `direction`/`transaction_type`; the negative case belongs on `balance_after`, which is unconstrained — and مدى's real balance is −1240.50)* |
| 06 | **foreign amount + currency** | `349.00` / `AED` alongside `356.25` SAR ✅ |
| 07 | **null semantics** | `balance_after`, `foreign_amount`, `foreign_currency` all null → all read back null ✅ |
| 08 | **2^53 + 1 minor units at scale 3** (BHD) | `9007199254740.993` ✅ |

Probe 08 is the decisive one: 9,007,199,254,740,993 minor units is exactly one above
2^53 = 9,007,199,254,740,992 — the first integer an IEEE-754 double cannot represent. It survived
the round trip unchanged, which no float path could do.

Server columns are unconstrained `numeric` (no precision/scale), so nothing truncates.

## Cleanup — proven

| assertion | before | after |
|---|---|---|
| probe rows | 0 | **0** |
| row count | 57 | **57** |
| `sum(amount)` | 58431.65 | **58431.65** |
| `sum(balance_after)` | 55352.25 | **55352.25** |
| `max(updated_at)` | 2026-08-25 22:23:59.157217+00 | **unchanged** |

`max(updated_at)` holding still is the strongest cleanup assertion available: **not one original
financial row was modified.** Probe rows were deleted by their exact `client_request_id` prefix.

## Scope of the claim

This proves the **transport contract**: a canonical decimal string written through PostgREST lands
in `NUMERIC` and reads back through `::text` byte-identically, for every adversarial shape tested.

It does **not** enable anything. `exactPushTransportCapabilityProvider` is untouched and still
returns `unknown`. Blocker A (the outbox inventory) remains, and §5 still holds — flipping the
capability re-arms every parked row at once.

---

# BLOCKER A — RESOLVED: FULL LOCAL INVENTORY EXPORTED ✅

Probe built into the profile binary, installed 2026-08-26, app launched from the icon,
`Documents/demo_inventory.json` (8,672 bytes) retrieved read-only via
`xcrun devicectl device copy from`.

## Runtime state — confirms the D-003 source analysis exactly

```
PRAGMA user_version        = 31      (>= 30)
planning_cutover_state     = 1       (marker set)
```

→ `PlanningCutoverState.canonical`, empirically. `shouldParkExactMoneyWrite(canonical, unknown)`
is therefore **true**, which is why every money-bearing item below is parked. The source-derived
conclusion in D-003 is now confirmed by measurement.

## THE MONEY LEDGER IS CLEAN

| check | result |
|---|---|
| `ledger_sync_outbox` | **empty — 0 rows** |
| transactions with no `server_id` | **0** |
| transactions in `conflict` | **0** |
| transactions `synced` | **57 / 57** |

## 🎯 PENDING DELETE COUNT: **ZERO** — the critical unknown, now proven

```json
"queued_deletes": { "ledger": [], "planning": [] }
```

Both queues contain **no `operation = 'delete'` item of any kind**. The DELETE bypass of
`shouldParkExactMoneyWrite` (§4) is real in code but has **nothing to fire**. This was the single
most dangerous unknown in the preflight and it is now closed with direct evidence rather than
circumstantial reasoning.

## THE RE-ARM SET — exactly 11 items

Every one carries `failure_class = exact_money_transport_unverified`, `attempt_count = 0`,
`last_error = null`. Nothing has ever been transmitted.

| entity_type | operation | status | entity_id | count |
|---|---|---|---|---|
| account | update | parked | `acc-mada` | **4** |
| account | update | parked | `acc-rajhi` | **3** |
| account | update | parked | `acc-cash` | **1** |
| budget | update | parked | `bud-groceries` | 1 |
| budget | update | parked | `bud-restaurants` | 1 |
| budget | update | parked | `bud-transport` | 1 |
| | | | **TOTAL** | **11** |

**These 11, and only these 11, would be re-armed and drained the instant
`exactPushTransportCapabilityProvider` returns `verifiedExact`.**

Note the duplication: 8 items cover only **3 distinct accounts**. The queue accumulates repeat
updates for the same entity without coalescing.

## CONFLICT CAUSATION — now PROVEN, and F-020 is exonerated

The correlation is exact and the mechanism is visible:

| account | parked outbox items | local `sync_status` | local `server_revision` | server `revision` |
|---|---|---|---|---|
| `acc-mada` | 4 | **conflict** | 23 | 35 |
| `acc-rajhi` | 3 | **conflict** | 19 | 34 |
| `acc-cash` | 1 | **conflict** | 11 | 13 |
| **`acc-stcpay`** | **0** | **synced** | **11** | **11** |

The chain, end to end:

1. A reconcile/backfill enqueued account updates → `planning_outbox_queue.dart:433` set the row
   `sync_status = 'pending'`.
2. Push ran → parked (money-bearing, capability unverified) → **never sent**.
3. The row stays `pending` **forever**.
4. Every subsequent pull hits `if (syncStatus == 'pending') { _markConflict(...) }`
   (`accounts_pull_service.dart:252`) → **conflict**, with no divergence test (**F-021**).

`acc-stcpay` has no queued item, was never `pending`, and is the only account still `synced` —
with a local `server_revision` (11) that **exactly matches the server**. The three conflicted rows
are all **behind** the server.

**Earlier hypothesis withdrawn:** the "was ever selected during QA" correlation was a confound. The
real predictor is "has a parked outbox item". **F-020 did not cause the conflicts**, as reported.

### F-021 — new consequence discovered: false conflicts FREEZE the row

`accounts_pull_service.dart:251` returns early on an already-conflicted row:

```dart
if (syncStatus == 'conflict') return _AccountPullOutcome.conflict;
```

So a row falsely flagged conflict **stops receiving pulls entirely**. That is why the three local
`server_revision` values (23 / 19 / 11) have drifted behind the server (35 / 34 / 13): they have
been frozen out of sync since the moment they were flagged.

**Severity of F-021 rises accordingly** — it does not merely show a misleading dialog; it
permanently desynchronises rows that had nothing wrong with them.

## Everything else — clean

| table | state |
|---|---|
| budgets | **3 pending** (the 3 parked items) — **0 conflict** |
| goals · subscriptions · plans · goal_contributions · bill_payments | all `synced` (2 · 4 · 2 · 5 · 7) |
| cards | 2, both `synced`, both with `server_id` — **no local-only cards** |
| smart inbox pending | **0** |
| unproven financial rows | **accounts = 1** (`default_account`), everything else **0** |

**Asymmetry worth noting:** budgets are `pending` but **not** conflicted, while accounts with the
same parked state **are**. The `pending → conflict` rule is implemented in the accounts pull only.
Accounts are treated more harshly than budgets for identical underlying state.

## LOCAL-ONLY — 1 row, exactly as predicted

```
الحساب الرئيسي   id=default_account   server_id=null   sync_status=null   is_default=0
```

No `server_id`, no `sync_status`, not in any outbox. It is the auto-seeded sentinel
(`kDefaultAccountLocalId`). It is **not** in the re-arm set — no queued item references it — so
enabling the capability would **not** push it. It would only be created server-side if a
backfill/reconcile subsequently enqueued it.

---

# RECONCILIATION CYCLE — RESULT (2026-08-26 14:2x)

## Server financial data — UNCHANGED ✅

| table | before | after |
|---|---|---|
| `user_transactions` | 57 · Σ 58,431.65 · max_updated 2026-08-25 22:23:59 | **identical** |
| `user_budgets` | 3 · Σ 4,600.00 | **identical** |

**No money-bearing row was written to the server during reconciliation.** Parking held.

`user_accounts` did move (cash 13→15, stcpay 11→15, mada 35→37, rajhi 34→36, default → rajhi) —
`set_default_account` traffic (F-020), not money.

## New local data — user-created, confirmed

The tester deliberately created, at 14:22:

| what | detail |
|---|---|
| account «حساب EGP» | `planning_sync_outbox` · `account create` · **parked** · entity `iBWc2pkGU02-YsHJOekNtg` |
| transaction | `ledger_sync_outbox` · `create` · **parked** · `b-4GVOpq4VkGuTk9LEKXDA` · **8600 minor = 86.00 EGP** · 2026-08-26T14:22:35Z |

Both parked with `exact_money_transport_unverified`. **The ledger outbox is no longer empty** — it
held 0 items in the first inventory.

## Re-arm set grew 11 → 15

| entity | operation | status | n |
|---|---|---|---|
| **ledger (transaction)** | **create** | parked | **1** |
| account | create | parked | 1 |
| account | update | parked | 10 |
| budget | update | parked | 3 |

**Queued DELETEs: still 0 in both queues.** ✅

## F-021 fix — behaved correctly, conflicts did NOT clear

| account | before | after |
|---|---|---|
| `acc-stcpay` | synced · srev **11** | **synced · srev 15** ✅ pulled and refreshed |
| `acc-rajhi` | conflict · srev 19 | conflict · srev 19 |
| `acc-mada` | conflict · srev 23 | conflict · srev 23 |
| `acc-cash` | conflict · srev 11 | conflict · srev 11 |

STC Pay advancing 11→15 proves the pull ran and the normal (non-pending) path is unaffected.

The three did **not** clear because the divergence check found **real** divergence: `is_default`
genuinely changed on the server during the same window (rajhi f→t, mada t→f via
`set_default_account`), so `_serverDivergedFromLocal` correctly returned true. **This is the fix
working, not failing** — it declined to silently discard a real difference.

They can only clear once local and server agree on `is_default`, i.e. after the account-default
traffic settles. **Not resolved by fiat; no conflict was touched.**

## Stale-base question — answered

The 10 parked `account update` items are built against local rows whose `server_revision`
(19 / 23 / 11) is now far behind the server (36 / 37 / 15). They are **stale** and should be
**superseded or coalesced**, not sent: 10 items cover 3 distinct accounts, and each carries balance
fields that would overwrite newer server state.

The 3 parked `budget update` items remain valid — `user_budgets` has not changed on the server since
the seed, so their base is still current.

**The two newest items (account create + transaction create) are the only ones with no stale base**,
because a `create` has no server counterpart to be stale against.

---

# PUSH-02 — FIRST MONEY-BEARING PUSH — **VERIFIED END-TO-END** ✅

2026-08-26 18:29:26 UTC. One approved outbox item, sent in isolation.

## Chain proven

**Local Drift transaction → isolated outbox item → PUSH → local Docker → ACK → local sync state →
relaunch/pull → UI**

## Candidate

```
outbox item        zf0FyDz1cXgwLrw6mJeO7w   (ledger_sync_outbox, create, was parked)
local transaction  b-4GVOpq4VkGuTk9LEKXDA
amount             8600 minor = 86.00 EGP
```

## Server assertions — all pass

| assertion | result |
|---|---|
| `user_transactions` 57 → 58 | ✅ **58** |
| exactly one row with `client_request_id = b-4GVOpq4VkGuTk9LEKXDA` | ✅ **1** |
| `amount` exactly `86.00` (read via `::text`) | ✅ |
| `currency = EGP` | ✅ |
| `sum(amount)` 58,431.65 → 58,517.65 | ✅ **+86.00 exactly** |
| **no original transaction modified** | ✅ `max(updated_at)` over all rows *except* the new one is still `2026-08-25 22:23:59.157217+00` |
| no account / budget / goal / subscription row changed | ✅ 4 accounts · Σbal 18,287.50 · budgets 4,600.00 · goals 22,800.00 · subs 1,163.25 — all identical |

Created row:

```
id                 40044342-a885-4a72-9059-4cf34a678b9c
client_request_id  b-4GVOpq4VkGuTk9LEKXDA
amount 86.00  currency EGP  type expense  status confirmed
local_account_id   iBWc2pkGU02-YsHJOekNtg
server_account_id  NULL          (EGP account still unpushed — as predicted)
revision           1
```

## Idempotency — verified by a real relaunch

The app was force-closed and reopened, re-running the full sync cycle:

| after relaunch | result |
|---|---|
| total transactions | **58** (not 59) |
| rows with our `client_request_id` | **1** |
| EGP rows | **1** |
| our row's `revision` | **still 1** — not even re-written |
| `updated_at` | unchanged at 18:29:26 |

**No duplicate, and no redundant re-upsert.**

## Local state after ACK

| check | result |
|---|---|
| `ledger_sync_outbox` | **empty** — the item was ACKed and removed |
| transactions `sync_status` | **58 synced, 0 pending** |
| transactions without `server_id` | **0** — the pushed row received its server identity |
| queued DELETEs | **0** in both queues |

## Isolation — held, and re-proved itself

| queue | before | after |
|---|---|---|
| ledger (approved item) | 1 parked | **0 — ACKed and gone** |
| planning: account create | 1 parked | 1 **parked** |
| planning: account update | 10 parked | **11 parked** |
| planning: budget update | 3 parked | 3 **parked** |
| planning: account_default_command | — | 1 pending *(non-money, bypasses parking by design)* |

`reArmParked()` never ran. `exactPushTransportCapabilityProvider` was never overridden and still
returns `unknown`.

**Stronger evidence than "nothing changed":** the account-update count went **10 → 11**. A *new*
money-bearing item was enqueued during the relaunch (F-020 / reconcile traffic) and was
**immediately parked** — proving the global parking gate is still fully armed for every item except
the one named in `DEMO_PUSH_ALLOW`.

## UI

The tester confirmed «حساب EGP» and the 86.00 EGP transaction render correctly on the iPhone.

## New demo baseline

**`user_transactions` = 58 · Σ = 58,517.65.** All prior comparisons in this document referencing 57
/ 58,431.65 describe the pre-PUSH-02 baseline.

**No rollback performed** — the row is cleanly synchronised on both sides, per instruction.

**STATUS: FIRST MONEY-BEARING PUSH — VERIFIED END-TO-END.** Stopping before any update / delete /
budget / account push.

---

# PUSH-03 — FIRST ISOLATED FINANCIAL UPDATE — VERIFIED END-TO-END

2026-08-27 · item `NJyCkDXa9ajvn3HLnETNeA` · `bud-groceries` · planning queue · isolation
`DEMO_PUSH_ALLOW` extended to the planning queue (`PlanningOutboxQueue.demoReArmOne` +
`demoPushAllowsItem` in `planning_push_service.dart`; global capability stayed `unknown`).

## Chain proven
`Drift intent → isolated re-arm → parking-gate exemption (this id only) → PUSH → Docker →
ACK → pull adopts new proof → UI`

## Server assertions (pre-snapshot MD5 95ae4f75cf4b6c466f447fc546b18199)
- exactly one `user_budgets` row changed; **revision 1 → 2**; `updated_at 00:17:35.147577Z`
- `amount = 2500.00` byte-exact; currency/period/active/header unchanged
- intended change delivered: `start_date → 2026-07-31 21:00+00` (Riyadh midnight) +
  `last_notified_*` bookkeeping
- `bud-restaurants` / `bud-transport`: **byte-identical** pre/post (full 20-column diff)
- transactions 58 / 58,517.65 · goals · subs · plans · contribs · bill_payments: unchanged
- deviation recorded: `category_id` key overwritten by local id → **F-029** (MEDIUM)

## ACK / idempotency (post-relaunch inventory)
- the approved item is GONE from the outbox; relaunch re-arm matched 0 rows; revision stayed 2
- `bud-groceries` local: `synced`, base adopted `2026-08-27T00:17:35.147577+00:00` — no conflict
- untouched as promised: budget items ×2, EGP account create, 3 parked EGP ledger transactions

## UI
Budgets screen (Mada active): بقالة **2,500** · «ميزانية شهري · أغسطس 2026» · spend math intact
(1,644 / 856 / 66%) — screenshot 03:22.

## Concurrent (non-PUSH-03) state changes — operator navigation, F-020 live
`set_default_account` flips at 00:19:44Z / 00:22:21Z (STC Pay, then Mada default) · revisions
36,37,15,15 → 41,40,15,17 · content byte-identical · new parked mada snapshot `Q-0f7uHGIn…` ·
acc-mada transiently `conflict` again · the EGP-default intent was superseded by the operator's
own choice (command delivered to Mada and left the queue). See F-020 LIVE RECURRENCE.

---

# PUSH-04 — ISOLATED FINANCIAL ACCOUNT CREATE — VERIFIED END-TO-END

2026-08-27 · item `Yw16poTdxx1W37d7mmGx8g` · «حساب EGP» create · accounts queue.
Coverage gap found & fixed on attempt 1: the demo exemption existed in the ledger and
planning push services but NOT in `accounts_push_service.dart` — the third push service.
Fail-closed held: the un-exempted attempt delivered nothing and mutated nothing. The same
one-line `!demoPushAllowsItem(item.id)` bypass was added there; all three push services
are now covered.

## Chain proven
`Local Drift account → isolated re-arm → PUSH → Docker INSERT → ACK → server_id
attachment → pull adopts proof → single row everywhere`

## Server assertions (pre MD5 a814bfcc… / bb841cc7…)
- `user_accounts` **4 → 5**; exactly one new row; no duplicate on relaunch (count 5, rev 1)
- identity correct: `local_id iBWc2pkGU02-YsHJOekNtg` · «حساب EGP» · **EGP** · bank ·
  local `created_at` preserved
- **all money fields NULL** exactly as intended · `is_default = f` (no default mutation;
  Mada stayed `t` — the local intent had already moved to Mada by the operator's choice)
- the 4 existing account rows: **byte-identical** pre/post (full 21-column diff)
- tx 58/58,517.65 · budgets rev 2,1,1 · goals · subs · plans · contribs · billpays: unchanged

## ACK / idempotency (post-relaunch inventory)
- outbox item GONE; `server_id cd87d97a-f2c3-42a5-98a4-04d1239a35ad` attached locally;
  `sync_status synced`; base `2026-08-27T00:42:35.809682+00:00` adopted without conflict
- untouched as promised: budget items ×2, mada snapshot `Q-0f7uHGIn…`, **all three parked
  EGP ledger transactions** (not auto-pushed)
- pre-existing transient mada conflict (F-020 navigation churn) unchanged — not related

## Unlocked
The three EGP transactions' `missingDependency` is resolved: their account now has a
server_id. They remain parked pending per-item operator approval.

---

# PUSH-05 — ISOLATED FINANCIAL TRANSACTION CREATE — VERIFIED END-TO-END

2026-08-27 · item `Jwcm08CfGENwtnv5nuV2tg` · tx `9Ua2M5sVuVE6IA-f-96kdw` · **86.00 EGP** ·
ledger queue (same proven PUSH-02 path) · isolation `DEMO_PUSH_ALLOW`, global capability `unknown`.

## Chain proven
`Drift tx → isolated re-arm → PUSH → Docker INSERT → ACK → proof attachment → pull → UI-backing row`

## Server assertions (pre: 58 / 58,517.65 / row absent)
- `user_transactions` **58 → 59** · sum **58,517.65 → 58,603.65** (+86.00 exact)
- exactly one row `client_request_id 9Ua2M5sVuVE6IA-f-96kdw` · `amount::text '86.00'` byte-exact ·
  EGP · `server_account_id cd87d97a-…` (the PUSH-04 account — first linked transaction) ·
  `occurred_at` preserved
- unrelated tables unchanged: accounts rev 41,40,15,17,1 · budgets 2,1,1 · goals · subs ·
  contribs · billpays

## ACK / idempotency (post-relaunch)
- outbox item GONE (ledger queue now exactly the two remaining) · local tx `synced`
  (rollup 59 synced / 2 pending) · relaunch re-arm matched 0 rows · server stayed 59 / 58,603.65 /
  single row — **no duplicate**
- tx #2 (15.00) and #3 (142.86) remained parked throughout

## New demo baseline
**59 transactions · 58,603.65**

---

# PUSH-06 — SECOND ISOLATED FINANCIAL TRANSACTION CREATE — VERIFIED

2026-08-27 · item `6WC-lM7wj0QQws7ec6zucA` · tx `aXisUG4D7QxED3bnPo54Cg` · **15.00 EGP**.
Pre: 59 / 58,603.65 / row absent. Post: **60 / 58,618.65** · one row · `amount::text '15.00'`
byte-exact · EGP · linked to `cd87d97a-…` · accounts rev 41,40,15,17,1 and budgets 2,1,1
unchanged. Post-relaunch: outbox item GONE (queue = the single 142.86 item) · local tx
`synced` (rollup 60/1) · server stayed 60 / 58,618.65 / single row — no duplicate.
The 142.86 transaction remained parked throughout. **Baseline: 60 · 58,618.65.**

---

# PUSH-07 — FINAL ISOLATED LEDGER CREATE — VERIFIED

2026-08-27 · item `6Fe4-m47c2qUkvYl8ig4qw` · tx `8wG403K8M2p9ryczJnM0bw` · **142.86 EGP**.
Pre: 60 / 58,618.65 / row absent. Post: **61 / 58,761.51** · one row · `'142.86'` byte-exact ·
EGP · linked `cd87d97a-…` · accounts 41,40,15,17,1 and budgets 2,1,1 unchanged. Post-relaunch:
**ledger outbox EMPTY** — first time in Phase 6 · all 61 transactions `synced` · server stayed
61 / 58,761.51 / single row — no duplicate. Planning items untouched (2 budgets + mada snapshot).
**Baseline: 61 · 58,761.51.**

---

# PUSH-08 — SECOND ISOLATED BUDGET UPDATE — VERIFIED

2026-08-27 · item `ZzfpLlR3ukE3nhJRzlj_eg` · `bud-restaurants` · same invariants as PUSH-03.
Server: rev **1 → 2** · `amount 1200.00` byte-exact · start_date → Riyadh midnight +
notification fields only · `bud-transport` untouched at rev 1 · tx 61/58,761.51, accounts
41,40,15,17,1, goals, subs unchanged. Post-relaunch: item GONE · local `synced`, base
`2026-08-27T01:19:10.368434+00:00` adopted without conflict · revisions stayed 2,2,1 — no
duplicate. Mada snapshot untouched; no canonicalisation attempted (per operator decision the
NULL↔0.00 recurrence is a product finding for F-020/F-021 remediation).

---

# PUSH-09 — FINAL ISOLATED BUDGET UPDATE — VERIFIED

2026-08-27 · item `k75o_17CyV7_wqJgGVuZMA` · `bud-transport`. Server: rev **1 → 2** ·
`900.00` byte-exact · `show_on_header f` preserved · start_date/notifications only ·
groceries/restaurants unchanged at rev 2 · tx 61/58,761.51, accounts, goals, subs unchanged.
Post-relaunch: item GONE · local `synced` without conflict · revisions stayed 2,2,2 — no
duplicate. Mada snapshot untouched.

# PHASE 6 — FINAL INVENTORY (2026-08-27, post PUSH-09)

- **Ledger outbox: 0** · **Planning outbox: 1** (the stale Mada snapshot `Q-0f7uHGIn…`,
  base rev 37 vs server 40, zero user intent, `is_default:false` contradicting current intent)
- Conflicts: 1 — acc-mada, sustained by the NULL↔0.00 write-path normalisation (product
  finding, remediate with F-020/F-021; not demo state to repair)
- Pending/local-only: `default_account` legacy local-only row (known); everything else synced
- Queued DELETEs: 0 (both queues)
- **Server baselines: 61 transactions · 58,761.51 · 5 accounts (rev 41,40,15,17,1) ·
  3 budgets (rev 2,2,2) · goals/subs/plans/contribs/billpays unchanged since seed**
- Recommendation: close Phase 6 by DELETING the stale Mada snapshot (planner-proven dead;
  pushing it can only conflict or, worse, clear the server default). No further pushes needed —
  every genuine user intent has been delivered. The mada conflict flag clears via F-020/F-021
  remediation in Phase 4, not by pushing stale data.

**Delivered in Phase 6: PUSH-01…09 — 9/9 isolated, verified, zero rollbacks, zero duplicates,
zero unintended server writes from any push.**

---

# PHASE 6 — FINANCIAL PUSH QA COMPLETE (2026-08-27)

Close-out: the dead Mada snapshot `Q-0f7uHGInlBgSakLqGPkA` was deleted by the strict
one-shot (preconditions target_ok/planning_total=1/ledger_total=0 all held; deleted=1;
postconditions planning=0, ledger=0, conflict untouched, `default_account` intact).

## Final proven state
- **Ledger outbox 0 · Planning outbox 0 · queued DELETEs 0**
- 61/61 transactions synced · 3/3 budgets synced · 4/5 accounts synced
- Known residuals ONLY: acc-mada conflict (recurring NULL↔0.00 write-path normalisation —
  product issue, remediate with F-020/F-021 in Phase 4) · legacy local-only `default_account`
- Server baseline: **61 tx · 58,761.51 · 5 accounts rev 41,40,15,17,1 · budgets rev 2,2,2 ·
  goals 62,000.00 · subs 1,163.25 · contribs 22,800.00 · billpays 2,746.25**

## PUSH-01 → PUSH-09 summary
| # | what | proof |
|---|---|---|
| 01 | set-default RPC (non-money path) | verified, reversible |
| 02 | first money-bearing tx create (ledger) | 58 baseline established |
| 03 | first isolated budget UPDATE (bud-groceries) | rev 1→2, 2500.00 exact |
| 04 | isolated account CREATE («حساب EGP») | 4→5 accounts, money NULL preserved |
| 05 | tx create 86.00 EGP | 58→59, first row linked to the new account |
| 06 | tx create 15.00 EGP | 59→60 |
| 07 | tx create 142.86 EGP | 60→61, ledger queue emptied |
| 08 | budget UPDATE (bud-restaurants) | rev 1→2, 1200.00 exact |
| 09 | budget UPDATE (bud-transport) | rev 1→2, 900.00 exact, header flag preserved |

9/9 isolated via `DEMO_PUSH_ALLOW` · global capability never left `unknown` ·
zero rollbacks · zero duplicates across every restart · zero unintended writes from any push ·
every money field byte-exact end-to-end. Findings raised along the way: F-029 (category_id
local-id overwrite), F-020 live recurrence, NULL↔0.00 write-path normalisation.

---

# PHASE 3 · TEST 1 — ADMIN → APP ANNOUNCEMENT PROPAGATION — VERIFIED END-TO-END

2026-08-27 · admin `demo.admin@qirsh.test` · via the admin UI's own write path
(`POST/PATCH /api/announcements`, `requireAdmin()` + service client) — no SQL.

- Forward: table 0→1 · row exactly as submitted (`8007661b…`, info, dismissible, active) ·
  edge fn served it · cold launch → **banner visible on Home** (operator screenshot 05:04),
  dismissible (×) rendered.
- Reverse: `is_active=false` via the same route · row retained (deactivated, reversible) ·
  edge fn → `[]` · cold launch → **banner gone** (operator-confirmed).
- Financial tables byte-identical throughout (61/58,761.51 · accounts 41,40,15,17,1 ·
  budgets 2,2,2). Defence-in-depth observed: RLS rejects direct client inserts; middleware
  rejects invalid sessions.
- Side finding: **UX-032** — banner crowds the pending-review card (no-widget-into-widget rule).

---

# PHASE 3 · TEST 2 — ADMIN → APP COUPON CATALOG + FEATURE FLAG PROPAGATION — VERIFIED END-TO-END

2026-08-27 · all mutations through the admin UI's own routes with the demo.admin session.

- Pre: categories 0 · coupons 0 · `enable_coupons` false/0/f (original state).
- Flag ON (edit-form payload: value=true, rollout=100, active) → **only** that row changed
  (full-table diff vs MD5'd snapshot) → served by `catalog-flags`. No visible effect —
  correct: the coupons surface additionally requires a non-empty catalog (fail-closed).
- Catalog: created «فئة تجريبية للعرض» + «كوبون تجريبي — خصم توضيحي» (code DEMO2026, global,
  featured) via `/api/coupon-categories` + `/api/coupons`; server validation rejected the
  first attempt (missing is_global/valid_from) exactly as the form would.
- Visual round-trip on the iPhone (operator-confirmed, cold launches, same build, no
  reinstall): section «كوبونات توفر عليك» **appeared** → flag OFF (coupon left in place) →
  section **disappeared** → flag ON → section **returned**. Clean flag-only proof.
- Cleanup: coupon deleted via the destructive admin path (`confirm=permanent` guard
  observed working — unconfirmed delete is refused); category retired via the admin PATCH
  (the route has NO DELETE by design), then the demo-created row removed surgically to
  restore the exact pre-test 0/0; flag restored to its ORIGINAL false/0/f; full flags
  table byte-identical to the pre-test snapshot.
- Financial tables byte-identical throughout: 61 · 58,761.51 · 41,40,15,17,1 · 2,2,2.

---

# PHASE 3 — ADMIN → APP PROPAGATION QA COMPLETE (2026-08-27)

- Announcement content propagation verified end-to-end (forward + reverse, operator-confirmed on device).
- Coupon catalog propagation verified end-to-end (create → visible on Home).
- Feature-flag OFF/ON behaviour visually verified against the same existing catalog item (pure flag proof).
- Cleanup returned the environment to the original baseline (0/0 catalog, flags byte-identical to pre-test, flag restored to false/0/f).
- Financial baseline unchanged throughout: 61 tx · 58,761.51 · accounts 41,40,15,17,1 · budgets 2,2,2.
- Banks/parsers/referrals/campaigns deliberately NOT mutated in this phase; their standing findings
  (F-016 dead regex fields, F-029 category_id overwrite, referral/campaign observations) carry into
  the Phase-4 remediation backlog.
