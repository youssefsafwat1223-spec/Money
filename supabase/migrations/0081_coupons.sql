-- Coupons / Offers — catalog, RLS and Storage foundation (Coupons Phase C1).
-- Authority: docs/COUPONS_ADMIN_SYSTEM.md (r2) + docs/COUPONS_APP_EXPERIENCE.md (r2).
--
-- SCOPE (this migration only): the public marketing CATALOG domain —
-- coupon_categories, coupon_tags, coupon_tag_links, coupons — plus their RLS
-- and the coupon-assets Storage bucket/policies.
-- NOT in this migration (later Coupon phase): coupon_metrics_daily and the
-- record_coupon_event analytics RPC (0082).
--
-- ISOLATION: this is a NEW, self-contained catalog domain. It creates no
-- dependency on and makes no change to any financial contract — transactions /
-- Money authority, Planning currency, revision/CAS columns, financial sync,
-- the backup snapshot format, or the capture pipeline. It holds no user data:
-- every row here is admin-authored public marketing content.
--
-- WRITE AUTHORITY: no client role may write anything below. Admin mutations go
-- browser session -> authenticated Admin server route (session + admin_users
-- check) -> service_role operation, server-side only (0003 pattern).

-- ---------------------------------------------------------------------------
-- 1. Canonical visibility ("live") predicate
-- ---------------------------------------------------------------------------
-- ONE definition, referenced by the RLS policy below; the Edge snapshot and the
-- Admin status badge MUST mirror this exact semantic contract.
--   active            : is_active = true
--   window start      : valid_from <= now()   (INCLUSIVE — live AT valid_from)
--   window end        : valid_until IS NULL   (no expiry)
--                       OR valid_until > now() (EXCLUSIVE — expired AT valid_until)
-- There is no deleted_at/archived column in this domain: deactivation is the
-- soft-delete (is_active = false hides a row from every client read).
-- Pure scalar logic over its arguments: it reads no table and grants no
-- additional visibility, so it is a plain invoker-rights STABLE function (it
-- deliberately does NOT use definer rights).
CREATE OR REPLACE FUNCTION public.coupon_is_live(
  p_is_active   BOOLEAN,
  p_valid_from  TIMESTAMPTZ,
  p_valid_until TIMESTAMPTZ
) RETURNS BOOLEAN
LANGUAGE sql
STABLE
SET search_path = pg_catalog, public, pg_temp
AS $$
  SELECT COALESCE(p_is_active, false)
     AND p_valid_from <= now()
     AND (p_valid_until IS NULL OR p_valid_until > now());
$$;

COMMENT ON FUNCTION public.coupon_is_live(BOOLEAN, TIMESTAMPTZ, TIMESTAMPTZ) IS
  'Canonical Coupon visibility predicate (Coupons C1). valid_from inclusive, '
  'valid_until exclusive, is_active required. RLS, Edge catalog and Admin '
  'status badge must all use this same contract.';

-- ---------------------------------------------------------------------------
-- 2. coupon_categories — Coupon-OWNED display taxonomy
-- ---------------------------------------------------------------------------
-- Deliberately independent of the financial transaction-category domain: no FK,
-- no shared authority. The Coupon feature stays understandable if the financial
-- taxonomy evolves.
CREATE TABLE IF NOT EXISTS coupon_categories (
  key        TEXT PRIMARY KEY,
  label_ar   TEXT NOT NULL,
  label_en   TEXT NULL,
  sort_order INTEGER NOT NULL DEFAULT 0,
  is_active  BOOLEAN NOT NULL DEFAULT true,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT coupon_categories_key_shape CHECK (key ~ '^[a-z0-9_]{2,32}$'),
  CONSTRAINT coupon_categories_label_ar_present CHECK (btrim(label_ar) <> '')
);

CREATE INDEX IF NOT EXISTS idx_coupon_categories_order
  ON coupon_categories (sort_order, key);

DROP TRIGGER IF EXISTS trg_coupon_categories_updated_at ON coupon_categories;
CREATE TRIGGER trg_coupon_categories_updated_at
  BEFORE UPDATE ON coupon_categories
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ---------------------------------------------------------------------------
-- 3. coupon_tags — normalized tag model (NOT an array column on coupons)
-- ---------------------------------------------------------------------------
-- `key` is the normalized identifier (admin route lowercases, trims and
-- collapses whitespace to '_'); `label_ar` is what the UI renders as #<label>.
-- Arabic keys are permitted so an Arabic-first label can normalize to a key.
CREATE TABLE IF NOT EXISTS coupon_tags (
  id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  key        TEXT NOT NULL UNIQUE,
  label_ar   TEXT NOT NULL,
  label_en   TEXT NULL,
  sort_order INTEGER NOT NULL DEFAULT 0,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT coupon_tags_key_shape CHECK (key ~ '^[a-z0-9_؀-ۿ]{2,32}$'),
  CONSTRAINT coupon_tags_label_ar_present CHECK (btrim(label_ar) <> '')
);

CREATE INDEX IF NOT EXISTS idx_coupon_tags_order ON coupon_tags (sort_order, key);

DROP TRIGGER IF EXISTS trg_coupon_tags_updated_at ON coupon_tags;
CREATE TRIGGER trg_coupon_tags_updated_at
  BEFORE UPDATE ON coupon_tags
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ---------------------------------------------------------------------------
-- 4. coupons — the catalog
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS coupons (
  id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  slug           TEXT NOT NULL UNIQUE,
  partner_name   TEXT NOT NULL,
  -- Arabic-first content; English is an optional fallback.
  title_ar       TEXT NOT NULL,
  title_en       TEXT NULL,
  description_ar TEXT NOT NULL,
  description_en TEXT NULL,
  -- Redemption shape (see constraints below).
  redemption_type TEXT NOT NULL CHECK (redemption_type IN ('code', 'link')),
  code           TEXT NULL,
  partner_url    TEXT NULL,
  -- Display classification: Coupon-owned taxonomy. NOT a financial category.
  -- No ON DELETE action => RESTRICT: a category in use cannot be dropped.
  display_category_key TEXT NOT NULL REFERENCES coupon_categories(key),
  -- OPTIONAL on-device ranking hints naming financial category keys. METADATA
  -- ONLY: intentionally NO foreign key — unknown/stale keys stay legal content
  -- and simply produce no client-side ranking boost. No spend history is ever
  -- stored or received here.
  spend_hint_category_keys TEXT[] NOT NULL DEFAULT '{}',
  -- Country targeting. CANONICAL: '{}' (empty) => GLOBALLY available.
  -- Non-empty => ISO-3166-1 alpha-2 UPPERCASE allowlist. 'ALL' is not a value.
  country_codes  TEXT[] NOT NULL DEFAULT '{}',
  -- Presentation
  accent_hex     TEXT NULL,
  image_path     TEXT NULL,   -- storage object path in coupon-assets (server-derived)
  featured       BOOLEAN NOT NULL DEFAULT false,
  priority       INTEGER NOT NULL DEFAULT 0,
  -- Scheduling (see coupon_is_live)
  valid_from     TIMESTAMPTZ NOT NULL DEFAULT now(),
  valid_until    TIMESTAMPTZ NULL,
  is_active      BOOLEAN NOT NULL DEFAULT true,
  -- Terms
  terms_ar       TEXT NULL,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at     TIMESTAMPTZ NOT NULL DEFAULT now(),

  CONSTRAINT coupons_slug_shape CHECK (slug ~ '^[a-z0-9][a-z0-9_-]{1,63}$'),
  CONSTRAINT coupons_partner_present CHECK (btrim(partner_name) <> ''),
  CONSTRAINT coupons_title_ar_present CHECK (btrim(title_ar) <> ''),
  CONSTRAINT coupons_description_ar_present CHECK (btrim(description_ar) <> ''),

  -- Redemption shape. 'code': a non-empty code is required and a partner_url is
  -- OPTIONAL (secondary "open site" CTA). 'link': the destination is required
  -- and `code` MUST be NULL so a code can never become a contradictory second
  -- authority. Any other mix is rejected at the database.
  CONSTRAINT coupons_redemption_shape CHECK (
    (redemption_type = 'code' AND code IS NOT NULL AND btrim(code) <> '')
    OR
    (redemption_type = 'link' AND code IS NULL AND partner_url IS NOT NULL)
  ),

  -- Destination safety: only https. This rejects http, javascript:, data:,
  -- file: and every other scheme without fragile URL parsing in SQL. Fuller
  -- validation (host allowlist, shape) is duplicated in the Admin server route.
  CONSTRAINT coupons_url_https CHECK (
    partner_url IS NULL OR partner_url LIKE 'https://%'
  ),

  -- Country codes: empty (global) OR every element is exactly two uppercase
  -- ASCII letters. array_to_string keeps this a simple immutable expression
  -- (CHECK constraints cannot contain subqueries).
  CONSTRAINT coupons_country_codes_shape CHECK (
    country_codes = '{}'::text[]
    OR array_to_string(country_codes, ',') ~ '^[A-Z]{2}(,[A-Z]{2})*$'
  ),

  CONSTRAINT coupons_accent_hex_shape CHECK (
    accent_hex IS NULL OR accent_hex ~ '^#[0-9A-Fa-f]{6}$'
  ),

  -- A window that ends before it starts can never be live: reject it outright.
  CONSTRAINT coupons_window_order CHECK (
    valid_until IS NULL OR valid_until > valid_from
  ),

  -- Storage objects are server-derived under coupons/<uuid>/...; never accept a
  -- client-shaped or traversing path.
  CONSTRAINT coupons_image_path_shape CHECK (
    image_path IS NULL OR image_path ~ '^coupons/[0-9a-f-]{36}/[A-Za-z0-9_.-]+$'
  )
);

CREATE INDEX IF NOT EXISTS idx_coupons_live
  ON coupons (is_active, featured DESC, priority DESC, valid_from)
  WHERE is_active = true;
CREATE INDEX IF NOT EXISTS idx_coupons_display_category
  ON coupons (display_category_key);

DROP TRIGGER IF EXISTS trg_coupons_updated_at ON coupons;
CREATE TRIGGER trg_coupons_updated_at
  BEFORE UPDATE ON coupons
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ---------------------------------------------------------------------------
-- 5. coupon_tag_links — coupon <-> tag join (no duplicate relation possible)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS coupon_tag_links (
  coupon_id  UUID NOT NULL REFERENCES coupons(id)     ON DELETE CASCADE,
  tag_id     UUID NOT NULL REFERENCES coupon_tags(id) ON DELETE CASCADE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (coupon_id, tag_id)
);

CREATE INDEX IF NOT EXISTS idx_coupon_tag_links_tag ON coupon_tag_links (tag_id);

-- ---------------------------------------------------------------------------
-- 6. Category deactivation guard (smallest safe mechanism)
-- ---------------------------------------------------------------------------
-- A display category may not be deactivated while any LIVE coupon still points
-- at it (that would strand live catalog rows with an invisible classification).
-- Trigger-bound and invoker-rights (no definer rights); admin writes run as
-- service_role, which sees every row.
CREATE OR REPLACE FUNCTION public.coupon_categories_block_deactivate_in_use()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = pg_catalog, public, pg_temp
AS $$
BEGIN
  IF OLD.is_active AND NOT NEW.is_active THEN
    IF EXISTS (
      SELECT 1 FROM public.coupons c
      WHERE c.display_category_key = OLD.key
        AND public.coupon_is_live(c.is_active, c.valid_from, c.valid_until)
    ) THEN
      RAISE EXCEPTION
        'coupon_categories: cannot deactivate "%" while live coupons use it',
        OLD.key
        USING ERRCODE = 'restrict_violation';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_coupon_categories_block_deactivate ON coupon_categories;
CREATE TRIGGER trg_coupon_categories_block_deactivate
  BEFORE UPDATE ON coupon_categories
  FOR EACH ROW EXECUTE FUNCTION public.coupon_categories_block_deactivate_in_use();

-- ---------------------------------------------------------------------------
-- 7. Row Level Security
-- ---------------------------------------------------------------------------
-- Every table is RLS-enabled and READ-ONLY for clients. Roles are named
-- EXPLICITLY (anon AND authenticated): `authenticated` does not inherit an
-- anon-scoped policy, so each role is granted its read separately.
-- No INSERT/UPDATE/DELETE policy exists for any client role => all writes are
-- denied by default; only service_role (which bypasses RLS, server-side only)
-- can mutate.

ALTER TABLE coupons           ENABLE ROW LEVEL SECURITY;
ALTER TABLE coupon_categories ENABLE ROW LEVEL SECURITY;
ALTER TABLE coupon_tags       ENABLE ROW LEVEL SECURITY;
ALTER TABLE coupon_tag_links  ENABLE ROW LEVEL SECURITY;

-- coupons: only currently-live rows are readable, by either client role.
DROP POLICY IF EXISTS coupons_live_select_anon ON coupons;
CREATE POLICY coupons_live_select_anon ON coupons
  FOR SELECT TO anon
  USING (public.coupon_is_live(is_active, valid_from, valid_until));

DROP POLICY IF EXISTS coupons_live_select_authenticated ON coupons;
CREATE POLICY coupons_live_select_authenticated ON coupons
  FOR SELECT TO authenticated
  USING (public.coupon_is_live(is_active, valid_from, valid_until));

-- coupon_categories: only ACTIVE categories are exposed (the minimum needed to
-- render chips/labels for live coupons).
DROP POLICY IF EXISTS coupon_categories_active_select_anon ON coupon_categories;
CREATE POLICY coupon_categories_active_select_anon ON coupon_categories
  FOR SELECT TO anon USING (is_active = true);

DROP POLICY IF EXISTS coupon_categories_active_select_authenticated ON coupon_categories;
CREATE POLICY coupon_categories_active_select_authenticated ON coupon_categories
  FOR SELECT TO authenticated USING (is_active = true);

-- coupon_tags / coupon_tag_links: least exposure — a client may read ONLY the
-- tags actually attached to a coupon it can already see. (The mobile client
-- consumes the flattened Edge snapshot; these policies exist so direct reads,
-- if ever used, can never enumerate the full tag universe or reveal links of
-- hidden/scheduled coupons.)
DROP POLICY IF EXISTS coupon_tags_linked_select_anon ON coupon_tags;
CREATE POLICY coupon_tags_linked_select_anon ON coupon_tags
  FOR SELECT TO anon
  USING (EXISTS (
    SELECT 1 FROM coupon_tag_links l JOIN coupons c ON c.id = l.coupon_id
    WHERE l.tag_id = coupon_tags.id
      AND public.coupon_is_live(c.is_active, c.valid_from, c.valid_until)
  ));

DROP POLICY IF EXISTS coupon_tags_linked_select_authenticated ON coupon_tags;
CREATE POLICY coupon_tags_linked_select_authenticated ON coupon_tags
  FOR SELECT TO authenticated
  USING (EXISTS (
    SELECT 1 FROM coupon_tag_links l JOIN coupons c ON c.id = l.coupon_id
    WHERE l.tag_id = coupon_tags.id
      AND public.coupon_is_live(c.is_active, c.valid_from, c.valid_until)
  ));

DROP POLICY IF EXISTS coupon_tag_links_live_select_anon ON coupon_tag_links;
CREATE POLICY coupon_tag_links_live_select_anon ON coupon_tag_links
  FOR SELECT TO anon
  USING (EXISTS (
    SELECT 1 FROM coupons c
    WHERE c.id = coupon_tag_links.coupon_id
      AND public.coupon_is_live(c.is_active, c.valid_from, c.valid_until)
  ));

DROP POLICY IF EXISTS coupon_tag_links_live_select_authenticated ON coupon_tag_links;
CREATE POLICY coupon_tag_links_live_select_authenticated ON coupon_tag_links
  FOR SELECT TO authenticated
  USING (EXISTS (
    SELECT 1 FROM coupons c
    WHERE c.id = coupon_tag_links.coupon_id
      AND public.coupon_is_live(c.is_active, c.valid_from, c.valid_until)
  ));

-- Table privileges mirror the policies: SELECT only for client roles. (RLS
-- would already deny writes for want of a policy; withholding the grant makes
-- the intent explicit and survives a future policy mistake.)
REVOKE ALL ON TABLE coupons, coupon_categories, coupon_tags, coupon_tag_links
  FROM anon, authenticated;
GRANT SELECT ON TABLE coupons, coupon_categories, coupon_tags, coupon_tag_links
  TO anon, authenticated;

-- ---------------------------------------------------------------------------
-- 8. Storage — coupon-assets bucket
-- ---------------------------------------------------------------------------
-- Public-read marketing artwork (no user data). Object paths are ALWAYS derived
-- server-side by the Admin route: coupons/<coupon_id>/art.<ext>.
-- Bucket-level guards below are the safe SQL baseline: public read, byte limit
-- and a MIME allowlist. Deeper validation (magic bytes, dimensions, extension
-- normalization, SVG and arbitrary-content rejection) is NOT expressible in SQL
-- and is owned by the Admin server route (documented boundary; the approved
-- contract is not weakened by living outside SQL).
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'coupon-assets', 'coupon-assets', true, 524288,
  ARRAY['image/webp', 'image/png', 'image/jpeg']
)
ON CONFLICT (id) DO UPDATE
  SET public = EXCLUDED.public,
      file_size_limit = EXCLUDED.file_size_limit,
      allowed_mime_types = EXCLUDED.allowed_mime_types;

-- Read: public marketing assets, explicitly for BOTH client roles.
DROP POLICY IF EXISTS "coupon assets public read" ON storage.objects;
CREATE POLICY "coupon assets public read" ON storage.objects
  FOR SELECT TO anon, authenticated
  USING (bucket_id = 'coupon-assets');

-- No INSERT/UPDATE/DELETE policy is created for anon or authenticated: uploads,
-- overwrites and deletes are impossible for ordinary users and remain exclusive
-- to the service-role Admin server route.
