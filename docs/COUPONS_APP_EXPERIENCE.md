# Coupons / Offers — App Experience Specification

Status: SPEC r2 (revised per final design review; implementation-ready, pre-implementation)
Scope: mobile UI/UX, sync + local cache (Drift v31), flag gating, coupon code / direct-link behavior, display categories & tags, contextual on-device matching, analytics, localization/accessibility, tests, staging validation.
Companion: `docs/COUPONS_ADMIN_SYSTEM.md` (server/admin side; r2 — tag/category/country/storage/authority models defined there are authoritative).
Baseline: tree `1c9cc6bd`, Drift v30, existing demo feature at `app/lib/features/coupons/` (route `/coupons` at `app/lib/core/router/app_router.dart:167`, dashboard teaser at `app/lib/features/dashboard/dashboard_screen.dart:1527`).

Revision log (r2): `coupon_local_state` table REMOVED — V1 has no favorites/saves/dismissals (deferred to V1.1); impression dedup is session-scoped in-memory; analytics events finalized (`impression`, `detail_view`, `code_copy`, `cta_click`) with a concrete rebuild-safe dedup rule; tags/display categories consumed from the normalized server model (denormalized into the cache snapshot); country semantics = empty set ⇒ global (no `'ALL'` literal); v30→v31 migration documented explicitly.

## 0. What changes vs the demo

The current feature renders a **hardcoded sample catalog** (`_sampleCoupons` in `coupons_providers.dart`) filtered by the user's settings country (using a demo-only `'ALL'` literal). This track replaces the data source with the server catalog while keeping the existing UI shell (screen, cards, teaser). The demo model, its `'ALL'` country literal, and its sample data are all superseded.

## 1. Data flow (device side)

```
CatalogSyncService (existing periodic/startup sync)
  → GET catalog-coupons (full active snapshot; anon)
    → atomic replace of Drift `remote_coupons` (v31 cache table)
      → RemoteCouponsDao (catalog_daos.dart)
        → couponsProvider (rewritten: reads Drift, never network — rule 1)
          → CouponsScreen / dashboard teaser / detail sheet
```

- Fetch piggybacks the existing sync cadence exactly where `catalog-campaigns` is fetched today (`catalog_sync_service.dart:115`); failure is non-fatal (keep last cache; empty cache ⇒ empty state).
- **Offline-first:** the screen always renders from the cache; the live-predicate is re-checked locally (§5) so an expired offer never renders from a stale cache.

## 2. Local schema — Drift **v31** (additive, ONE table)

**V1 adds exactly one table.** There is **no `coupon_local_state` table** — V1 ships no favorites/saves/dismissals, and analytics dedup is session-scoped in memory (§8), so no second persistent business-state table is justified.

```sql
-- Server catalog cache (refetchable content; NOT part of business backup).
-- Denormalized snapshot of the server's normalized model: labels and tag
-- lists are embedded as fetched — the SERVER is the authority; this is cache.
CREATE TABLE IF NOT EXISTS remote_coupons (
  id             TEXT PRIMARY KEY,          -- server UUID
  slug           TEXT NOT NULL,
  partner_name   TEXT NOT NULL,
  title_ar       TEXT NOT NULL,
  title_en       TEXT,
  description_ar TEXT NOT NULL,
  description_en TEXT,
  redemption_type TEXT NOT NULL,            -- 'code' | 'link'
  code           TEXT,
  partner_url    TEXT,
  display_category_key TEXT NOT NULL,
  display_category_label_ar TEXT NOT NULL,
  display_category_label_en TEXT,
  tags_json      TEXT NOT NULL DEFAULT '[]',   -- [{key,label_ar,label_en}], server order
  spend_hints_json TEXT NOT NULL DEFAULT '[]', -- [category_key,…] ranking hints only
  country_codes_json TEXT NOT NULL DEFAULT '[]', -- [] ⇒ GLOBAL (canonical, §5)
  accent_hex     TEXT,
  image_url      TEXT,                      -- composed public URL, nullable
  featured       INTEGER NOT NULL DEFAULT 0,
  priority       INTEGER NOT NULL DEFAULT 0,
  valid_from     TEXT NOT NULL,             -- ISO8601 UTC
  valid_until    TEXT,                      -- NULL = open-ended
  terms_ar       TEXT,
  fetched_at     TEXT NOT NULL
);
```

### 2.1 v30 → v31 migration (explicit)

- `app/lib/data/db/app_database.dart`: `_targetSchemaVersion` 30 → **31**.
- `onCreate`: includes the `remote_coupons` DDL (fresh installs land on v31).
- `onUpgrade` gains `if (from < 31) { CREATE TABLE IF NOT EXISTS remote_coupons(...); }` — **additive only**: no data transform, no rewrite of any existing table, no index changes elsewhere.
- The existing fail-closed downgrade guard is unchanged and needs no special case (an older binary opening a v31 file fails closed exactly as it would for any newer version).
- Migration tests: v30 file → open at v31 → table exists + all pre-existing data intact; fresh-create parity; downgrade still fails closed (§10).

### 2.2 Backup exclusion (explicit)

`remote_coupons` is **excluded from the business snapshot** — snapshot v4 and crypto envelope v3 are untouched; the restore pipeline is untouched. After any restore, the cache simply refetches. This is the deliberate isolation decision (companion doc §12): the backup format contract is not reopened by Coupons.

## 3. Feature gating & entry points

Everything is gated by the existing remote flag **`enable_coupons`** (seeded `false`; SHA-256 rollout bucketing already implemented):

- `couponsEnabledProvider` (new) exposes the flag; when **off**: the dashboard teaser renders nothing, entry points are hidden, and `CouponsScreen` shows a neutral empty state if reached.
- When **on**: (a) dashboard teaser (top-3 via `dashboardCouponsProvider`, "المزيد" → `context.push('/coupons')` — wiring unchanged), (b) the `/coupons` screen.
- Rollout: staging QA → `rollout_percent` ramp → 100%. Kill = flag off, no build needed.
- Synergy (no new code): a `growth_campaigns` banner can target `action_route: '/coupons'`.

## 4. Screen & interaction spec

**CouponsScreen** (`/coupons`, exists — restyled to server data):
- Header (existing section-hero pattern), then **filter chips**: `الكل` + display-category chips (from cached categories present, ordered by the server's deterministic order) + tag chips (rendered as `#label_ar`, from cached tags present, server order, capped 8 with overflow sheet). Single-select; selection is session-only state.
- **Featured carousel** (featured, by priority) then the vertical list (contextual order, §7). Card = existing visual language: accent band / cached network image (accent fallback), partner name, title_ar, display-category chip, expiry line — `تنتهي خلال N أيام` when ≤7 days remain, `مفتوح` when open-ended.
- Tap → **detail sheet**: full description_ar, terms_ar (collapsible), validity dates, tag chips, then the redemption CTA (§5). *(No save/bookmark and no hide/dismiss actions in V1 — see §12 deferred list.)*
- Empty states: flag-off / no live coupons / no filter match — friendly Arabic copy. Loading = existing shimmer idiom. Sync failure renders cache silently.
- `/coupons?highlight={slug}`: scroll-to + auto-open the detail sheet (enables campaign/notification targeting now; inbound universal links remain out of scope).

## 5. Redemption behavior (code / direct link)

Client-side re-validation first: a coupon renders/acts only if `valid_from <= now && (valid_until == null || valid_until > now)` — the same live-predicate as server RLS.

**Country eligibility (canonical semantics):** `countryCodes.isEmpty || countryCodes.contains(userSettingsCountry)`. The empty set means globally available; there is no `'ALL'` literal. Codes are ISO-3166-1 alpha-2 uppercase, matching the admin/DB/Edge contract exactly.

- **`code` type:** primary CTA `انسخ الكود` → `Clipboard.setData` + haptic + snackbar `تم نسخ الكود` → then emit `code_copy` (fire-and-forget, §8; **emitted after the copy succeeds and never awaited** — analytics can never block or fail redemption). If `partner_url` present, secondary CTA `افتح الموقع` → `url_launcher` external → emit `cta_click`. Copy never auto-opens the site.
- **`link` type:** single primary CTA `احصل على العرض` → opens `partner_url` externally → emit `cta_click`.
- Failure paths: launch failure → snackbar `تعذّر فتح الرابط`; analytics failures are always swallowed.

## 6. Session state (in-memory only — no persistence)

V1 keeps **zero** persistent per-coupon user state. A single session-scoped object (Riverpod `Provider`-held, process lifetime) tracks:
- `Set<String> impressedCouponIds` — the impression-dedup set (§8);
- `Set<String> detailViewedCouponIds` — detail_view dedup (per session);
- the active filter chip selection.
Nothing here survives restart, by design. If V1.1 approves Favorites, persistence arrives with that feature (§12) — not before.

## 7. Contextual on-device matching (privacy contract)

Per PRODUCT_SPEC (§F19/§506): **matching is 100% on-device; no financial data leaves the device.**

- Input A: the coupon's `spend_hints_json` — optional financial-category-key hints authored by the admin (companion doc §2.4). Hints are non-authoritative: unknown/stale keys simply never match.
- Input B: local 30-day spend totals per financial category from the existing reports aggregates (read-only query; no new financial code).
- Ranking (pure function, unit-tested): `featured DESC` → `hintBoost DESC` (any hint key ∈ user's top-3 spend categories → tiers 2/1/0) → `priority DESC` → `valid_until ASC NULLS LAST` → stable id. Coupons with no hints rank purely by featured/priority — the feature is fully functional with hints absent.
- Country eligibility (§5) applies before ranking; the teaser (top-3) uses the same ranking.
- Ranking inputs/outputs are never transmitted; analytics events carry no category/spend context.

## 8. Analytics (V1 final: consent-gated, anonymous, fire-and-forget)

**Event set (authoritative): `impression`, `detail_view`, `code_copy`, `cta_click`** → `record_coupon_event(coupon_id, event)` RPC (authenticated-only; companion doc §3). No `save` event exists in V1.

- **Gating:** emitted only when Supabase is configured AND a signed-in session exists AND the existing cloud-consent state allows metrics (reuse of the existing consent surface — no new consent UI). Otherwise events are dropped silently. No queue, no outbox, no retries: coupon analytics are best-effort by design.
- **Never blocking:** every emission is post-action and unawaited with a short client timeout; failure is swallowed. Redemption (copy/launch) completes regardless.
- **Impression dedup rule (concrete, rebuild-safe):** an `impression` fires for a coupon at most **once per app session**, when its card first reports ≥50% viewport visibility for ≥300 ms in the list/teaser/carousel. The dedup set lives in the session-state provider (§6), NOT in widget state — so Flutter rebuilds, tab switches, scroll re-entries, and navigation cannot re-fire it. (`detail_view` dedups the same way per session; `code_copy`/`cta_click` are explicit user actions and are never deduped.)
- Nothing else is sent: no install id, no country, no spend data, no code value. Merchants receive at most anonymous daily aggregates; **no merchant access to user financial data.**

## 9. Localization & accessibility

- Content: Arabic-first (`*_ar` required server-side); `*_en` used when the app locale is English and non-null, else Arabic fallback. Category/tag labels come from the cached server labels (`label_ar`/`label_en`) — never hardcoded.
- UI strings: new keys in the ARB files + `flutter gen-l10n` (gate rule). The demo's inline strings migrate to ARB.
- RTL default; chips/carousel verified both directions.
- Accessibility: Semantics labels on cards (`عرض من {partner}: {title}`) and CTAs; copy announces `تم نسخ الكود` to screen readers; targets ≥ 44px; accent used as trim only (text always on standard surfaces — contrast-safe); dynamic type respected.

## 10. Tests

- **Unit:** ranking matrix (featured/hint-boost/priority/urgency; hints absent ⇒ pure featured/priority; unknown hint keys ⇒ no boost); country eligibility (**empty ⇒ global**, ISO match, mismatch); live-predicate re-check; snapshot→cache mapper (embedded category/tags/hints/countries JSON, nullables, bad rows skipped fail-soft).
- **DB:** v31 migration tests per §2.1 (upgrade, fresh, data-intact, downgrade fail-closed).
- **Sync:** fetch → atomic replace (old rows gone); fetch failure keeps prior cache.
- **Widget:** flag-off hides teaser + empty screen; flag-on renders cache; code-type sheet copies (mock clipboard) + snackbar; link-type single CTA; `highlight` param auto-opens; **impression fires once across forced rebuilds/scroll re-entry** (pump-driven visibility, session-set assertion).
- **Analytics:** consent-off ⇒ zero RPC calls; consent-on ⇒ correct event names; failure swallowed (fake client throwing) with redemption still completing.
- **Gate:** all inside `tools/ci_gates.sh` (13/13 before commit); `flutter analyze` clean; l10n freshness stage passes.

## 11. Staging validation (app side, on `bdhqjijscwdzqwqanygv`)

Against the admin-seeded state (companion doc §11): flag off → no surface; flag on → catalog appears after sync with category/tag chips in server order; the global (empty-countries) coupon visible under any settings country, the `{SA}` coupon only under SA; scheduled appears post-boundary; kill-switched disappears next sync; expired-in-cache never renders; the four events land in `coupon_metrics_daily` (and impressions don't inflate on scroll/rebuild); image renders + accent fallback after object deletion; offline launch renders cache; restore-then-relaunch refetches the cache (backup exclusion proof).

## 12. V1 scope boundary & deferred V1.1

**V1 ships:** server catalog + sync + cache (one v31 table), flag-gated screen/teaser, display-category & tag filter chips, code/link redemption, on-device hint ranking, 4-event consent-gated analytics, l10n/a11y, tests, staging validation.

**Deferred to V1.1 (documented, NOT implemented):** Favorites/saves; hide/dismiss per coupon; "new" badge (needs persistent first-seen); any persistent per-coupon local state (arrives only with Favorites); a `save` analytics event (follow-up migration if approved); inbound universal/deep links.

## 13. Dependencies & explicitly untouched systems

Touches: router (existing `/coupons` route + `highlight` param), dashboard teaser (flag gate), `CatalogSyncService` (+1 fetch), `catalog_daos.dart` (+1 DAO), Drift v31 (additive, one table), l10n ARB, feature flags (existing key), `url_launcher` (add dependency if absent).
Explicitly untouched (contracts unmodified): Money, financial sync, Planning currency, CAS/conflict handling, capture pipeline, backup snapshot format (v3/v4 — `remote_coupons` excluded by design, §2.2). Financial categories are referenced only as optional hint **strings**; the Coupons feature remains fully understandable and functional if that taxonomy evolves. Any genuine need to modify a protected system stops work and is reported first.
