// Coupons Phase C3 — Admin API/security/validation contract tests.
//
// Behavioural tests run against the REAL shared validation/error modules (they
// are plain .mjs precisely so the routes and these tests cannot drift apart).
// Route-level authorization, the service-role boundary and the Storage-path
// rules are asserted structurally, because 0081/0082 are not deployed yet and
// C3 must not contact staging to make Admin development easier.
import assert from "node:assert/strict";
import { existsSync, readFileSync, readdirSync } from "node:fs";
import test from "node:test";

import {
  COUPON_SORTS,
  IMAGE_MIME_ALLOWLIST,
  MAX_IMAGE_BYTES,
  couponStatus,
  detectImageSignature,
  isIsoCountryCode,
  normalizeSlug,
  normalizeTagKey,
  resolveSort,
  storageObjectPath,
  validateCategoryPayload,
  validateCouponPayload,
  validateDestinationUrl,
  validateImageUpload,
  validateTagPayload,
} from "../lib/coupon-validation.mjs";
import { mapDatabaseError, messageFor, safeErrorBody } from "../lib/coupon-errors.mjs";

const read = (path) => readFileSync(new URL(`../${path}`, import.meta.url), "utf8");
/** Source with comments stripped, so a scan tests CODE and not documentation. */
const readCode = (path) =>
  read(path)
    .split("\n")
    .map((l) => l.replace(/(^|[^:])\/\/.*$/, "$1"))
    .filter((l) => {
      const t = l.trim();
      return !t.startsWith("*") && !t.startsWith("/*") && !t.startsWith("*/");
    })
    .join("\n");
const ROUTES = [
  "app/api/coupons/route.ts",
  "app/api/coupons/image/route.ts",
  "app/api/coupon-categories/route.ts",
  "app/api/coupon-tags/route.ts",
  "app/api/coupon-analytics/route.ts",
];

const base = (over = {}) => ({
  slug: "partner-offer",
  partner_name: "Partner",
  title_ar: "عنوان",
  description_ar: "وصف",
  redemption_type: "code",
  code: "SAVE20",
  display_category_key: "food",
  is_global: true,
  valid_from: "2026-08-01T00:00:00.000Z",
  priority: 0,
  ...over,
});
const err = (res, field) => res.errors.find((e) => e.field === field)?.error;

/* ------------------------------------------------- A/B: route authorization */

test("A/B: every Coupon route maps unauthenticated->401 and non-admin->403", () => {
  const guard = read("lib/auth-guard.ts");
  assert.match(guard, /unauthenticated[\s\S]*?status: 401/);
  assert.match(guard, /not_authorized[\s\S]*?status: 403/);
  // Fails CLOSED when the auth/allowlist lookup itself is unavailable.
  assert.match(guard, /authorization_unavailable[\s\S]*?status: 503/);
  // Admin rights come only from the admin_users allowlist, never from claims.
  assert.match(guard, /from\("admin_users"\)/);
  assert.doesNotMatch(guard, /email.*(endsWith|includes).*@/);

  for (const path of ROUTES) {
    const src = read(path);
    const handlers = [...src.matchAll(/export async function (GET|POST|PATCH|DELETE)[\s\S]*?(?=export async function|$)/g)];
    assert.ok(handlers.length > 0, `${path} exports handlers`);
    for (const [body, verb] of handlers.map((m) => [m[0], m[1]])) {
      assert.match(body, /await requireAdmin\(\)/, `${path} ${verb} must require admin`);
      assert.match(body, /adminAuthErrorResponse\(e\)/, `${path} ${verb} must map auth errors`);
      // Authorization happens before any privileged client is created.
      assert.ok(
        body.indexOf("requireAdmin") < body.indexOf("createAdminClient"),
        `${path} ${verb}: admin check must precede the service-role client`,
      );
    }
  }
});

/* --------------------------------------------------- D–G: create validation */

test("D: a valid code offer passes and is normalized", () => {
  const res = validateCouponPayload(base());
  assert.equal(res.ok, true);
  assert.equal(res.value.code, "SAVE20");
  assert.equal(res.value.partner_url, null);
  assert.deepEqual(res.value.country_codes, []);
  assert.equal(res.value.is_active, true);
});

test("E: a valid link offer passes; its destination is kept, code stays null", () => {
  const res = validateCouponPayload(
    base({ redemption_type: "link", code: "", partner_url: "https://example.com/x" }),
  );
  assert.equal(res.ok, true);
  assert.equal(res.value.code, null);
  assert.match(String(res.value.partner_url), /^https:\/\/example\.com\/x/);
});

test("F: invalid code shapes are rejected", () => {
  assert.equal(err(validateCouponPayload(base({ code: "" })), "code"), "code_required");
  assert.equal(
    err(validateCouponPayload(base({ redemption_type: "link", partner_url: "https://a.com", code: "X" })), "code"),
    "code_not_allowed_for_link",
  );
  assert.equal(
    err(validateCouponPayload(base({ redemption_type: "voucher" })), "redemption_type"),
    "invalid_redemption_type",
  );
});

test("G: destination URLs are validated with a real parser, stricter than the DB", () => {
  assert.equal(validateDestinationUrl("https://example.com").ok, true);
  assert.equal(validateDestinationUrl("http://example.com").error, "url_not_https");
  assert.equal(validateDestinationUrl("javascript:alert(1)").error, "url_not_https");
  assert.equal(validateDestinationUrl("data:text/html,x").error, "url_not_https");
  assert.equal(validateDestinationUrl("file:///etc/passwd").error, "url_not_https");
  assert.equal(validateDestinationUrl("not a url").error, "invalid_url");
  assert.equal(validateDestinationUrl("https://user:pass@host.com").error, "url_has_credentials");
  for (const host of ["https://localhost", "https://127.0.0.1", "https://10.0.0.5", "https://192.168.1.1", "https://169.254.1.1", "https://172.16.0.1"]) {
    assert.equal(validateDestinationUrl(host).error, "url_private_host", host);
  }
  // The destination is never fetched server-side (no SSRF surface).
  for (const path of ROUTES) {
    assert.doesNotMatch(read(path), /fetch\(\s*(partner_url|url|destination)/i);
  }
});

/* ------------------------------------------------------ H: duplicate mapping */

test("H: duplicate slug / tag key map to safe messages, never raw SQL", () => {
  assert.equal(mapDatabaseError({ code: "23505", message: 'duplicate key value violates unique constraint "coupons_slug_key"' }), "duplicate_slug");
  assert.equal(mapDatabaseError({ code: "23505", message: 'duplicate key ... "coupon_tags_key_key"' }), "duplicate_tag_key");
  const body = safeErrorBody("duplicate_slug");
  assert.equal(body.error, "duplicate_slug");
  assert.match(body.message, /slug is already used/i);
  assert.ok(!JSON.stringify(body).includes("constraint"));
});

/* ---------------------------------------------- I/J/K: update, disable, delete */

test("I: update reuses the SAME schema as create (no second authority)", () => {
  const src = read("app/api/coupons/route.ts");
  const uses = src.match(/validateCouponPayload\(/g) ?? [];
  assert.equal(uses.length, 2, "create and update both validate");
  assert.match(src, /validateCouponPayload\(body, \{ mode: "create" \}\)/);
  assert.match(src, /validateCouponPayload\(body, \{ mode: "update" \}\)/);
});

test("J/K: disable is a PATCH; permanent delete is confirm-gated and prefix-scoped", () => {
  const src = read("app/api/coupons/route.ts");
  // Permanent delete requires an explicit confirmation token.
  assert.match(src, /confirm.*!==.*"permanent"/);
  // …and only removes THIS coupon's storage prefix.
  assert.match(src, /list\(`coupons\/\$\{id\}`\)/);
  assert.match(src, /coupons\/\$\{id\}\/\$\{o\.name\}/);
  // The UI keeps disable as the routine action and warns before deleting.
  // The warning copy is Arabic-first since the 2026 redesign; these assertions
  // track the rendered strings, not code comments.
  const page = read("app/(admin)/coupons/page.tsx");
  assert.match(page, /الحذف النهائي يزيل العرض/);
  assert.match(page, /استخدم «إيقاف» بدلًا من الحذف/);
  assert.match(page, /is_active: active/);
});

/* ------------------------------------------------------- L/M: country targeting */

test("L: global availability persists as [] and never 'ALL'", () => {
  const res = validateCouponPayload(base({ is_global: true, country_codes: ["SA"] }));
  assert.deepEqual(res.value.country_codes, []);
  for (const path of [...ROUTES, "app/(admin)/coupons/page.tsx", "lib/coupon-validation.mjs"]) {
    assert.ok(!readCode(path).includes("'ALL'"), `${path} must not use the 'ALL' literal in code`);
  }
});

test("M: scoped countries are uppercased, de-duplicated and ISO-validated", () => {
  const ok = validateCouponPayload(base({ is_global: false, country_codes: ["sa", "AE", "sa"] }));
  assert.deepEqual(ok.value.country_codes, ["SA", "AE"]);
  assert.equal(
    err(validateCouponPayload(base({ is_global: false, country_codes: [] })), "country_codes"),
    "countries_required_when_not_global",
  );
  assert.equal(
    err(validateCouponPayload(base({ is_global: false, country_codes: ["ALL"] })), "country_codes"),
    "invalid_country_code",
  );
  assert.equal(isIsoCountryCode("SA"), true);
  assert.equal(isIsoCountryCode("sa"), false);
});

/* ------------------------------------------------------- N/O: category manager */

test("N: category payloads validate key/labels/order", () => {
  assert.equal(validateCategoryPayload({ key: "food", label_ar: "مطاعم" }).ok, true);
  assert.equal(
    validateCategoryPayload({ key: "F!", label_ar: "x" }).errors[0].error,
    "invalid_category_key",
  );
  assert.equal(validateCategoryPayload({ key: "food", label_ar: " " }).errors[0].error, "required");
  // Update mode does not re-require the immutable key in the body payload.
  const upd = validateCategoryPayload({ label_ar: "مطاعم", sort_order: 3 }, { mode: "update" });
  assert.equal(upd.ok, true);
  assert.equal(upd.value.key, undefined);
});

test("O: the 0081 in-use restriction becomes controlled Admin copy, never raw SQL", () => {
  assert.equal(mapDatabaseError({ code: "23001", message: "restrict" }), "category_in_use");
  assert.equal(
    mapDatabaseError({ code: "P0001", message: 'coupon_categories: cannot deactivate "food" while live coupons use it' }),
    "category_in_use",
  );
  assert.match(messageFor("category_in_use"), /used by active offers/i);
  // The trigger is never bypassed: no route force-updates coupons to dodge it.
  assert.doesNotMatch(read("app/api/coupon-categories/route.ts"), /from\("coupons"\)/);
});

/* ----------------------------------------------------------- P/Q/R: tag model */

test("P: tag creation normalizes the key (Arabic preserved)", () => {
  const res = validateTagPayload({ key: "  Fine Dining ", label_ar: "مطاعم" });
  assert.equal(res.ok, true);
  assert.equal(res.value.key, "fine_dining");
  assert.equal(normalizeTagKey("مطاعم فاخرة"), "مطاعم_فاخرة");
  assert.equal(normalizeSlug("Talabat  20% OFF!"), "talabat-20-off");
});

test("Q: duplicate tag keys surface as controlled validation feedback", () => {
  assert.equal(validateTagPayload({ key: "!", label_ar: "x" }).errors[0].error, "invalid_tag_key");
  assert.match(messageFor("duplicate_tag_key"), /already exists/i);
});

test("R: tags attach/detach through the normalized join, never a tags[] column", () => {
  const src = read("app/api/coupons/route.ts");
  assert.match(src, /coupon_tag_links/);
  assert.match(src, /async function syncTagLinks/);
  assert.match(src, /\.delete\(\)\s*\.eq\("coupon_id", couponId\)/);
  for (const path of [...ROUTES, "app/(admin)/coupons/page.tsx"]) {
    assert.doesNotMatch(read(path), /\btags:\s*\[/, `${path} must not build a tags[] array`);
  }
  const res = validateCouponPayload(base({ tag_ids: ["a", "b", 7] }));
  assert.deepEqual(res.value.__tag_ids, ["a", "b"]);
});

/* --------------------------------------------------------------- S: spend hints */

test("S: spend hints are optional, de-duplicated, FK-free and survive unknown keys", () => {
  const res = validateCouponPayload(base({ spend_hint_category_keys: ["restaurants", "restaurants", "legacy_key"] }));
  assert.deepEqual(res.value.spend_hint_category_keys, ["restaurants", "legacy_key"]);
  assert.equal(validateCouponPayload(base()).value.spend_hint_category_keys.length, 0);
  // The Admin UI labels them as ranking metadata, not transaction categorization.
  const page = read("app/(admin)/coupons/page.tsx");
  assert.match(page, /تلميحات ترتيب حسب الإنفاق/);
  assert.match(page, /ولا تُصنَّف بها عمليات أي/);
});

/* ------------------------------------------------------- T–Y: image + storage */

test("T: oversized images are rejected before any upload", () => {
  const res = validateImageUpload({ size: MAX_IMAGE_BYTES + 1, mime: "image/png", bytes: new Uint8Array(12) });
  assert.equal(res.error, "image_too_large");
  assert.equal(MAX_IMAGE_BYTES, 512 * 1024);
});

test("U: only the approved MIME types are accepted", () => {
  assert.deepEqual(IMAGE_MIME_ALLOWLIST, ["image/webp", "image/png", "image/jpeg"]);
  const png = new Uint8Array([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0, 0, 0, 0]);
  assert.equal(validateImageUpload({ size: 10, mime: "image/gif", bytes: png }).error, "image_mime_not_allowed");
});

test("V: declared MIME must match the real magic bytes", () => {
  const png = new Uint8Array([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0, 0, 0, 0]);
  const jpeg = new Uint8Array([0xff, 0xd8, 0xff, 0xe0, 0, 0, 0, 0, 0, 0, 0, 0]);
  const webp = new Uint8Array([0x52, 0x49, 0x46, 0x46, 0, 0, 0, 0, 0x57, 0x45, 0x42, 0x50]);
  assert.equal(validateImageUpload({ size: 10, mime: "image/png", bytes: png }).extension, "png");
  assert.equal(validateImageUpload({ size: 10, mime: "image/jpeg", bytes: jpeg }).extension, "jpg");
  assert.equal(validateImageUpload({ size: 10, mime: "image/webp", bytes: webp }).extension, "webp");
  // A PNG renamed/declared as JPEG is refused.
  assert.equal(validateImageUpload({ size: 10, mime: "image/jpeg", bytes: png }).error, "image_signature_mismatch");
  assert.equal(detectImageSignature(new Uint8Array(12)), null);
});

test("W: SVG and HTML uploads are rejected outright", () => {
  const svg = new TextEncoder().encode('<svg xmlns="http://www.w3.org/2000/svg"><script/></svg>');
  assert.equal(validateImageUpload({ size: svg.length, mime: "image/svg+xml", bytes: svg }).error, "image_mime_not_allowed");
  // Even when disguised behind an allowed MIME, the signature check refuses it.
  assert.equal(validateImageUpload({ size: svg.length, mime: "image/png", bytes: svg }).error, "image_signature_unknown");
  const html = new TextEncoder().encode("<!DOCTYPE html><html><body>x</body></html>");
  assert.equal(validateImageUpload({ size: html.length, mime: "image/png", bytes: html }).error, "image_signature_unknown");
});

test("X: the Storage object key is generated by the server, never by the client", () => {
  const id = "11111111-1111-1111-1111-111111111111";
  assert.equal(storageObjectPath(id, "png"), `coupons/${id}/art.png`);
  // A client cannot influence directory, name or extension.
  assert.equal(storageObjectPath("../../etc", "png"), null);
  assert.equal(storageObjectPath(id, "svg"), null);
  assert.equal(storageObjectPath(id, "../art.png"), null);
  const src = read("app/api/coupons/image/route.ts");
  assert.match(src, /storageObjectPath\(couponId, check\.extension\)/);
  // The uploaded filename is never used to build the key.
  assert.doesNotMatch(src, /file\.name/);
});

test("Y: image replacement uploads first, then repoints, then removes the old object", () => {
  const src = read("app/api/coupons/image/route.ts");
  const upload = src.indexOf(".upload(path");
  const update = src.indexOf('.update({ image_path: path })');
  const remove = src.indexOf("remove([previousPath])");
  assert.ok(upload > 0 && update > upload, "upload precedes the row update");
  assert.ok(remove > update, "the old object is removed only after the row points at the new one");
  // A failed row update does not leave the coupon pointing at a broken object.
  assert.match(src, /if \(path !== previousPath\) await supabase\.storage\.from\(BUCKET\)\.remove\(\[path\]\)/);
  // Deletion only ever touches this coupon's own prefix.
  assert.match(src, /previousPath\.startsWith\(`coupons\/\$\{couponId\}\/`\)/);
  assert.match(src, /currentPath\.startsWith\(`coupons\/\$\{couponId\}\/`\)/);
});

/* ------------------------------------------------- Z: service-role never in UI */

test("Z: the browser never receives service-role credentials", () => {
  const page = read("app/(admin)/coupons/page.tsx");
  assert.match(page, /^"use client";/);
  // A client component must not import the server admin client or read secrets.
  assert.doesNotMatch(page, /createAdminClient|SUPABASE_SERVICE_ROLE_KEY|supabase-server/);
  // Every mutation goes through a trusted /api route.
  assert.match(page, /fetch\("\/api\/coupons"/);
  // The service-role key is referenced ONLY in the server-side factory.
  assert.match(read("lib/supabase-server.ts"), /SUPABASE_SERVICE_ROLE_KEY/);
  for (const path of ["lib/coupon-validation.mjs", "lib/coupon-errors.mjs", "components/sidebar.tsx"]) {
    assert.doesNotMatch(read(path), /SERVICE_ROLE/, `${path} must not touch the service role`);
  }
  // It is never exposed through a NEXT_PUBLIC_ variable (which ships to the bundle).
  for (const path of [...ROUTES, "lib/supabase-server.ts", "app/(admin)/coupons/page.tsx"]) {
    assert.doesNotMatch(read(path), /NEXT_PUBLIC_[A-Z_]*SERVICE/);
  }
});

/* ---------------------------------------------------- AA–AC: analytics panel */

test("AA/AB: analytics totals and daily breakdown come from a trusted admin route", () => {
  const src = read("app/api/coupon-analytics/route.ts");
  assert.match(src, /await requireAdmin\(\)/);
  assert.match(src, /from\("coupon_metrics_daily"\)/);
  assert.match(src, /totals/);
  assert.match(src, /daily/);
  // Bounded window, validated coupon id — no unbounded scans, no raw interpolation.
  assert.match(src, /MAX_RANGE_DAYS = 90/);
  assert.match(src, /Math\.min\(Math\.max\(Math\.trunc\(requested\), 1\), MAX_RANGE_DAYS\)/);
  assert.match(src, /\/\^\[0-9a-f-\]\{36\}\$\/i\.test\(couponId\)/);
  // The browser never reads the table directly.
  assert.doesNotMatch(read("app/(admin)/coupons/page.tsx"), /coupon_metrics_daily/);
  assert.match(read("app/(admin)/coupons/page.tsx"), /\/api\/coupon-analytics/);
});

test("AC: analytics are labelled directional, never redemptions/sales/conversions", () => {
  const page = read("app/(admin)/coupons/page.tsx");
  assert.match(page, /مؤشرات استرشادية على التفاعل/);
  assert.match(page, /ليست أرقامًا محاسبية/);
  for (const banned of ["redemptions", "sales", "verified conversions", "conversions"]) {
    assert.ok(!page.toLowerCase().includes(banned), `the UI must not call these "${banned}"`);
  }
  assert.match(read("app/api/coupon-analytics/route.ts"), /classification: "directional"/);
});

/* --------------------------------------------------- AD: status boundaries */

test("AD: derived status matches the 0081 predicate exactly (inclusive/exclusive)", () => {
  const now = new Date("2026-08-15T12:00:00.000Z");
  const mk = (o) => ({ is_active: true, valid_from: "2026-08-01T00:00:00.000Z", valid_until: null, ...o });
  assert.equal(couponStatus(mk({}), now), "live");
  assert.equal(couponStatus(mk({ is_active: false }), now), "disabled");
  assert.equal(couponStatus(mk({ valid_from: "2026-09-01T00:00:00.000Z" }), now), "scheduled");
  assert.equal(couponStatus(mk({ valid_until: "2026-08-10T00:00:00.000Z" }), now), "expired");
  // valid_from is INCLUSIVE: live exactly at the boundary.
  assert.equal(couponStatus(mk({ valid_from: now.toISOString() }), now), "live");
  // valid_until is EXCLUSIVE: expired exactly at the boundary.
  assert.equal(couponStatus(mk({ valid_until: now.toISOString() }), now), "expired");
  // Disabled wins over any window.
  assert.equal(couponStatus(mk({ is_active: false, valid_from: "2026-09-01T00:00:00.000Z" }), now), "disabled");

  // The same three-part rule as the migration.
  const sql = readFileSync(new URL("../../supabase/migrations/0081_coupons.sql", import.meta.url), "utf8");
  assert.match(sql, /p_valid_from <= now\(\)/);
  assert.match(sql, /p_valid_until IS NULL OR p_valid_until > now\(\)/);
});

/* ------------------------------------------ safety: sorting + date semantics */

test("sorting uses a controlled enum, never a client-supplied column name", () => {
  assert.deepEqual(Object.keys(COUPON_SORTS).sort(), ["newest", "priority", "title", "updated", "validity"]);
  assert.equal(resolveSort("priority").column, "priority");
  assert.equal(resolveSort("../; drop table coupons").column, "priority", "unknown keys fall back");
  const src = read("app/api/coupons/route.ts");
  assert.match(src, /resolveSort\(params\.get\("sort"\)/);
  assert.doesNotMatch(src, /\.order\((?!sort\.column)[^)]*params\.get/);
});

test("dates: admin local input is converted to absolute UTC before persisting", () => {
  const page = read("app/(admin)/coupons/page.tsx");
  assert.match(page, /function localToIso/);
  assert.match(page, /new Date\(value\)\.toISOString\(\)/);
  assert.match(page, /فترة العرض الفعلية/);
  // The server rejects unparseable timestamps rather than assuming UTC.
  assert.equal(err(validateCouponPayload(base({ valid_from: "not-a-date" })), "valid_from"), "invalid_date");
  assert.equal(
    err(validateCouponPayload(base({ valid_until: "2026-07-01T00:00:00.000Z" })), "valid_until"),
    "window_ends_before_start",
  );
});

test("priority is bounded in the Admin layer (0081 has no CHECK; no migration added)", () => {
  assert.equal(err(validateCouponPayload(base({ priority: 5000 })), "priority"), "invalid_priority");
  assert.equal(err(validateCouponPayload(base({ priority: 1.5 })), "priority"), "invalid_priority");
  assert.equal(validateCouponPayload(base({ priority: -1000 })).ok, true);
  const sql = readFileSync(new URL("../../supabase/migrations/0081_coupons.sql", import.meta.url), "utf8");
  assert.doesNotMatch(sql, /CONSTRAINT coupons_priority/);
});

/* ------------------------------------------------- feature-flag independence */

test("the Admin page is not gated by enable_coupons (content is prepared first)", () => {
  const page = read("app/(admin)/coupons/page.tsx");
  assert.doesNotMatch(page, /enable_coupons/);
  assert.match(page, /قبل تشغيل الميزة على التطبيق/);
  for (const path of ROUTES) {
    assert.doesNotMatch(read(path), /feature_flags|enable_coupons/, "routes must not toggle the flag");
  }
});

/* --------------------------------------- contract consistency with 0081/0082 */

test("Admin output stays compatible with the 0081 schema and the catalog mapper", () => {
  const sql = readFileSync(new URL("../../supabase/migrations/0081_coupons.sql", import.meta.url), "utf8");
  const edge = readFileSync(
    new URL("../../supabase/functions/catalog-coupons/index.ts", import.meta.url), "utf8",
  );
  const value = validateCouponPayload(base({ partner_url: "https://example.com" })).value;

  // Every persisted key exists as a column in 0081.
  for (const key of Object.keys(value).filter((k) => !k.startsWith("__"))) {
    assert.match(sql, new RegExp(`\\b${key}\\b`), `0081 must define ${key}`);
  }
  // Shapes the Edge mapper requires.
  assert.equal(value.redemption_type, "code");
  assert.ok(value.code !== null, "code offers carry a code the mapper needs");
  assert.ok(String(value.partner_url).startsWith("https://"), "mapper drops non-https");
  assert.ok(Array.isArray(value.country_codes), "[] means global for both sides");
  assert.match(edge, /country_codes/);

  // A link offer produced by Admin satisfies the mapper's no-dual-authority rule.
  const link = validateCouponPayload(
    base({ redemption_type: "link", code: "", partner_url: "https://example.com" }),
  ).value;
  assert.equal(link.code, null);
  assert.match(edge, /type === 'link' && \(url === null \|\| code !== null\)/);

  // Admin analytics reads exactly the four 0082 events, in the same names.
  const analytics = read("app/api/coupon-analytics/route.ts");
  for (const ev of ["impression", "detail_view", "code_copy", "cta_click"]) {
    assert.match(analytics, new RegExp(`"${ev}"`), `analytics must know ${ev}`);
  }
  const m0082 = readFileSync(
    new URL("../../supabase/migrations/0082_coupon_metrics.sql", import.meta.url), "utf8",
  );
  assert.match(m0082, /'impression', 'detail_view', 'code_copy', 'cta_click'/);
});

/* ------------------------------- built-bundle proof (stronger than naming) */

test("Z2: the BUILT client bundle contains no service-role name or value", (t) => {
  // Scans the real build output when one exists (`npm run build`). It is not a
  // naming-convention check: it greps the emitted browser chunks.
  const staticDir = new URL("../.next/static/", import.meta.url);
  if (!existsSync(staticDir)) {
    t.skip("no .next/static build output present (run npm run build)");
    return;
  }
  const files = [];
  const walk = (dir) => {
    for (const entry of readdirSync(dir, { withFileTypes: true })) {
      const child = new URL(`${entry.name}${entry.isDirectory() ? "/" : ""}`, dir);
      if (entry.isDirectory()) walk(child);
      else if (/\.(js|json|css|map)$/.test(entry.name)) files.push(child);
    }
  };
  walk(staticDir);
  assert.ok(files.length > 0, "build output has client assets");

  // The secret's VALUE (when configured locally) and its NAME must both be absent.
  const envPath = new URL("../.env.local", import.meta.url);
  let secret = null;
  if (existsSync(envPath)) {
    const m = /^SUPABASE_SERVICE_ROLE_KEY=(.+)$/m.exec(readFileSync(envPath, "utf8"));
    if (m) secret = m[1].trim().replace(/^["']|["']$/g, "");
  }
  for (const file of files) {
    const content = readFileSync(file, "utf8");
    assert.ok(!content.includes("SERVICE_ROLE"), `${file.pathname} must not name the service role`);
    if (secret && secret.length > 20) {
      assert.ok(!content.includes(secret), `${file.pathname} must not embed the service-role key`);
    }
  }
});
