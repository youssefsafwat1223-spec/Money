# Referral Rewards System — Specification (V1, design-only) — **r3**

> Status: **DESIGN ONLY.** No code, no migrations (next would be 0083 — not
> created), no dependencies, no staging/production contact. Baseline `8d33cff5`,
> **Drift v31 (no bump)**, server migrations 0001→0082. Shares the Canonical
> Vocabulary of [REPORT_ADS_SYSTEM.md §2](./REPORT_ADS_SYSTEM.md); Admin surface
> in [REFERRAL_ADS_ADMIN_SYSTEM.md](./REFERRAL_ADS_ADMIN_SYSTEM.md).
>
> r2: progress authority + cycle pinning, ledger/state separation, concurrency-safe
> UPSERT stacking, deletion that cannot rewind progress, fraud-reversal semantics,
> manual-code-only attribution, InstallId deferred.
> **r3: qualification authority pinned to real Supabase Auth truth (onboarding is
> LOCAL-ONLY — repository finding), explicit qualification trigger, Admin
> idempotency keys, `entitlement_events` ledger rename, atomic ledger+state,
> secure code generation, enumeration/attempt-abuse handling, single server
> enablement authority, rule-deactivation policy, single migration 0083.**

## 1. Product contract

A **referrer** has a stable referral code. When a configured number of genuinely
new users (**referees**) join with that code and **qualify**, the referrer is
granted an **ad-free report-export entitlement** for a configured number of days.
Example, expressed purely as configuration: `required_referrals = 5`,
`reward_type = report_export_ad_free`, `reward_days = 7`. **5 and 7 are never
hardcoded** — they are Admin-managed, versioned rows.

## 2. Repository truth reused (not invented)

- Identity: Supabase `user.id`; `public.profiles` (FK → `auth.users(id) on delete
  cascade`, `0001_init.sql`).
- **Exactly-once template already exists:** `award_gamification_for_transaction`
  (`0074`) — atomic `INSERT … ON CONFLICT DO NOTHING` + `GET DIAGNOSTICS
  ROW_COUNT`, returning the stored canonical result on duplicate calls; SECURITY
  DEFINER + pinned `search_path`; REVOKE anon / GRANT authenticated (`0079`/`0080`).
- **Deletion saga exists:** `purge_user_data(uuid)` (`0065`) explicit DELETE list
  + `account_purge_queue` + `purge-scheduled-deletions` worker.
- Consent: `ConsentState{unset,accepted,declined}` with separate
  `cloudConsentState`/`aiConsentState`. **Ad consent is UMP's, not Qirsh's**
  (Report-Ads §12) — no new Qirsh consent field.
- **Deep links: none.** Only the Google Sign-In reverse-client-id URL scheme; no
  associated domains, no Android App Links (`autoVerify`), no deferred-install
  attribution. This decides §5.
- Flags: `FeatureFlagService` (SHA-256 bucket + rollout% + per-user override),
  seeds in `0003`. New `enable_referrals` (seed false).
- `InstallId` (`core/utils/install_id.dart`) exists — **deliberately not used**
  for referral anti-fraud in V1 (§8).

## 3. Referral identity

- **`referral_codes`**: one row per user; server-generated, stable, opaque
  8-char Crockford base32 excluding ambiguous glyphs (`O 0 I 1 L`), e.g.
  `QK7F9X2M`; `UNIQUE(code)`; `UNIQUE(user_id)`; created lazily on first
  `get_referral_summary`.
- Never a sequential id; never email or phone.
- **Normalization:** trim, strip spaces/dashes, upper-case, fold look-alike input
  characters into the canonical alphabet before lookup.
- **Rotation:** not user-rotatable, not user-editable in V1. Admin may rotate as
  an abuse remedy; the old code stops attributing **going forward** and never
  retroactively unqualifies anything.

### 3.1 Code generation (r3 — server-side, cryptographically secure)

- Generated **only** on the server inside the definer function. The client can
  neither choose nor influence a code.
- **Cryptographically secure randomness** — `gen_random_bytes()` from `pgcrypto`
  (already available in this project's Postgres), never `random()` and never any
  predictable/seeded generator.
- Alphabet: **Crockford base32 minus `O 0 I 1 L`**; **fixed canonical uppercase**
  representation stored and compared.
- `UNIQUE (code)` at the database level is the authority.
- **Collision retry:** bounded loop (e.g. ≤ 5 attempts) re-drawing on unique
  violation; exhaustion raises rather than degrading to a weaker generator.
- No sequential identifiers, no user id derivation, no email/phone.

### 3.2 Lookup privacy — not an enumeration API (r3)

`apply_referral_code` must never become an account-enumeration oracle:

- **Invalid code** returns a single generic rejection
  (`rejected(invalid_code)`) that reveals **nothing** about whether a code
  exists, and never a referrer name, email, phone, user UUID, or any account
  metadata.
- **Successful attribution** returns only the minimum onboarding needs: that
  attribution succeeded, plus the current cycle progress figures for the
  *referee's own* screen. It does **not** disclose the referrer's identity.
- Error shapes for "unknown code", "self-referral" and "already referred" are
  distinguishable to the *caller about themselves* only where that is required
  for correct UX, and never expose another account's existence or attributes.

### 3.3 Apply-attempt abuse (r3)

Codes are share identifiers, not secrets, so V1 does not over-engineer this — but
the behaviour is defined rather than ignored:

- **One successful attribution permanently closes further attempts** for that
  referee (the `UNIQUE(referred_user_id)` invariant), so brute force cannot
  re-target an already-attributed account.
- Self-referral and duplicate attribution are rejected by hard invariants.
- No enumeration is possible (§3.2), so a high-volume attacker learns nothing
  beyond "some code was invalid".
- **High-volume invalid-code throttling is classified DEFERRED OPERATIONAL
  HARDENING.** The repository has a `capture_rate_limits` precedent for
  server-side rate limiting that could be reused cheaply if abuse appears; V1
  does not build a new limiter, and this is recorded as a known, accepted gap
  rather than silently omitted.

## 4. Share UX — **no invite URL claimed in V1** (r2)

The repository owns no landing page and no deep-link infrastructure, so V1 does
**not** claim `https://…/invite?code=…` as a working attribution mechanism.

V1 share payload = friendly Arabic-first invite text **+ the referral code** **+**
the App Store / Play listing URL **only once those URLs actually exist**. The
recipient installs normally and types the code during onboarding.

## 5. Attribution

| Mechanism | V1 status |
|---|---|
| **MANUAL CODE ATTRIBUTION** | **THE V1 MECHANISM.** Referee types/pastes the code in onboarding. Requires no native infrastructure. |
| **DIRECT LINK ATTRIBUTION** | **FAST-FOLLOW.** Requires a registered custom scheme and/or iOS Universal Link + Android App Link — none exist. When added, an *already-installed* app opens with the code and **auto-fills** the onboarding field (still editable, still server-validated). |
| **DEFERRED INSTALL ATTRIBUTION** | **DEFERRED.** Preserving a code through App Store / Play install needs Firebase Dynamic Links (deprecated), Branch, or Play Install Referrer + an iOS equivalent. None present. Not pretended. |

`referrals.attribution_method ∈ {manual_code, direct_link}` is recorded for
analysis; V1 only ever produces `manual_code`.

## 6. Qualification — pinned to server-verifiable truth (r3)

### 6.1 Repository finding: onboarding completion is **LOCAL-ONLY**

Verified: onboarding completion is stored in `FlutterSecureStorage` as
`onboarding_done` (`AppSession`, `core/session/app_session.dart`). The server
`user_settings` table (`0060_user_settings.sql`) has **no** onboarding column,
and `profiles` (`0001`, `0005`: `last_seen_at`, `app_version`) has none either.
**There is no server-authoritative onboarding-completion marker today.**

### 6.2 Decision: **Option B — do not invent a client-trusted claim**

`qualify_referral` must never trust a client boolean such as
`onboarding_completed = true`. Two options were assessed:

- **A.** add a server-authoritative onboarding marker in `0083`;
- **B.** qualify on facts the server can already prove by itself.

**V1 adopts B — the smallest safe design.** Qualification requires, evaluated
entirely from server state:

1. **Verified auth identity** (§6.3) — the expensive, abuse-resistant part;
2. **A successful one-time referral attribution** (`referrals` row exists for the
   referee, `status = 'attributed'`, created inside the window);
3. `referrer ≠ referee`; referee has no other referrer (both DB invariants).

Rationale: the cost of farming referrals is dominated by producing verified
identities, not by completing onboarding; and onboarding completion could only be
asserted by the client today, which would be exactly the client-trusted claim we
must not accept. Option A remains available as a later hardening step if abuse
data warrants it — it would add one server-written marker and one extra
predicate, with no change to any other contract.

### 6.3 Verified-identity authority (r3)

Read **inside** the SECURITY DEFINER function from Supabase Auth truth — never
from a client field:

```sql
-- verified iff a confirmed email OR a trusted OAuth provider identity
EXISTS (SELECT 1 FROM auth.users u
         WHERE u.id = p_referred_user_id
           AND u.email_confirmed_at IS NOT NULL)
OR EXISTS (SELECT 1 FROM auth.identities i
         WHERE i.user_id = p_referred_user_id
           AND i.provider IN ('google','apple'))
```

A client-supplied `isVerified` is never accepted. (The function is definer-owned,
so it may read `auth`; `search_path` stays pinned as in `0079`/`0080`.)

### 6.4 Qualification trigger (r3)

Qualification is **requested**, never asserted. Every predicate is re-validated
server-side on each attempt:

- **(a) Inline at attribution.** `apply_referral_code` attempts qualification in
  the same transaction when §6.2's predicates already hold (the common case: the
  referee signed in with Google/Apple or a confirmed email).
- **(b) Deferred re-attempt.** A guarded `authenticated` RPC
  `request_referral_qualification()` — callable only for *self* — which the
  referee's client may call after sign-in/verification. It carries **no
  arguments** and asserts nothing; the server re-reads auth truth and the
  referral row and decides. A client call can never mean "trust me, I qualify".
- **(c) Optional sweep.** A service-only periodic pass over
  `status = 'attributed'` rows may run the same predicate set. Not required for
  V1 correctness because (b) covers the deferred case.

No path exists by which a client can mark a referral qualified.

**No financial activity is ever required.**

## 7. Entry point & eligibility window

- **Where:** onboarding, after account creation, before first financial setup —
  one optional "Have an invite code?" field (`setup_screen.dart` already has an
  ordered step list).
- **Window:** attachable only **before onboarding completion**, else within
  **72 h of account creation** — whichever comes first. Then the field closes. A
  successful attach is final; failed attempts are soft-rate-limited.

## 8. Anti-fraud

**Hard invariants (DB-enforced, non-negotiable):**
- `referrals.referred_user_id` **UNIQUE** → one referrer per referee, ever.
- `CHECK (referrer_user_id <> referred_user_id)` → no self-referral.
- Milestone claim `UNIQUE(referrer_user_id, rule_id, cycle_index)` → one
  milestone → at most one grant (§12).
- Attach only once, only inside the window (§7).

**InstallId fraud signal — DEFERRED (r2 decision).** V1 does **not** transmit or
store any `InstallId`-derived value for referral anti-fraud. Reusing a stable
device identifier for a new *cross-account* purpose changes its privacy role, and
a stable hash is **not anonymous** — `sha256(installId)` is trivially
correlatable and joins accounts together, which is precisely the capability we
would be introducing. Client-side hashing does **not** meaningfully improve
privacy here; it only obscures the value from casual reading.

V1 therefore launches on **hard server invariants + verified auth + onboarding
completion**. Install correlation is recorded as **DEFERRED FRAUD HARDENING**; if
it is ever adopted it must specify exact server purpose, pseudonymization,
retention, deletion, and access controls, and be approved on its own terms.

**Soft signals retained for V1 (no new identifiers required):** qualification
bursts from one referrer in a short window; disposable-email domains; rapid
account create/delete/recreate patterns. These surface in an Admin review queue
and **never auto-reject**.

## 9. Privacy

No financial data ever enters the referral system — no transactions, balances,
categories, or report contents. Tables carry only user ids, codes, statuses,
timestamps, and grant metadata. No OS advertising id and (per §8) no install
fingerprint.

## 10. Entitlement state contract (**r2 — ledger vs current state**)

Two distinct concerns, never conflated:

**A. `entitlement_events` — immutable, append-only ledger.** *(r3 rename: it
records grant **and** extend **and** revoke **and** shorten, so "grants" was too
narrow. `referral_reward_grants` keeps its name — it genuinely records only
milestone grant claims.)* Every grant,
extension, and revocation is one row, never rewritten:

| col | notes |
|---|---|
| `id` | uuid PK |
| `user_id` | beneficiary |
| `entitlement_type` | `report_export_ad_free` |
| `source` | `referral_reward` \| `admin_grant` |
| `source_reference` | referral grant id / admin audit id |
| `rule_id`, `rule_version` | snapshot (referral grants) |
| `cycle_index`, `milestone_index` | snapshot (referral grants) |
| `duration_days_granted` | **the duration actually granted** |
| `effect` | `grant` \| `extend` \| `revoke` \| `shorten` |
| `resulting_ends_at` | the boundary this row produced |
| `operation_id` | **UNIQUE** — idempotency key (§10.1) |
| `created_at` | server now |

### 10.1 Idempotency for every entitlement mutation (r3)

`entitlement_events.operation_id` is **UNIQUE** and required on every mutation,
so a replay can never double-apply:

- **Referral grants** derive it deterministically from the milestone claim:
  `referral:{rule_id}:{cycle_index}:{referrer_user_id}` — the same milestone can
  only ever produce one event.
- **Admin actions** carry a client-generated UUID minted once per operator
  intent (§10.2).

Replay semantics: the mutation begins with
`INSERT INTO entitlement_events (operation_id, …) ON CONFLICT (operation_id) DO NOTHING`;
`ROW_COUNT = 0` ⇒ this operation already applied ⇒ **return the stored result and
mutate nothing**. `ROW_COUNT = 1` ⇒ this call owns the mutation and proceeds.

### 10.2 Admin operation idempotency (r3 — required)

Every mutating Admin entitlement operation (**grant, extend, shorten, revoke**)
carries an `operation_id` minted **once per operator intent** in the Admin UI and
resent unchanged on retry. Without it, an Admin double-click, a network retry, a
Next.js retry or a reverse-proxy retry could grant 7 days twice.

**Invariant:** the *same* `operation_id` replayed any number of times ⇒ **one**
entitlement mutation and **one** immutable event/audit result. *Different*
intentional operations carry different ids and apply independently (two
deliberate +7-day extensions are two events, +14 days).

### 10.3 Ledger → state atomicity (r3)

For **every** entitlement mutation the immutable event **and** the
`user_entitlement_state` row change **in one server transaction**, inside the
same SECURITY DEFINER function. Neither of these is ever observable:

- event inserted but state unchanged;
- state changed without an event (and, for Admin actions, without an audit row).

**Rollback:** any failure after the `operation_id` claim rolls back the whole
transaction *including the claim*, so the operation may be safely retried with
the same id. A retry **after commit** hits the `ON CONFLICT` path and returns the
stored result. This is the same rollback discipline as `0074`.

**B. `user_entitlement_state` — the single current authority.**

| col | notes |
|---|---|
| `user_id` + `entitlement_type` | **UNIQUE together** (the required invariant) |
| `starts_at`, `ends_at` | server times |
| `status` | `active` \| `revoked` |
| `updated_at` | |

"Currently entitled" is **derived**: `status = 'active' AND ends_at > now()` —
mirroring the coupon `coupon_is_live` predicate. There is **no** mutable
`source_reference` on the current row: multiple referral and admin grants may
extend the same entitlement, and attributing it to one source would be a lie. The
ledger holds provenance; the state row holds only the boundary.

## 11. Concurrency-safe stacking (**r2 — proof, not assertion**)

Rule (unchanged): `base = max(now_server, current_ends_at)`;
`new_ends_at = base + reward_duration`. Never shortens.

The proof matters when **no row exists yet**, so `SELECT … FOR UPDATE` has
nothing to lock. The design uses `UNIQUE(user_id, entitlement_type)` + a single
atomic UPSERT:

```sql
INSERT INTO user_entitlement_state
       (user_id, entitlement_type, starts_at, ends_at, status, updated_at)
VALUES (p_user, p_type, now(), now() + make_interval(days => p_days), 'active', now())
ON CONFLICT (user_id, entitlement_type) DO UPDATE
   SET ends_at   = greatest(user_entitlement_state.ends_at, now())
                   + make_interval(days => p_days),
       status    = 'active',
       updated_at = now()
RETURNING ends_at;
```

Why this is safe in every case:
- **No row exists, two grants race:** both attempt INSERT; the unique index lets
  exactly one succeed. The loser blocks on the index entry until the winner
  commits, then takes the `DO UPDATE` branch and adds its own days to the
  committed value. Result: both durations applied, serialized, no lost update.
- **Row exists, two grants race:** `DO UPDATE` takes a row lock; the second
  re-reads the *committed* `ends_at` (Postgres re-evaluates the `ON CONFLICT DO
  UPDATE` against the locked, updated row) and extends from it.
- **Referral grant and Admin grant simultaneously:** identical mechanism —
  neither is special-cased; both go through the same RPC path.
- Each successful UPSERT writes its `entitlement_events` row (with its
  `operation_id`) in the **same transaction**, so ledger and state can never
  diverge, and a replayed operation is rejected by the `operation_id` claim
  **before** any UPSERT runs (§10.1).

Exactly one serialized current-entitlement result emerges in all cases.

## 12. Progress authority + cycle-pinned rules (**r2 — §§12–13 of the revision**)

Progress is **never recomputed by counting referral rows** (that would let
deletion rewind it — §14). It is an explicit, atomically-advanced state:

**`referral_reward_progress`** — one row per `(referrer_user_id, reward_type)`:

| col | notes |
|---|---|
| `referrer_user_id` + `reward_type` | UNIQUE together |
| `pinned_rule_id`, `pinned_rule_version` | **the rule this cycle is pinned to** |
| `cycle_index` | 1, 2, 3 … |
| `qualified_in_cycle` | 0 … `required_referrals` |
| `cycle_state` | `open` \| `completed` (terminal when `repeatable = false`) |
| `updated_at` | |

**Cycle pinning semantics (the deterministic rule):** *a cycle pins one rule
version for its entire life.* Changing the Admin rule never touches an open cycle;
the new rule applies at the **next cycle boundary**.

Worked example (exactly the required behaviour):
- Progress is **4 / 5** under Rule **V1** (5 → 7 days).
- Admin activates Rule **V2** (10 → 3 days).
- The open cycle stays **4 / 5 under V1**. The next valid referral completes the
  V1 cycle and grants the **V1** reward (7 days).
- The **next** cycle starts pinned to the then-current rule: **0 / 10 under V2**.

Consequences, guaranteed: Admin changes never destroy in-progress progress; an
already-earned reward is never recalculated; a new rule applies only from the
next cycle. If `repeatable = false`, the single pinned cycle completes and
`cycle_state = 'completed'` — no next cycle is created.

**Qualification transition — one atomic transaction, fixed order (r3).**
The whole sequence runs in a single server transaction, in exactly this order:

```
1. qualification transition   (guarded attributed → qualified)
2. progress advance           (row-locked +1 within the open cycle)
3. unique milestone claim     (referrer + rule_id + cycle_index)
4. entitlement event + state  (operation_id claim → UPSERT, §10.1/§10.3)
5. reward-grant record        (referral_reward_grants row completed)
```

**Retry semantics:** a retry **after commit** finds step 1 already done
(`ROW_COUNT = 0`) or the milestone/`operation_id` already claimed, and returns the
**already-stored result** without re-applying anything. A retry **after
rollback** finds no trace and may safely attempt again from step 1.

Concretely:

1. Guarded flip of the referral row `attributed → qualified`
   (`UPDATE … WHERE status = 'attributed'`; `ROW_COUNT = 0` ⇒ already processed ⇒
   return the stored outcome, advance nothing). *This is the exactly-once anchor.*
2. `UPDATE referral_reward_progress SET qualified_in_cycle = qualified_in_cycle + 1
   … WHERE cycle_state = 'open'` (row-locked).
3. If `qualified_in_cycle = pinned required_referrals`:
   a. **Claim the milestone** —
      `INSERT INTO referral_reward_grants (referrer_user_id, rule_id, cycle_index, …)
      ON CONFLICT (referrer_user_id, rule_id, cycle_index) DO NOTHING`;
      `ROW_COUNT = 0` ⇒ already granted ⇒ return stored result.
   b. Winner: apply the entitlement UPSERT (§11) + write `entitlement_events`.
   c. **Initialize the next cycle** if `repeatable`: `cycle_index += 1`,
      `qualified_in_cycle = 0`, **re-pin to the currently-active rule**; else
      `cycle_state = 'completed'`.

**Fifth / sixth behaviour (explicit):** the 5th qualification performs
`4 → 5 → claim → grant → open cycle 2 at 0/N`. The 6th is therefore **1 / N of
cycle 2** — never an ambiguous "6/5". With `repeatable = false` the 6th advances
nothing and grants nothing.

## 13. Immutable grant history

`referral_reward_grants` (milestone claim + audit) and `entitlement_events`
(§10 A) are **append-only**. Each referral grant records referrer, `rule_id`,
`rule_version`, `cycle_index`/`milestone_index`, reward type, **duration actually
granted**, grant timestamp, and the resulting entitlement boundary. Admin rule
changes never rewrite them.

## 14. Referred-user account deletion (**r2 — contradiction fixed**)

The earlier draft said "qualification is final" while cascading referral rows on
referee deletion — which would have rewound the referrer's progress. Fixed by
construction:

- **Progress is a counter** (§12), not a recount of rows, so deleting rows can
  never move it backwards.
- **Unqualified attribution** (`status = 'attributed'`) → removed entirely with
  the deleted user. Nothing was earned.
- **Qualified referral** → the row is **de-identified, not deleted**:
  `referred_user_id` FK is **`ON DELETE SET NULL`**, and the row keeps only the
  non-identifying qualification fact (`status='qualified'`, `qualified_at`,
  `cycle_index`, `attribution_method`) plus `referred_user_deleted_at`. That is
  the minimum needed to keep grant validity, cycle accounting, and exactly-once
  history intact.
- **No deleted-user PII is retained**, and no deleted `auth.users` UUID is kept
  merely for referrals — the reference is nulled, not preserved.
- Already-earned entitlements are unaffected by a referee's later deletion.

## 15. Referrer account deletion

On purge of referrer `U`, the user-facing referral domain is removed:
`referral_codes`, `referral_reward_progress`, `user_entitlement_state`,
`entitlement_events`, `referral_reward_grants` for `U`, and `referrals` where `U`
was the referrer (referees' rows have their `referrer_user_id` nulled, keeping no
dangling FK). Any minimal security/audit retention must be **explicitly justified
and de-identified** (Admin audit rows null their `target_user_id` on purge).
All of this is added to the existing `purge_user_data(uuid)` DELETE list so the
saga stays the single deletion authority. **No dangling FK anywhere.**

## 16. Fraud reversal semantics (**r2**)

Two clearly separated cases; **no historical row is ever silently deleted**:

**A. Pending / unqualified referral rejection.** Referral moves
`attributed → rejected` with a `rejection_reason`. No progress was counted, no
grant existed. Fully reversible bookkeeping.

**B. Already-qualified referral found fraudulent.** The immutable history is
**not** rewritten. Instead:
- the referral row is marked `reversed` + `rejection_reason` (its `qualified_at`
  stays for audit);
- an explicit **reversal/adjustment row** is appended to the ledger;
- **current-cycle progress may be decremented** — but only by explicit Admin
  action, recorded, and never below zero, and never across an already-completed
  cycle boundary (a completed cycle's grant stands);
- **the already-issued entitlement is NOT automatically shortened.** Shortening
  requires a **separate, explicit Admin revoke/shorten action with a required
  reason**, which appends its own `entitlement_events` row (`effect = revoke |
  shorten`) and its own audit entry.

**Consumed historical ad-free time is never rewritten.** Fraud marking and
entitlement revocation are deliberately two decisions, so an operator cannot
retroactively erase time a user already used.

## 17. Server data model (designed, **not migrated**)

`referral_codes`, `referrals`, `referral_reward_rules`,
`referral_reward_progress` (§12), `referral_reward_grants` (§12/§13),
`user_entitlement_state` (§10 B), `entitlement_events` (§10 A),
`referral_admin_audit` (Admin spec).

`referrals` columns: `id`, `referrer_user_id`, `referred_user_id` (UNIQUE, FK
`ON DELETE SET NULL`), `referral_code`, `attribution_method`, `status`
(`attributed|qualified|rejected|reversed`), `rejection_reason`, `created_at`,
`qualified_at`, `referred_user_deleted_at`, `CHECK (referrer <> referred)`.

`referral_reward_rules`: `id`, `version`, `reward_type`, `required_referrals`,
`reward_days`, `repeatable`, `is_active`, `effective_from`, `effective_until`.

Names are recommendations; the **UNIQUE/CHECK invariants and the ledger/state
separation are fixed**.

## 18. RPC / server operations

RPC-only; no Edge Function is required for V1 (nothing needs secrets or non-SQL
logic).

| Operation | Exposure |
|---|---|
| `get_referral_summary()` | `authenticated`, self only — code, `k/N` progress, cycle, active entitlement + expiry |
| `apply_referral_code(p_code)` | `authenticated`, self only — the single guarded attribution path |
| `qualify_referral(p_referred_user_id)` | **service/trigger only** — qualification + progress + exactly-once grant (§12) |
| `grant_entitlement(...)` / `revoke_entitlement(...)` | **service only** — Admin manual actions, audited |

Qualification and grant functions are never callable by a normal user.

## 19. Server referral authority — **one** authority, no second boolean (r3)

Exactly one server mutation authority, and it is **not** a feature flag:

| Layer | Authority | Governs |
|---|---|---|
| **Client** | `enable_referrals` (FeatureFlagService) | **discovery/UI rollout only** |
| **Server** | **an active, in-window `referral_reward_rule`** | whether new referral **attribution and qualification** are accepted |

**No active rule ⇒ the server rejects new attribution/qualification** with
`rejected(no_active_rule)`. No second "referral system enabled" boolean exists —
the rule's `is_active` + effective dates *are* the switch.

The server deliberately does **not** consult `feature_flags` for mutation
authority: `FeatureFlagService` rollout is a *client-side, per-install SHA-256*
bucket, and reproducing it server-side would mean re-implementing install-level
bucketing for a decision that must be account-level and deterministic. Rollout
percentage governs who *sees* the feature; the rule governs what the server
*accepts*.

**User-facing controlled errors** (never a crash, never a silent success):
`rejected(no_active_rule)` → "الدعوات غير متاحة حاليًا / Invites aren't available
right now"; likewise `rejected(invalid_code)`, `rejected(self_referral)`,
`rejected(already_referred)`, `rejected(window_closed)`. A stale client that still
shows the UI fails **safely and legibly**.

### 19.1 Rule deactivation vs pinned cycles (r3)

A boolean flip must never retroactively erase progress. **V1 policy:**

- **New attribution stops immediately** (no active rule ⇒ reject).
- **Already-attributed referrals may still qualify**, and an **already-pinned
  in-progress cycle may still complete** under its pinned rule version — a user
  at 4/5 with a 5th already attributed can finish and receive the pinned reward.
- **No new cycle opens** while no rule is active. If a cycle completes with
  `repeatable = true` and no rule is active, progress enters
  `cycle_state = 'awaiting_rule'`; a new cycle is pinned when a rule is active
  again.
- Pinned progress and earned rewards are never destroyed by deactivation.

Admin deactivation confirmation must say:

> Deactivating stops new invites from being attributed. Users who already have an
> invite in progress can still complete their current cycle under the rule it was
> started with. No new cycles start until a rule is active again.

## 20. Kill-switch propagation reality

- **Server-side** (rule `is_active = false`, or revoking the RPC grant):
  **immediate** for new referral mutations.
- **Client-side** `enable_referrals` / `enable_report_ads`: delivered by
  `FeatureFlagService`, which re-evaluates only after **catalog sync + app
  restart** (flag-reading providers are not invalidated post-sync). A running
  client is **not** updated instantly, and a client-side AdMob placement cannot be
  instantly removed from a live process. Same-session flag reactivity is a
  **separate rollout-hardening item** to resolve before these are relied on as
  incident kill switches (Report-Ads §15).

## 21. RLS / security

- `referral_codes`: owner `SELECT` own; no client write.
- `referrals`: referrer `SELECT` own-as-referrer; referee `SELECT` own row. No
  client INSERT/UPDATE/DELETE; no client write to `status`/`qualified_at`.
- `referral_reward_rules`: **no client access** (Admin/service only). The client
  learns thresholds only through `get_referral_summary`'s computed `k/N`.
- `referral_reward_progress`, `referral_reward_grants`, `entitlement_events`:
  **no client access**.
- `user_entitlement_state`: owner `SELECT` own; **no client write**.
- Users may not qualify referrals, increment counts, grant themselves
  entitlement, edit rules, or touch another user's data.
- Admin path: browser → authenticated route → `admin_users` → service role.

## 22. Client entitlement consumption

The client never self-awards and never computes an expiry. It reads
`{status, ends_at, server_now, verified_at}` and resolves it into the **three-state
decision** owned by [REPORT_ADS_SYSTEM.md §8](./REPORT_ADS_SYSTEM.md):
`VERIFIED_ACTIVE` (no ad), `VERIFIED_INACTIVE` (**the only state that may show an
ad**, and only while fresh within the 5-minute TTL), or `UNKNOWN_OR_STALE` (no
ad). Any lookup failure — server unreachable, auth refresh failure, RPC timeout,
malformed response, resume-before-refresh, signed-out — resolves to
`UNKNOWN_OR_STALE`, so an entitled user is never shown an ad because the
authority could not be reached. State is held **in-session**, keyed to the
authenticated user id and cleared on logout / account switch / deletion, and
refreshed at sign-in / resume / report-area entry. **No local persistence in V1 (Drift stays
v31)** — see Report-Ads §10–§11. Multi-device converges because the state is
per-account and server-owned.

## 23. Auth edge cases

Signed-out / local-only export → no account → **ad-free**, no ad. Auth
unavailable → session state if present, else ad path (fail-open). **Account
switch → entitlement state is per-account and cleared/replaced**, so one user's
ad-free days never leak into another session. Logout clears it; login refetches.

## 24. Feature flags

`enable_referrals` (seed false) — client rollout/UI gate; server enforces
independently (§19). `enable_report_ads` (seed false) — Report-Ads §14.
Separate flags so either system can be disabled alone.

## 25. Analytics (privacy-minimal)

Client: `referral_code_copied`, `referral_shared`,
`referral_code_apply_requested`. **Server-authority** (derived from server state,
never a client claim): `referral_attributed`, `referral_qualified`,
`referral_reward_granted`. No financial values, no report contents.
Report-ad events use the Report-Ads §18 vocabulary (no reward terms).

## 26. Drift & backup impact

**Drift stays v31 — no new table** (Report-Ads §11: with fail-open a persisted
entitlement cache has no correctness role). Referral progress is read via RPC and
held in memory. **Nothing** from this feature enters the financial backup;
business backup **v4** and crypto envelope **v3** are unchanged. Server authority
survives reinstall via account sync.

## 27. Migration plan — **single `0083`** (r3, not created)

Reassessed under "minimize server surface". **`report_ads_config` is eliminated**
(Report-Ads §14: after removing `enabled`, nothing needed server control —
placement is fixed, preload/timeout are client constants, ad-unit IDs are build
configuration). With no report-ads table, **`0084` has no content of its own and
is not created.**

**`0083_referral_rewards.sql`** — the entire server surface:

- tables: `referral_codes`, `referrals`, `referral_reward_rules`,
  `referral_reward_progress`, `referral_reward_grants`, `user_entitlement_state`,
  `entitlement_events`, `referral_admin_audit`;
- RLS on all of them (§21);
- RPCs: `get_referral_summary`, `apply_referral_code`,
  `request_referral_qualification`, `qualify_referral` (service),
  `grant_entitlement` / `revoke_entitlement` (service, `operation_id`);
- `purge_user_data(uuid)` extension (§14/§15);
- feature-flag seeds **`enable_referrals` and `enable_report_ads`, both false**
  (one-row inserts alongside the existing `0003` seeds).

`referral_admin_audit` lives here because it is referral/entitlement audit with
**no technical dependency** on report-ads config; making it wait on a second
migration would be artificial coupling.

*Rejected alternative:* splitting purely so Report Ads is "separately
revertible" — enablement is toggled by **data** (the flag row), not by reverting
a migration, so the split bought nothing and added a deploy step.

**Report Ads server surface = the `enable_report_ads` flag row + the shared
entitlement tables. It needs no table of its own.**

## 28. Mobile referral UX

Settings/Profile → **"دعوة الأصدقاء / Invite Friends"**: the code; copy; share
(invite text + code + store URLs when they exist — §4); progress
**"٣ / ٥ دعوات صالحة"** for the **current cycle**; reward description; and, when
active, "تقارير بدون إعلانات حتى ٢٤ أغسطس". Arabic-first, English fallback.
Restrained — no gamification noise on the financial home.

## 29. Test plan (local)

- unique code; repeat call returns the same code.
- `apply_referral_code`: valid → attributed; unknown → rejected; self → rejected;
  second referrer → rejected(already_referred); outside window →
  rejected(window_closed); **server disabled / no active rule → rejected even
  when the client flag says enabled** (§19).
- race: two applies → exactly one attach (UNIQUE).
- **H. qualification cannot trust a client onboarding boolean** — a call
  asserting `onboarding_completed = true` grants nothing.
- **I. qualification reads the exact authoritative state**: unverified referee
  (no `email_confirmed_at`, no google/apple identity) → not qualified; verified
  → qualified. Verification is read from `auth.users`/`auth.identities`, never a
  client field.
- **J. an invalid code leaks no referrer identity** — the rejection body contains
  no name, email, phone, user UUID or account metadata, and does not reveal
  whether the code exists.
- **K. a successful attribution permanently closes further apply attempts** for
  that referee.
- 4/5 → no grant; **5th → exactly one grant**, progress → cycle 2 at 0/N.
- **6th → 1/N of cycle 2** (repeatable) or nothing (non-repeatable).
- replay `qualify_referral` / concurrent 5th & 6th → one grant per cycle.
- **L. pinned cycle survives a rule-version change:** 4/5 under V1, activate
  V2(10/3) → next referral completes **V1** and grants **7 days**; the following
  cycle starts **0/10 under V2**.
- **M. rule deactivation:** new attribution rejected with
  `rejected(no_active_rule)`; an already-attributed referral still qualifies and
  a pinned in-progress cycle still completes; no new cycle opens
  (`awaiting_rule`); no progress is destroyed.
- **E. concurrent Admin duplicate `operation_id` → exactly one extension.**
- **F. same Admin `operation_id` retried → the same stored result**, no second
  mutation, no second audit row.
- **G. two distinct Admin `operation_id`s → two intentional extensions** (+14
  days for two +7 operations).
- ledger↔state atomicity: an induced failure after the `operation_id` claim rolls
  back **both** the event and the state change; retry with the same id succeeds
  once.
- stacking concurrency: two simultaneous grants with **no existing row** → both
  durations applied exactly once (§11); with an existing row → likewise; referral
  + admin grant simultaneously → serialized.
- referee deletion: qualified row de-identified, **progress unchanged**, grant
  still valid; unqualified row removed.
- referrer deletion: full purge, no dangling FK.
- fraud: reject-pending vs reverse-qualified; reversal does **not** auto-shorten
  an entitlement; explicit revoke does, with audit.
- multi-device: entitlement visible on a second signed-in device.

## 30. Staging E2E (future phase, Coupons-grade rigor)

Validation staging only (`bdhqjijscwdzqwqanygv`), never production; **injected
fake AdGateway or Google test ad units — never a live/production ad**:

```
Admin sets rule (5 / 7 / report_export_ad_free / repeatable)
 → A: get_referral_summary → code
 → B,C,D,E,F apply A's code (manual) + verify + complete onboarding
 → each qualifies server-side
 → EXACTLY ONE grant at the 5th; progress opens cycle 2 at 0/5
 → user_entitlement_state active for A (server time)
 → mobile harness (real SupabaseClient, real gate, Drift v31) sees ad-free
 → report export BYPASSES the ad gate while entitled
 → clamp to expiry → ad path returns
```

Reuse the C5 pattern: process-scoped staging credentials (never an env file),
fail-closed project-ref assertion before any mutation, full cleanup, schema
retained as evidence. Distinguish **server/referral E2E** (headless,
deterministic) from **real AdMob SDK physical-device smoke** (§31).

## 31. Physical-device QA (fold into 9I/9V)

iOS + Android: real interstitial presentation in **test mode with Google test ad
units only** (never a production ad, never a click); lifecycle; UMP form where
required; report export completes after dismissal; TestFlight / Play internal.
Evidence must state that test mode was used.

## 32. Responsibility matrix

| Server-authoritative | Client-responsible |
|---|---|
| referral ownership/code, attribution, qualification | show code, copy/share, request-apply |
| **progress state + cycle pinning** | show `k/N` for the current cycle |
| reward rule + version, grant (exactly-once) | — |
| **entitlement state + ledger** | present cached session state; run the ad gate |
| Admin mutations + audit | report export UX |

**The client never self-awards.**

## 33. Release / Path-B impact

Reopens Feature Freeze. Delta on the C6 manifest: migration ceiling 0082 →
**0083** (single migration; no `0084`); **Drift stays v31**; **no new Edge Function**; `enable_referrals` +
`enable_report_ads` seeds (false); new `google_mobile_ads` dependency + native ad
config + **UMP consent lifecycle**; Admin gains "Referral & Ads" (needs the Admin
deploy/build gate). Sequence: specs → review → server (`0083`) → Admin →
mobile (interstitial + referral) → local full gate 13/13 → staging E2E →
physical AdMob smoke (test mode) → release-impact reconciliation → **Feature
Freeze again** → 9Q.

## 34. Closed-domain isolation

Must not alter Money, Planning currency, CAS, financial sync, capture, the Coupon
system, the backup snapshot, or financial notification semantics. The only
Reports integration is the gate around **export**, never the financial
calculation. Any required touch of a closed contract is reported before change.
