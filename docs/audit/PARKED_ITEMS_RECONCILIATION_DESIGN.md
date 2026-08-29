<!-- PROVENANCE: copied from `demo-docker/PARKED_ITEMS_RECONCILIATION_DESIGN.md`, which is an untracked local
     demo/working directory. Design record for parked-item reconciliation — the exact-money parking contract.
     Tracked here so the authoritative artifact survives loss of that
     directory. The original is left in place; this copy is the one of
     record. -->

# PARKED PLANNING ITEMS — FORENSIC PASS & RECONCILIATION DESIGN

**No push. No conflict resolution. No deletion. No outbox mutation.** Analysis only.

Date 2026-08-26 · demo-docker only · Main/Audit untouched.

---

## 0. The single most important finding

**A stale snapshot cannot overwrite newer server state.** I expected this to be the risk; the code
already prevents it.

Every account update carries a **base token** captured at enqueue time
(`planning_outbox_queue.dart:412-425`):

```dart
final cols = readsRevision ? 'server_updated_at, server_revision' : 'server_updated_at';
final baseRow = await _db.customSelect('SELECT $cols FROM $table WHERE id = …');
final enriched = {...payload,
  if (baseToken != null)   'server_updated_at': baseToken,
  if (baseRevision != null) 'server_revision': baseRevision};
```

and the push refuses to write when that base no longer matches
(`accounts_push_service.dart:393-415`):

```dart
final expectedRevision = item.payloadJson['server_revision'] as int?;
if (_revisionCasEnabled && expectedRevision != null) {
  response = await _remoteSink.casUpdateAccount(serverId, expectedRevision, row);
  if (response == null) { await _markConflict(item.entityId); … return conflict; }
} else {
  final base = item.payloadJson['server_updated_at'] as String?;
  if (base != null) {
    final current = await _remoteSink.fetchAccountUpdatedAt(serverId);
    if (current != null && current != base) { await _markConflict(…); … return conflict; }
  }
  response = await _remoteSink.updateAccountByServerId(serverId, row);
}
```

`kServerRevisionCas = false` (`core/sync/sync_capabilities.dart:27`), so **every** account update
takes the **guarded-timestamp** branch, not revision CAS.

### What replaying the 11 items would actually do

Server `updated_at` for `acc-mada` / `acc-rajhi` / `acc-cash` has moved repeatedly (F-020 traffic).
Every parked base token predates that. Therefore each item would:

1. fetch the server's current `updated_at`,
2. see it ≠ its base,
3. call `_markConflict(entityId)` and `markSuccess(item.id)`,
4. return `conflict` — **the item is consumed, never retried, and nothing is written.**

**Net effect of a full replay: 0 server writes, 3 accounts re-flagged `conflict`, queue drained.**

So the danger is not corruption — it is **noise and state damage**: 11 pointless round-trips that
re-wedge the same three accounts we just spent a fix un-wedging.

---

## 1. Payload shape — why "coalescing" is the wrong verb

`_buildAccountPayload` (`planning_outbox_queue.dart:649`) emits a **complete row snapshot**, not a
delta:

```
local_id · name · currency · type · initial_balance · current_balance ·
bank_account_number · credit_limit · available_credit · payment_due_day ·
wallet_provider · exclude_from_totals · metadata · is_default · sort_order ·
created_at · updated_at        (+ server_updated_at / server_revision base tokens)
```

Consequences:

* There is **no field-level intent** to merge. Item *n* does not say "the user changed X"; it says
  "the whole account looked like this at time *n*".
* Therefore **the last snapshot for an account already subsumes every earlier one** — they are not
  independent intents, they are successive photographs.
* Money fields are exact decimal strings (`moneyToNumericTextOrNull`) — no precision concern.

**Conclusion: these items are not mergeable, and they do not need to be. They are redundant.**

---

## 2. Disposition of all 15 parked items

Counts from the probe (`demo_inventory.json`, post-PUSH-02):

| # | entity | op | status | entity_id | disposition |
|---|---|---|---|---|---|
| 1 | account | create | parked | `iBWc2pkGU02-YsHJOekNtg` («حساب EGP») | **KEEP — independently meaningful.** A `create` for a row with no `server_id`; nothing supersedes it, no base token to be stale. This is the natural PUSH-03 dependency. |
| 2–12 | account | update | parked | `acc-mada`, `acc-rajhi`, `acc-cash` (11 items over 3 accounts) | **SUPERSEDE ALL — rebuild one per account.** Every one is a whole-row snapshot against a base token the server has long passed. |
| 13–15 | budget | update | parked | `bud-groceries`, `bud-restaurants`, `bud-transport` | **KEEP — still current.** `user_budgets` has not changed on the server since the seed, so each base token still matches. One item per budget: no duplication. |

**Still to be confirmed per item** (needs the probe extension in §5): exact `payload_json`, each
item's `server_updated_at` base, and creation order within each account.

---

## 3. Recommended architecture: **REBUILD**, not coalesce or supersede-in-place

Three candidate strategies, judged against "preserve legitimate local intent, never let a stale
snapshot overwrite newer server fields":

| strategy | verdict |
|---|---|
| **Coalesce** — merge the 11 payloads into one | ✗ Meaningless. Snapshots do not merge; you would just pick one. And whichever you pick still carries a **stale base token**, so it conflicts anyway. |
| **Supersede** — keep only the newest item per account, drop the rest | ✗ Better, but the survivor still holds an **old base token** and an **old snapshot**. It conflicts on push and re-wedges the account. |
| **Rebuild** — drop all 11, re-enqueue exactly one fresh update per account from **current local state** with a **freshly read base token** | ✓ **Correct.** The payload reflects what the user's device actually holds now, and the base token matches the server the moment before the push, so the guard passes and the write lands. |

### The algorithm

```
for each account A with parked update items:
    1. VERIFY  A.sync_status is not 'conflict'
                 (a conflicted account must be resolved first — §4)
    2. READ    A's current local row  → payload = _buildAccountPayload(update, A)
    3. READ    A.server_updated_at / A.server_revision  → fresh base tokens
               (exactly what _enqueue already does — no new mechanism)
    4. COMPARE payload against the current SERVER row, field by field,
               money as exact minor units
               → if identical: the local intent is ALREADY represented remotely.
                 Drop all parked items for A. Enqueue NOTHING.
               → if different: enqueue ONE update carrying (payload, fresh base).
    5. DROP    every previously parked item for A.
```

Step 4 is what makes this safe and honest: **it re-derives whether any local intent still exists**
rather than assuming it does. For the three accounts here, the earlier field comparison (F-021's
`_serverDivergedFromLocal`) already suggests local and server content agree on everything except
`is_default`, which means most or all of these items may resolve to *"enqueue nothing"*.

### Why this preserves user intent

The user's intent lives in the **current local row**, not in a historical outbox snapshot. The row is
the durable record; the outbox is a delivery mechanism. Rebuilding from the row therefore cannot lose
intent — it can only lose *redundant descriptions* of that intent. The one thing that would lose
intent is discarding the local row, which this algorithm never does.

---

## 4. The three conflicts — divergence analysis

`sync_status = 'conflict'` on `acc-mada`, `acc-rajhi`, `acc-cash`.

**Do not resolve by picking a side.** Both existing buttons («احتفظ بنسختي» / «نسخة الجهاز الآخر»)
are whole-row choices, and F-021 showed the flag itself was often raised without evidence.

### What is known

| account | local `server_revision` (base) | current server `revision` | local `is_default` | server `is_default` |
|---|---|---|---|---|
| `acc-rajhi` | 19 | 36 | 1 | **t** |
| `acc-mada` | 23 | 37 | 0 | **f** |
| `acc-cash` | 11 | 15 | 0 | **f** |

**The `is_default` values agree on all three.** The revision gap is explained entirely by
`set_default_account` traffic (F-020), which rewrites **no account fields** — it only flips
`is_default` and bumps `revision`/`updated_at`.

**Working hypothesis, to be proven in §5:** there is **no field-level divergence at all**. The rows
diverge only in `revision`/`updated_at` — metadata the local row does not contest. If confirmed, the
correct resolution is neither "keep mine" nor "keep theirs" but:

> **re-prove the base**: adopt the server's `revision`/`updated_at` as the new base, leave every
> content field untouched on both sides, and clear the conflict.

That is precisely what F-021's `_refreshServerProofKeepingPending` already does — it simply cannot
run today because `_serverDivergedFromLocal` returns true on the `is_default`/timing race, not on
real content.

### Required before resolving

A field-by-field diff of **local vs base vs server** for each of the three accounts. Two-way
comparison is insufficient: a field that differs local-vs-server may have been changed by *either*
side, and only the base tells you which. This is the one piece of forensics that cannot be inferred
from what I hold today.

---

## 5. What the probe must additionally dump

The current probe answers counts, not payloads. To complete §2 and §4 it needs three more read-only
queries:

```sql
-- 1. exact payload + base tokens + ordering, per parked item
SELECT id, entity_type, entity_id, operation, status, payload_json, created_at
FROM planning_sync_outbox ORDER BY entity_id, created_at;

-- 2. the full current local account row (all content fields)
SELECT id, name, currency, type, initial_balance_minor, current_balance_minor,
       credit_limit_minor, available_credit_minor, bank_account_number,
       payment_due_day, wallet_provider, exclude_from_totals, is_default,
       sort_order, metadata, server_id, server_revision, server_updated_at,
       sync_status
FROM accounts;

-- 3. same for budgets, to confirm their base tokens are still current
SELECT id, server_id, server_revision, server_updated_at, sync_status FROM budgets;
```

Server-side values come from Docker directly — no probe needed.

**Blocked on disk:** free space is **3.65 GiB** against the `START_MIN_GIB = 5` gate. Per standing
instruction, nothing is deleted automatically. The extension is written but not built.

---

## 6. Tests required to prove the algorithm

| # | test | asserts |
|---|---|---|
| 1 | rebuild with **identical** local/server content | zero items enqueued; all parked items dropped; no server write |
| 2 | rebuild with a **genuine** local edit | exactly **one** item enqueued per account; payload equals current local row; base token equals the row's current `server_updated_at` |
| 3 | 11 parked items over 3 accounts | after rebuild, **at most 3** items exist — never 11, never per-item replay |
| 4 | server moves **between** rebuild and push | guarded path detects it → conflict, **no overwrite** (proves the guard survives the rebuild) |
| 5 | rebuild on a **conflicted** account | refuses; leaves the conflict for explicit resolution (step 1 of the algorithm) |
| 6 | money fields | compared as exact integer minor units; a **one-minor-unit** difference counts as a real edit |
| 7 | `account create` («حساب EGP») | untouched by the rebuild — creates have no base to be stale against |
| 8 | budget items | untouched; their base tokens still match the server |
| 9 | idempotency | running the rebuild twice produces the same queue, not duplicates |
| 10 | no data loss | every local account row is byte-identical before and after the rebuild |

---

## 7. Recommended order

1. Free disk to ≥ 5 GiB (**your call — nothing deleted automatically**).
2. Build the probe extension; capture the full forensic dump.
3. Confirm or refute the §4 hypothesis (no real field divergence).
4. If confirmed: clear the three conflicts by **re-proving the base**, not by choosing a side.
5. Run the §3 rebuild; expect **≤ 3 items**, quite possibly **0**.
6. **PUSH-03** — one isolated financial UPDATE from a clean, current base, using the same
   `DEMO_PUSH_ALLOW` isolation that PUSH-02 proved.

**Nothing in steps 3–6 executes without your approval.**
