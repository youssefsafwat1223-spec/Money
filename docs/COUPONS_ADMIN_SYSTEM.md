# Coupons / Offers — Admin System Specification

Status: SPEC r2 (revised per final design review; implementation-ready, pre-implementation)
Scope: server schema, migrations, RLS, Storage, Admin Dashboard, scheduling, analytics, tests, staging validation — for the Qirsh Coupons/Offers domain.
Companion: `docs/COUPONS_APP_EXPERIENCE.md` (mobile side).
Baseline: tree `1c9cc6bd`, server migrations `0001→0080`, Drift v30. Coupons introduces server migrations **0081** (catalog/storage/RLS domain) and **0082** (analytics RPC/metrics hardening) and client schema **v31** (companion doc §2). Migration files are NOT created until implementation is approved.

Revision log (r2): normalized tag model (`coupon_tags` + `coupon_tag_links`, no `tags[]` array); Coupon-owned display categories decoupled from financial categories (`coupon_categories` + optional spend-hint field); country targeting canonicalized (empty set = global, ISO codes); full Storage security contract; explicit admin mutation authority chain; analytics event set finalized (`impression`, `detail_view`, `code_copy`, `cta_click`); V1 local-state reduction reflected in staging/tests.

## 0. Product contract (from PRODUCT_SPEC.md F19 / MONETIZATION_PLAN.md §7)

- Contextual, privacy-respecting offers: **matching runs on-device**; the server ships a *public* catalog and never receives financial data for targeting.
- Coupons are free for all users (not paywalled).
- Two redemption shapes: **code** (copy + open partner site) and **direct link** (tracked affiliate URL, no code).
- Filterable by Coupon-owned display categories and tags; Arabic-first content with English fallback.
- The existing demo (`app/lib/features/coupons/_sampleCoupons`) is replaced by this server-driven catalog.

## 1. Architectural placement

Follows the established remote-catalog content pattern (architecture rules 1–2: UI reads only Drift; remote catalog is content only, logic stays in Dart):

```
Admin browser (authed session; NEVER holds service_role)
  → Admin server API route (session check + public.admin_users membership)
    → service-role DB/Storage operation (server-side only)
      → Supabase tables (RLS: anon SELECT live-only; no anon/authenticated writes)
        → Edge fn `catalog-coupons` (full active snapshot, like catalog-campaigns)
          → CatalogSyncService (app) → Drift cache `remote_coupons` (v31)
            → Riverpod providers → UI (existing /coupons route + dashboard teaser)
```

Precedent files: `supabase/migrations/0011_growth_campaigns.sql`, `supabase/functions/catalog-campaigns/index.ts`, `app/lib/data/catalog/catalog_sync_service.dart:115`, `admin/app/(admin)/campaigns/page.tsx`, `docs/ADMIN_AUTHORIZATION_RUNBOOK.md`.

## 2. Database schema — migration `0081_coupons.sql`

### 2.1 `coupon_categories` — Coupon-OWNED display classification

The Coupon domain owns its display taxonomy. It is deliberately **not** the
transaction-category domain: financial categories may evolve without touching
Coupons, and vice versa.

```sql
CREATE TABLE IF NOT EXISTS coupon_categories (
  key        TEXT PRIMARY KEY,                -- normalized: ^[a-z0-9_]{2,32}$
  label_ar   TEXT NOT NULL,
  label_en   TEXT NULL,
  sort_order INTEGER NOT NULL DEFAULT 0,
  is_active  BOOLEAN NOT NULL DEFAULT true,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT coupon_categories_key_shape CHECK (key ~ '^[a-z0-9_]{2,32}$')
);
ALTER TABLE coupon_categories ENABLE ROW LEVEL SECURITY;
CREATE POLICY coupon_categories_public_select ON coupon_categories
  FOR SELECT USING (is_active = true);
-- Writes: none for anon/authenticated (admin via service_role routes).
```

Admin-managed (create/rename-labels/reorder/deactivate). No initial list is
hardcoded in this spec; the launch set is seeded by the admin through the UI.
Deterministic ordering everywhere = `sort_order ASC, key ASC`.

### 2.2 `coupon_tags` + `coupon_tag_links` — normalized tag model

Tags are a first-class normalized domain (NOT an array column): admin search,
create, attach/detach, uniqueness, bilingual labels, deterministic ordering,
and future per-tag analytics all hang off `tag.id`.

```sql
CREATE TABLE IF NOT EXISTS coupon_tags (
  id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  key        TEXT NOT NULL UNIQUE,            -- normalized: lower, trimmed,
                                              -- spaces→'_', ^[a-z0-9_؀-ۿ]{2,32}$
  label_ar   TEXT NOT NULL,                   -- display, e.g. shown as #مطاعم
  label_en   TEXT NULL,
  sort_order INTEGER NOT NULL DEFAULT 0,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS coupon_tag_links (
  coupon_id UUID NOT NULL REFERENCES coupons(id)     ON DELETE CASCADE,
  tag_id    UUID NOT NULL REFERENCES coupon_tags(id) ON DELETE CASCADE,
  PRIMARY KEY (coupon_id, tag_id)
);
ALTER TABLE coupon_tags      ENABLE ROW LEVEL SECURITY;
ALTER TABLE coupon_tag_links ENABLE ROW LEVEL SECURITY;
CREATE POLICY coupon_tags_public_select      ON coupon_tags      FOR SELECT USING (true);
CREATE POLICY coupon_tag_links_public_select ON coupon_tag_links FOR SELECT USING (true);
-- Writes: none for anon/authenticated (admin via service_role routes).
CREATE INDEX IF NOT EXISTS idx_coupon_tag_links_tag ON coupon_tag_links(tag_id);
```

Normalization is enforced in the admin API route (lower/trim/collapse
whitespace to `_`) and re-checked by the key CHECK. The UI renders
`#'+label_ar`; persistence and analytics always use `key`/`id`.
Deterministic tag ordering = `sort_order ASC, key ASC`.

### 2.3 `coupons`

```sql
CREATE TABLE IF NOT EXISTS coupons (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  slug          TEXT NOT NULL UNIQUE,          -- stable handle for links/analytics
  partner_name  TEXT NOT NULL,
  title_ar      TEXT NOT NULL,
  title_en      TEXT NULL,
  description_ar TEXT NOT NULL,
  description_en TEXT NULL,
  -- Redemption: exactly one of code / direct link drives the primary CTA.
  redemption_type TEXT NOT NULL CHECK (redemption_type IN ('code','link')),
  code          TEXT NULL,                     -- required when redemption_type='code'
  partner_url   TEXT NULL,                     -- affiliate/partner URL (https only)
  -- Display classification: Coupon-owned (§2.1). NOT the financial taxonomy.
  display_category_key TEXT NOT NULL REFERENCES coupon_categories(key),
  -- OPTIONAL financial-matching hints (§2.5): stable financial category keys
  -- used ONLY by on-device ranking. Hints, never authority; empty = no boost.
  spend_hint_category_keys TEXT[] NOT NULL DEFAULT '{}',
  -- Country targeting (§2.6): EMPTY = globally available (canonical);
  -- non-empty = ISO-3166-1 alpha-2 allowlist.
  country_codes TEXT[] NOT NULL DEFAULT '{}',
  -- Presentation
  accent_hex    TEXT NULL CHECK (accent_hex IS NULL OR accent_hex ~ '^#[0-9A-Fa-f]{6}$'),
  image_path    TEXT NULL,                     -- storage object path (§4)
  featured      BOOLEAN NOT NULL DEFAULT false,
  priority      INTEGER NOT NULL DEFAULT 0,
  -- Scheduling
  valid_from    TIMESTAMPTZ NOT NULL DEFAULT now(),
  valid_until   TIMESTAMPTZ NULL,              -- NULL = open-ended
  is_active     BOOLEAN NOT NULL DEFAULT true, -- admin kill-switch
  -- Terms
  terms_ar      TEXT NULL,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT coupons_code_shape CHECK (
    (redemption_type = 'code' AND code IS NOT NULL AND length(trim(code)) > 0)
    OR (redemption_type = 'link' AND partner_url IS NOT NULL)
  ),
  CONSTRAINT coupons_url_https CHECK (
    partner_url IS NULL OR partner_url LIKE 'https://%'
  ),
  CONSTRAINT coupons_country_codes_shape CHECK (
    country_codes <@ ARRAY[]::text[] OR NOT EXISTS (
      SELECT 1 FROM unnest(country_codes) c WHERE c !~ '^[A-Z]{2}$'
    )
  )
);

ALTER TABLE coupons ENABLE ROW LEVEL SECURITY;
CREATE POLICY coupons_public_select ON coupons FOR SELECT USING (
  is_active = true
  AND valid_from <= now()
  AND (valid_until IS NULL OR valid_until > now())
);
CREATE INDEX IF NOT EXISTS idx_coupons_live
  ON coupons (is_active, featured DESC, priority DESC, valid_from)
  WHERE is_active = true;
CREATE INDEX IF NOT EXISTS idx_coupons_display_category
  ON coupons (display_category_key);
CREATE TRIGGER trg_coupons_updated_at BEFORE UPDATE ON coupons
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();
```

(If the `unnest`-in-CHECK form is rejected by the linter at implementation
time, the equivalent is a small IMMUTABLE validator function — behavior, not
shape, is the contract: every element must match `^[A-Z]{2}$`.)

### 2.4 Display classification vs financial matching — the separation

- `display_category_key` → **Coupon-owned** taxonomy (§2.1). Drives chips,
  grouping, admin filtering. Never consults financial data.
- `spend_hint_category_keys` → **optional targeting hints** naming stable
  financial category keys (`'restaurants'`, `'groceries'`, …). Consumed ONLY
  by the on-device ranking (companion doc §7). If the financial taxonomy
  evolves, stale hints degrade to "no boost" — nothing breaks, and the Coupons
  feature remains fully understandable without them.
- No financial history is ever sent to the server for matching; hints flow
  one way (server → device) as static catalog content.
- A plain array (not a mapping table) is deliberate here: hints have no
  labels, no admin CRUD beyond a multi-select, and no server-side analytics —
  none of the reasons that justify the normalized tag model apply.

### 2.5 Country targeting semantics (canonical)

**Empty `country_codes` array ⇒ globally available.** Non-empty ⇒ the coupon
is eligible only where `user_country ∈ country_codes` (ISO-3166-1 alpha-2,
uppercase). There is no `'ALL'` literal anywhere (the demo's `'ALL'` retires
with the demo). The same rule is implemented identically in: the admin editor
(explicit "متاح في جميع الدول" toggle ⇔ empty set), the DB CHECK, the Edge
snapshot (verbatim passthrough), and client eligibility
(`countries.isEmpty || countries.contains(userCountry)`).

## 3. Analytics — migration `0082_coupon_metrics.sql`

Aggregate-only, anonymous, write-only-through-RPC (mirrors `record_metric` /
0080 hardening):

```sql
CREATE TABLE IF NOT EXISTS coupon_metrics_daily (
  day         DATE NOT NULL,
  coupon_id   UUID NOT NULL REFERENCES coupons(id) ON DELETE CASCADE,
  event       TEXT NOT NULL CHECK (event IN
                ('impression','detail_view','code_copy','cta_click')),
  count       BIGINT NOT NULL DEFAULT 0,
  PRIMARY KEY (day, coupon_id, event)
);
ALTER TABLE coupon_metrics_daily ENABLE ROW LEVEL SECURITY;
-- No anon/authenticated SELECT or writes; admin reads via service_role routes.

CREATE OR REPLACE FUNCTION record_coupon_event(p_coupon_id UUID, p_event TEXT)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF p_event NOT IN ('impression','detail_view','code_copy','cta_click') THEN
    RAISE EXCEPTION 'unknown coupon event';
  END IF;
  INSERT INTO coupon_metrics_daily(day, coupon_id, event, count)
  VALUES (current_date, p_coupon_id, p_event, 1)
  ON CONFLICT (day, coupon_id, event) DO UPDATE
    SET count = coupon_metrics_daily.count + 1;
END $$;
REVOKE ALL ON FUNCTION record_coupon_event(UUID, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION record_coupon_event(UUID, TEXT) TO authenticated;
```

**V1 event set (authoritative): `impression`, `detail_view`, `code_copy`,
`cta_click`.** There is no `save` event (Favorites are V1.1; if approved later
the event is added by a follow-up migration, not pre-created).

Privacy contract: the RPC carries only `(coupon_id, event)` — no install id,
no country, no spend context, no code value. Partners/merchants receive at
most these anonymous daily aggregates; **no merchant ever accesses user
financial data.** Client emission is consent-gated, fire-and-forget, and can
never block redemption (companion doc §8, incl. the impression dedup rule).

Future tag analytics: derivable by joining `coupon_metrics_daily` ×
`coupon_tag_links` — no additional write path needed.

## 4. Storage — bucket `coupon-assets` (security contract)

Public-read is retained and justified: objects are partner marketing artwork
(public content, no user data). The full contract:

- **Access:** public `SELECT`; `INSERT/UPDATE/DELETE` denied to anon AND
  authenticated. All uploads/deletes go through the admin server route (§5)
  using the server-side service-role client. Service-role credentials never
  leave the server.
- **MIME allowlist:** `image/webp`, `image/png`, `image/jpeg` only. The upload
  route validates BOTH the declared content-type and the magic bytes.
  **No SVG** (no sanitization pipeline exists — rejected outright). No HTML,
  no PDFs, no arbitrary content.
- **Size limit:** ≤ 512 KB per object (route-enforced; bucket-level
  `file_size_limit` set as well).
- **Dimensions (recommendation, admin-UI-validated):** card artwork 16:9,
  1200×675 recommended, 600×338 minimum; square partner logos 512×512.
- **Path normalization:** exactly `coupons/{coupon_id}/art.{ext}` — the route
  derives the path; client-supplied names/paths are never used.
- **Replacement cleanup:** re-upload targets the same normalized path with
  upsert; a format change (e.g. png→webp) deletes the old object in the same
  route call. No stale versions accumulate.
- **Orphan cleanup:** deleting a coupon deletes the `coupons/{id}/` prefix in
  the same admin route. Additionally an on-demand admin maintenance route
  lists objects and removes any without a matching coupon row (manual sweep,
  no cron).
- `coupons.image_path` stores the object path; clients compose the public URL.
  Missing/failed image ⇒ accent-color fallback rendering.

## 5. Admin mutation authority (explicit chain)

```
Admin browser (Supabase session cookie; anon key only; NO service key)
  → Next.js admin API route (admin/app/api/coupons/*, /coupon-tags/*,
     /coupon-categories/*, /coupons/upload, /coupons/maintenance)
      1. verify authenticated session
      2. verify user UUID ∈ public.admin_users (fail-closed, runbook model)
  → server-side service-role client performs the DB/Storage mutation
```

- Normal mobile/authenticated users have NO write path: RLS blocks direct
  writes; the RPC surface is only `record_coupon_event`; service-role never
  ships in any client.
- This is the existing admin pattern (0003 comment: "All writes blocked for
  anon — admin uses service_role via backend API") reused unchanged.

## 6. Edge function — `catalog-coupons`

New function, cloned from `catalog-campaigns`:

- `GET`, anon key, standard catalog CORS headers; logs `x-app-version`.
- Queries the live set (filters identical to the RLS predicate), joined with
  its display category labels and tags:
  `{ items: [ { …coupon fields, display_category: {key,label_ar,label_en},
  tags: [{key,label_ar,label_en}, …deterministic order], country_codes: […],
  spend_hint_category_keys: […] } ], meta: { count, fetched_at } }`.
- Full snapshot, no delta cursor (catalog is small; campaigns precedent). If
  it ever exceeds ~1k rows, promote to a `catalog-delta` category.
- No secrets beyond standard; no APNs/AI/cron dependencies.

## 7. Admin Dashboard

New route group entries: `admin/app/(admin)/coupons/page.tsx` (+ `[id]` edit),
plus lightweight managers for tags and display categories (tabs on the coupons
page or sibling pages — implementer's choice, same API routes either way).

- **List page:** columns — partner, title_ar, type (code/link), display
  category, tags, countries (or "الكل" when empty), featured, priority,
  validity window, status badge, is_active, 7-day `code_copy`/`cta_click`
  counts. Filters: status (live/scheduled/expired/disabled), display category,
  tag, country, redemption type. Bulk activate/deactivate.
- **Editor form:**
  - identity: slug (auto from partner+title, editable, uniqueness-checked),
    partner_name;
  - content: title_ar (req), title_en, description_ar (req), description_en,
    terms_ar;
  - redemption: type selector → `code` (code req, uppercased/trimmed) or
    `link` (partner_url req); https validated in both shapes;
  - classification: display category select (from `coupon_categories`,
    deterministic order) + **tag picker** (search-as-you-type over
    `coupon_tags`, attach/detach chips, inline "create tag" with key
    normalization preview + label_ar/label_en);
  - matching hints: optional multi-select over the known financial category
    keys, clearly labeled "ترتيب سياقي فقط" (ranking hints only);
  - targeting: "متاح في جميع الدول" toggle (⇔ empty set) or ISO multi-select;
  - presentation: accent picker, image upload (§4 validations, preview),
    featured, priority;
  - scheduling: valid_from/valid_until pickers, "now"/"open-ended" shortcuts,
    status badge computed from the exact live-predicate;
  - kill-switch: is_active.
- **Tag manager:** search, create (normalized key + labels), edit labels,
  reorder, delete (blocked while linked, with usage count shown).
- **Category manager:** create/edit labels/reorder/deactivate (deactivating
  is blocked while live coupons reference the key).
- **Analytics panel (read-only):** per-coupon daily series for the four V1
  events + totals; catalog overview (top by copy/click rate). Reads via a
  service-role admin route.
- All route-level validation is duplicated server-side; DB CHECKs are the
  last line.

## 8. Scheduling semantics (single source of truth)

A coupon is **live** iff `is_active AND valid_from <= now() AND (valid_until
IS NULL OR valid_until > now())`. That predicate appears in exactly three
places and must stay literally identical: the RLS policy (§2.3), the
`catalog-coupons` query (§6), and the admin status badge (§7). The app
re-checks expiry locally at render time (companion doc §5) so a stale cache
never shows an expired offer. No cron jobs; no scheduled state flips.

## 9. Feature flag

Rollout rides the existing remote flag system: seeded key **`enable_coupons`**
(currently `false`, `app/lib/data/catalog/feature_flag_service.dart:13`) gates
the entire app surface (companion doc §3). Admin flips it in `/flags` with
rollout %. No new flag infrastructure.

## 10. Tests (admin/server side)

- **Migration lint:** 0081/0082 pass `tools/ci_gates.sh` stage 1 (numbering +
  SECURITY DEFINER lockdown — `record_coupon_event` must satisfy the
  definer-hardening checks like 0080).
- **Node contract tests** (live cases self-skip without credentials): anon
  sees only live coupons; scheduled/expired/disabled invisible; empty
  `country_codes` visible regardless of country filter logic client-side;
  anon INSERT/UPDATE rejected on all four tables; storage anon write
  rejected; `record_coupon_event` — anon EXECUTE rejected, authenticated
  increments, **unknown event rejected**, all four V1 events accepted; tag
  link cascade on coupon delete; RLS predicate ≡ function query (one row
  probed through both paths).
- **Admin lint/build:** `npm run lint && npm run build` stay green.
- **Admin API route validation matrix** (route tests or staging): code-shape,
  https, hex color, unknown display category rejected, malformed tag key
  rejected, non-ISO country rejected, oversized/wrong-MIME/SVG upload
  rejected, path traversal attempts ignored (server derives paths).

## 11. Staging validation plan (coupon-specific, on `bdhqjijscwdzqwqanygv`)

1. Apply 0081+0082; create `coupon-assets` bucket with policies; deploy
   `catalog-coupons`.
2. Seed via the admin UI (not SQL): two display categories; three tags (incl.
   one created inline from the picker); one live `code` coupon (global =
   empty countries), one live `link` coupon (country-scoped, e.g. `{SA}`),
   one scheduled, one expired, one disabled; one image upload (+ one rejected
   oversized/SVG attempt).
3. Verify with anon key: only live coupons visible via REST and
   `catalog-coupons`; tags/category labels embedded and deterministically
   ordered; the scheduled coupon appears after its boundary passes.
4. Admin: edit → `updated_at` bump propagates; tag detach/attach reflects in
   the snapshot; kill-switch removes; delete cascades tag links + metrics +
   storage prefix; maintenance sweep removes a manufactured orphan object.
5. Metrics: authenticated `record_coupon_event` increments all four events;
   anon EXECUTE fails; unknown event fails; admin analytics route reads the
   series.
6. Run the app-side staging pass (companion doc §11) against this seeded
   state, then clean or keep a curated staging set.

## 12. Feature isolation (explicit)

Coupons does **not** modify the contracts of: Money, financial sync, Planning
currency, CAS/conflict handling, the capture pipeline, or the backup snapshot
format. The client v31 `remote_coupons` table is refetchable catalog cache and
is **excluded from the business backup** (companion doc §2). Shared surfaces
are read-only or additive: the financial category **keys** (as optional hint
strings), `CatalogSyncService` (+1 fetch), the feature-flag system (existing
key), Drift (additive v31), and the metrics RPC idiom. Any need beyond this
list stops work and is reported first.
