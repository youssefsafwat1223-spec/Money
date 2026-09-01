# Qirsh Savings / Smart Coupons + Affiliate — implementation status

**As of 2026-09-01.** Written against the code, not against the plan. Where the
2026-08-30 plan and the repository disagree, the repository is right and this
file says so.

**Nothing here is deployed, and every user-facing surface is behind a flag that
is seeded OFF.** Engineering completeness and production rollout are different
things; this file only claims the first.

---

## Phase status

| Phase | State | Notes |
|---|---|---|
| 0 — merchant_keywords versioning | **DONE** | `0093`. The defect was real and re-confirmed at HEAD before fixing. |
| 1 — merchant-aware curated offers | **DONE** | `0094`, `0095`, Drift v34, resolver, ranking, UI, admin. |
| 2 — affiliate ingestion | **DONE, fixture-backed** | `0096`, provider-neutral adapter contract, worker, review/publish. No network contracted. |
| 3 — attribution | **DONE, fixture-backed** | `0097`, click/status/postback endpoints, device gateway, admin commission, polling reconciliation. Signature scheme is a seam awaiting a real provider. |
| 4 — savings | **DONE** | Drift v35, exact minor-unit math, local ledger, confirm flow, breakdown screen. |
| 5 — share to Qirsh | **DONE, unverified on device** | Android + iOS routing, separate stores, drain, domain resolution. |
| 6 — Safari extension | **CLOSED: DEFER** | Two independent reviews. See `PHASE6_SAFARI_EXTENSION_DECISION.md`. |

---

## Schema

**Server:** `0093` merchant_keywords versioning · `0094` catalog_merchants +
catalog_merchant_aliases + the frozen key functions · `0095` coupon offer
economics · `0096` affiliate core · `0097` affiliate attribution. Every one has a
rollback file; migration lint is green.

**Client:** Drift **v35**. v34 added the merchant catalog cache and the coupon
economics columns; v35 added `affiliate_click_receipts` and
`local_offer_savings`. Both bumps are additive and **forward-only** — a v34
binary cannot open a v35 database, so recovery is a flag, the kill switch, a
hotfix or a forward migration, never shipping an older build.

The two v35 tables landed in ONE version deliberately: each bump forces a sweep
of every version pin in the repository (fourteen files at v34, across Dart, Node
and docs), and doing that twice for two tables that ship together is how the
v32/v33 pin fallout happened. The sweep now runs first.

---

## Flags — all seeded OFF, all independent

`enable_coupons` (master) · `enable_offers_merchants` ·
`enable_offers_personalization` · `enable_affiliate_links` ·
`enable_savings_claims`.

Independent on purpose. One flag that disables everything is an outage, not a
kill switch: the generic catalog must keep working when merchant awareness is
switched off, and every CTA must still open when tracking is.

---

## The decisions that shaped this, and why

**Exact reviewed aliases, never fuzzy matching.** A false category chip is
user-correctable; "you shop at X constantly" derived from someone's bank messages
when they do not is a trust breach in a finance app. Recall is an
alias-coverage problem solved by adding data.

**A frozen key contract in two languages.** The device must resolve offline so it
cannot ask the server for a key; a unique index expression cannot call Dart.
Duplication is forced, so both implementations are generated from one table file
and pinned to expectations computed by the real PostgreSQL function.

**Digits are retained in the key.** Stripping them — as the three legacy
normalizers do — produces stored, cross-user, permanent false merges:
`7-ELEVEN` → `-ELEVEN`, `360 MALL` → `MALL`, `"123"` → the empty key.

**Boilerplate stripping lives OUTSIDE the key.** A lexicon inside it would make
every new acquirer prefix a full key-version migration. Outside, it only ever
affects the query string and can never corrupt stored identity — and the
database refuses to store an alias the pipeline would strip, so the two cannot
disagree.

**Nothing publishes itself.** `ingestOffers` has no code path producing
`published`; making it automatic would take a schema change, not a config flag.

**Polling is a backstop, not a fallback.** The conversions run is separate from
the offers run, with its own cursor and its own ledger kind, and it goes through
the same transition rule as the webhook — a poll and a push are two views of one
state machine. It runs for push networks too: webhooks are lost, and a status
update that never arrives leaves a user's saving pending forever. A network with
no polling API records a SKIPPED run, because "no API" and "no conversions" are
different facts and reporting them identically is how a broken poll hides.

**A click has no user, no IP and no user-agent.** The network gets a random
sub-id; the device keeps the only copy of the claim token. A wrong token is
indistinguishable from a missing click, so the status endpoint is not an oracle.

**Commission is never savings.** Different money, different owner. It appears in
exactly one admin page, is not returned to the device, and the savings math has
no parameter that could carry it.

**Savings abstain rather than invent.** No structured value, no currency, a
different currency, a basket below the minimum, a pending conversion, an approved
conversion of unknown size — all produce nothing, not zero. Zero reads as "you
saved nothing", which is a different and false statement.

---

## What is NOT done, and cannot be here

**External, blocking:**

- **No affiliate network is contracted.** Phases 2 and 3 run against a
  deterministic fixture adapter. The postback signature check is a per-network
  switch with no default-allow branch, so a real provider is an added case.
  Live provider validation is impossible until an agreement exists.
- **No physical device QA.** No Android device has ever been attached to this
  machine; iOS additionally needs Apple portal access that requires a 2FA code
  from an unavailable client. The Android and iOS share routing, and the whole
  v34→v35 migration on a real database, are unverified on hardware.
- **Edge Functions are not deployed.** The Supabase Management API returns 403;
  raised with Support. `affiliate-sync`, `prepare-affiliate-click`,
  `affiliate-click-status` and `affiliate-postback` exist and type-check but have
  never run against the live project.
- **Production migrations not applied.** `0093`–`0097` are source-only. The
  deployed ledger must be re-confirmed against production before any of them run.

**Known gaps, in-repo:**

- **No JVM test source set for Android**, so the Kotlin share router and the SMS
  prefilter are covered by structural assertions over their source rather than by
  execution. Weaker than running them, and recorded as such.
- **The iOS share extension is still named "إضافة رسالة بنك"**, which is now
  inaccurate for a URL share. Renaming is a product decision, deliberately left
  open rather than decided unilaterally.
- **Three OPEN egress findings** recorded in `egress_inventory_test.dart`:
  `record_metric` has no consent gate, `accounts_backfill`'s `set_default_account`
  gates on transport rather than consent, and `SupabaseEngagementRecorder` is
  unwired. All predate this work; all are now visible rather than invisible.
