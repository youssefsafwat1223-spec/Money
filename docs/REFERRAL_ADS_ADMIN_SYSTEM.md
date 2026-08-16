# Referral & Ads — Admin System Specification (V1, design-only) — **r3**

> Status: **DESIGN ONLY.** No code, no migrations, no dependencies, no
> staging/production contact. Baseline `8d33cff5`, **Drift v31 (no bump)**.
> Companions: [REPORT_ADS_SYSTEM.md](./REPORT_ADS_SYSTEM.md),
> [REFERRAL_REWARDS_SYSTEM.md](./REFERRAL_REWARDS_SYSTEM.md). Shares their
> Canonical Vocabulary (Report-Ads §2).
>
> r2: Standard Interstitial vocabulary, `report_ads_config.enabled` removed, no
> `require_when_online`, UMP is the consent authority, cycle pinning surfaced,
> fraud reversal split from entitlement revocation.
> **r3: `report_ads_config` ELIMINATED entirely (no table, no `0084`), Admin
> operation idempotency keys, `entitlement_events` ledger rename, bounded
> plain-text reason contract, de-identified allowlisted audit payloads,
> rule-deactivation UX, kill-switch hardening classified REQUIRED.**

## 1. Reuse of the existing secure Admin architecture (repository truth)

Extends the Next.js 14 admin at `admin/` exactly as Coupons (C3) did — no second
admin system:

- **Navigation:** `admin/components/sidebar.tsx` `NAV[]` (Dashboard, Banks,
  Parsers, Categories, Feature Flags, Announcements, Campaigns, Offers, Parser
  Lab). Add one entry: **`{ href: "/referrals", label: "Referral & Ads" }`**.
- **Auth chain (unchanged):** browser session → authenticated route →
  `requireAdmin()` (`admin/lib/auth-guard.ts`; `admin_users` membership;
  fail-closed **503** on lookup failure) → `createAdminClient()` service-role
  operation (`admin/lib/supabase-server.ts`, server-only). Middleware redirects
  unauthenticated → `/login` (307) and non-admin → `/not-authorized` (307);
  route-level `adminAuthErrorResponse` (401/403/503) is defence-in-depth behind it.
- **Validation pattern:** plain `.mjs` shared by TS routes and node:test
  (`coupon-validation.mjs` precedent) → `referral-validation.mjs`,
  `referral-errors.mjs`.
- **C3 rule:** Next.js route files export **only HTTP verbs** — a stray export
  breaks `next build` and `tsc` alone will not catch it.
- **Service-role boundary:** `SUPABASE_SERVICE_ROLE_KEY` never reaches the
  browser.

## 2. Sections under **Referral & Ads**

1. Report Ads settings (§3) · 2. Referral rules (§4) · 3. User lookup (§5) ·
4. Referral / entitlement detail (§6) · 5. Manual actions (§7) ·
6. Fraud review (§8) · 7. Audit history (§9) · 8. Metrics (§10)

## 3. Report Ads settings — **no config table** (r3)

**`report_ads_config` is eliminated.** After `enabled` was removed in r2, nothing
remained that needed server control: the placement is fixed (Report Export), the
preload budget and show-timeout are client constants, and ad-unit/app IDs are
build-time environment configuration. A table created only to justify a migration
is rejected — see [REFERRAL_REWARDS_SYSTEM.md §27] (**no `0084`**).

The Report Ads screen is therefore **read-only diagnostics plus one flag
pointer**:

| Shown | Source | Editable? |
|---|---|---|
| `enable_report_ads` state / rollout | `feature_flags` (existing Feature Flags admin) | via the existing flags screen |
| resolved ad-unit IDs + environment (test/production) | server-side build config | **no** — display only |
| the effective ad-gate chain (below) | computed | no |
| fixed V1 product policy: **fail-open**, one ad opportunity per export | constant | no |

**Never Admin-editable:** AdMob app/ad-unit IDs, any SDK or server credential,
test-device registration. Ad-unit IDs are environment configuration identifiers,
not business content and not secrets, but they are still supplied by build
configuration and never pasted into a DB row.

**Removed and not reintroduced:** `report_ads_config.enabled`, `ad_gate_policy` /
`require_when_online` (V1 is unconditionally fail-open, so no operator can make
report export depend on ad delivery), and any Admin ad-consent setting — **Google
UMP is the consent authority** (Report-Ads §12), and Qirsh product analytics use
the separate existing `cloudProcessingEnabled` surface (Report-Ads §12.1).

**Effective ad gate (read-only diagnostic):** `enable_report_ads` ∧ valid build
config ∧ UMP `canRequestAds` ∧ entitlement decision `VERIFIED_INACTIVE` (fresh)
∧ ad available.

**Kill-switch reality shown in the UI:** flag flips require catalog sync + app
restart, so the screen must **not** present `enable_report_ads` as instantaneous.
**Same-session flag reactivity is REQUIRED rollout hardening before
`enable_report_ads = true` in production** (Report-Ads §15). Pausing the AdMob ad
unit is an operational fallback only, never correctness authority.

## 4. Referral rule config

Admin manages `referral_reward_rules` — the "5 / 7" as **configuration, never
hardcoded**:

| Field | Validation |
|---|---|
| `reward_type` | enum; V1 `report_export_ad_free` |
| `required_referrals` | int ≥ 1 |
| `reward_days` | int ≥ 1, ≤ sane max |
| `repeatable` | boolean |
| `is_active` | at most one active rule per `reward_type` |
| `effective_from` / `effective_until` | `until` > `from` |

**Cycle-pinning must be surfaced in the UI** (Referral §12). Editing a threshold
creates a **new version**; the editor states plainly:

> Changing this creates a new rule version. Users with a cycle already in
> progress keep their current rule until that cycle completes; the new rule
> applies from their next cycle. Rewards already earned are never recalculated.

**Deactivation confirmation must state the pinned-cycle policy** (Referral §19.1):

> Deactivating stops new invites from being attributed. Users who already have an
> invite in progress can still complete their current cycle under the rule it was
> started with. No new cycles start until a rule is active again.

**There is no separate "referral system enabled" Admin boolean.** The rule's
`is_active` + effective dates **are** the server authority; `enable_referrals`
governs only client discovery/UI rollout (Referral §19).

All rule changes are audited (§9).

## 5. User lookup

Search by **safe existing identifiers only** — `user_id`, referral `code`, or
auth email. **No financial information anywhere in this section.** Results:
short `user_id`, code, current-cycle progress, active-entitlement badge.

## 6. Referral / entitlement detail

- referral **code** + status;
- **current cycle**: `qualified_in_cycle / required_referrals`, `cycle_index`,
  and the **pinned rule version** (so an operator can see why a user is on 4/5
  under V1 while V2 is active);
- **referrals list**: short `user_id` (or "deleted user" for de-identified
  qualified rows — Referral §14), `attribution_method`, `status`,
  `qualified_at` / `rejection_reason`. Never the referee's financial data;
- **grant history** from the immutable ledger: `rule_version`, `cycle_index`,
  **duration actually granted**, `granted_at`, resulting boundary;
- **current entitlement** from `user_entitlement_state`: `ends_at`, `status`.
  Provenance is read from the ledger, not from a mutable field on the state row
  (Referral §10).

## 7. Manual actions — all audited, all explicit

Via service-role routes calling the guarded RPCs:
- **Grant** `report_export_ad_free` for N days (`source = admin_grant`).
- **Extend** an active entitlement — same concurrency-safe UPSERT and stacking
  rule as referral rewards (Referral §11); no special path.
- **Revoke / shorten** an entitlement — **a separate, explicit action** with a
  **required reason**.
- **Reject** a pending referral (case A) or **reverse** a qualified one
  (case B) — §8.
- **Rotate** a user's referral code (abuse remedy; old code stops attributing
  going forward; past qualifications untouched).

### 7.1 Operation idempotency — **required** (r3)

Every mutating entitlement operation (**grant, extend, shorten, revoke**) carries
an **`operation_id`** — a UUID minted **once per operator intent** when the
confirm dialog opens, and **resent unchanged on every retry**. Without it an
Admin double-click, a network retry, a Next.js retry, or a reverse-proxy retry
could grant 7 days twice.

- **Same `operation_id` replayed** ⇒ **one** entitlement mutation, **one**
  immutable `entitlement_events` row, **one** audit row; subsequent replays
  return the stored result unchanged.
- **Different intentional operations** carry different ids and apply
  independently (two deliberate +7-day extensions = +14 days).
- Enforced server-side by `UNIQUE (entitlement_events.operation_id)` and the
  `ON CONFLICT DO NOTHING` claim (Referral §10.1–10.3) — never by UI disabling
  alone, which cannot survive a proxy retry.
- The UI still disables the confirm button while in flight, as defence in depth.

### 7.2 Reason field contract (r3)

Every manual action requires a `reason`:

- **plain text only** — no HTML, no markup, no structured payload;
- **bounded length: 4–500 characters**, validated **server-side** (not just in
  the browser);
- control characters stripped; stored as `text` and rendered escaped;
- rejected with a controlled 4xx if empty, too short, too long, or non-text.

Arbitrary large or structured operator blobs are not accepted.

Every mutation writes its audit row **in the same transaction** as the change, so
an un-audited change is impossible. Nothing is silently deleted.

## 8. Fraud review workflow (r2 — two distinct cases)

**Case A — pending/unqualified rejection:** referral `attributed → rejected` with
a reason. No progress counted, no grant existed.

**Case B — already-qualified fraud finding:** the immutable history is **not**
rewritten. The referral is marked `reversed` (its `qualified_at` retained), a
reversal row is appended to the ledger, and then the Admin decides, **as two
separate choices**:

1. whether to **decrement current-cycle progress** (never below zero, never
   across a completed cycle boundary — a completed cycle's grant stands); and
2. whether to **revoke/shorten the current remaining entitlement** (a distinct
   action with its own reason and audit row).

**Fraud marking never automatically shortens an entitlement, and consumed
historical ad-free time is never rewritten.**

Review queue lists **soft signals only** (qualification bursts, disposable-email
domains, create/delete/recreate patterns — Referral §8). Soft signals never
auto-reject. **No InstallId/device fingerprint appears here**: that signal is
deferred in V1 (Referral §8). Hard invariants (one-referrer, no-self,
exactly-once) are displayed as immutable facts, not editable fields.

## 9. Audit model — append-only, **de-identified** (r3)

`referral_admin_audit` (in `0083` — Referral §27):

| col | notes |
|---|---|
| `id` | uuid PK |
| `actor_admin_id` | the acting `admin_users` id |
| `action` | `grant \| extend \| revoke \| shorten \| reject_referral \| reverse_referral \| adjust_progress \| rotate_code \| rule_change` |
| `target_user_id` | **nulled on user purge** (§9.1) |
| `target_ref` | entitlement / referral / rule id |
| `operation_id` | the idempotency key (§7.1) |
| `reason` | bounded plain text (§7.2) |
| `before` / `after` | **allowlisted JSON only** (§9.2) |
| `created_at` | server now |

No Admin UPDATE or DELETE on audit rows.

### 9.1 Retention after user deletion

When a user is purged, audit retention must not become a PII backdoor. On purge:

- `target_user_id` is **set to NULL** (the row survives de-identified);
- any `before`/`after` field carrying an identifier is scrubbed to `null`;
- **no email, no phone, no referral code, and no `auth.users` UUID** is retained
  anywhere in the audit after purge.

This is wired into the same `purge_user_data(uuid)` saga as the rest (Referral
§15), so deletion has exactly one authority.

### 9.2 `before` / `after` are an allowlisted schema, not object dumps (r3)

Free-form snapshots are forbidden — they are how PII leaks into audit tables. Only
these keys may ever appear, all non-identifying:

`entitlement_type`, `status`, `ends_at`, `duration_days`, `rule_id`,
`rule_version`, `required_referrals`, `reward_days`, `repeatable`, `is_active`,
`cycle_index`, `qualified_in_cycle`, `referral_status`, `rejection_reason`.

Anything not on this list is dropped server-side before the row is written. The
allowlist is validated in `referral-validation.mjs` and asserted by test.

## 10. Metrics — product funnel, not billing

Report export attempts; ad impressions / dismissals / load-failures (Report-Ads
§18 vocabulary — **no** `report_ad_completed`, **no** reward terms); active
ad-free entitlements; referrals attributed / qualified / rejected / reversed;
qualified-invite conversion; rewards granted.

**AdMob remains the authority for ad revenue and impression reporting.** No AdMob
revenue-API integration in V1; no shadow billing system. Directional labelling is
mandatory — never call ad views or referral events "conversions", "redemptions"
or "sales" (carried from the Coupons analytics trust rule).

*Carried C6 note:* Coupons admin returns per-item totals with no cross-item
headline endpoint; decide up front here whether a global headline is
server-computed or client-summed, to avoid repeating that gap.

## 11. Routes, validation, error mapping

All under `admin/app/api/…`, verb-only exports, `requireAdmin()` first:
`GET/POST/PATCH /api/referral-rules` (versioning on threshold change) ·
`GET/PATCH /api/report-ads-config` (behaviour only; no `enabled`; no credentials) ·
`GET /api/referral-users?query=` · `GET /api/referral-users/[id]` ·
`POST /api/entitlements/grant|extend|revoke` ·
`POST /api/referrals/reject|reverse` · `POST /api/referral-progress/adjust` ·
`POST /api/referral-codes/rotate` · `GET /api/referral-metrics` ·
`GET /api/referral-audit`.

Validation returns `{ok:false, errors:[{field,error}]}` → controlled 4xx via
`safeErrorBody`. Auth failures use the accepted middleware-redirect +
`adminAuthErrorResponse` semantics. No service-role material in any response body
(asserted by test).

## 12. Tests (Admin)

`admin/tests/referral-admin.test.mjs` (node:test via `npm run test:auth`) plus a
real `next build`:

- auth matrix with **`redirect: 'manual'`** (the C5 finding: Node `fetch` follows
  redirects and would report a 307 as a 200): unauthenticated → 307 `/login`;
  non-admin → 307 `/not-authorized`; admin → 200.
- rule threshold edit → **new version**; in-progress cycles keep the pinned rule;
  earned grants unchanged.
- manual grant/extend → entitlement UPSERT + `entitlement_events` row + audit row,
  **all in one transaction** (induced mid-failure rolls back all three).
- **E. concurrent duplicate `operation_id` → exactly one extension.**
- **F. the same `operation_id` retried → the same stored result**, no second
  mutation, no second audit row.
- **G. two distinct `operation_id`s → two intentional extensions** (+14 days).
- **reason validation**: empty / <4 / >500 chars / HTML / non-text → controlled
  4xx, **no DB write**.
- **audit `before`/`after` allowlist**: a non-allowlisted key is dropped
  server-side and never persisted.
- **audit de-identification on purge**: `target_user_id` nulled; no email, phone,
  code or auth UUID remains.
- **revoke/shorten is a separate action** from fraud reversal; each audited.
- reversing a qualified referral does **not** shorten an entitlement by itself.
- progress adjustment cannot go below zero or cross a completed cycle.
- validation rejects bad rule/config with 4xx and **no DB write**.
- **no service-role leak** in any response (scan the built bundle — C3 precedent).
- **no `report_ads_config` table or route exists**; the Report Ads screen exposes
  no editable field, no credential, and no ad-unit write path.
- rule deactivation: new attribution rejected; pinned in-progress cycle still
  completes; no progress destroyed (Referral §19.1).
- metrics totals match server tables.

## 13. Release / deployment requirements

- Admin needs its **own deploy/build gate** (`npm run build` + `npm run
  test:auth`), folded into **9T** with Edge/secrets, since Admin and the referral
  RPCs share the same prerequisite (**`0083` applied** — there is no `0084`).
- **Production `admin/.env.local` is production-scoped and must never be edited**
  for validation; staging validation uses **process-scoped credentials** (the C5
  runner pattern) with a fail-closed project-ref assertion before any mutation.
- Admin is **not** gated by `enable_referrals` / `enable_report_ads` — operators
  configure before user enablement.
- **Kill-switch reality (Report-Ads §15, Referral §20):** server-side rule
  disable is immediate for new referral mutations; client-side flags require
  catalog sync + app restart, so the Admin UI must not present them as instant.

## 14. Closed-domain isolation

Admin reads/writes only referral, progress, entitlement, ledger, rule, config and
audit tables. It touches **no** financial, planning, CAS, capture, coupon or
backup contract. Any discovered need to touch a closed contract is reported
before change.
