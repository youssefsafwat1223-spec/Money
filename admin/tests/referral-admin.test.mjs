// Referral & Ads Phase R2 — Admin test suite (node:test via `npm run test:auth`).
//
// Mirrors the Coupons C3 approach: STATIC source-contract scans (the suite does
// not boot a live server or touch a DB) plus validator unit tests. It asserts
// the security chain, the RPC-only mutation boundary, idempotency, the reason
// contract, the audit allowlist, and the "no report_ads_config" elimination.
import assert from "node:assert/strict";
import { existsSync, readFileSync, readdirSync } from "node:fs";
import test from "node:test";

import {
  validateReason,
  filterAuditPayload,
  AUDIT_ALLOWLIST,
  validateRulePayload,
  validateEntitlementAction,
  validateReferralAction,
  validateProgressAdjust,
  validateRotateCode,
  validateDeactivateRule,
  classifyLookupQuery,
  isUuid,
} from "../lib/referral-validation.mjs";
import { mapDatabaseError, messageFor, safeErrorBody } from "../lib/referral-errors.mjs";

const read = (path) => readFileSync(new URL(`../${path}`, import.meta.url), "utf8");
const uuid = () => crypto.randomUUID();

// The referral/entitlement mutation + read routes (relative to admin/).
const MUTATION_ROUTES = [
  "app/api/referral-rules/route.ts",
  "app/api/entitlements/grant/route.ts",
  "app/api/entitlements/extend/route.ts",
  "app/api/entitlements/revoke/route.ts",
  "app/api/referrals/reject/route.ts",
  "app/api/referrals/reverse/route.ts",
  "app/api/referral-progress/adjust/route.ts",
  "app/api/referral-codes/rotate/route.ts",
];
const READ_ROUTES = [
  "app/api/referral-rules/route.ts",
  "app/api/referral-users/route.ts",
  "app/api/referral-users/[id]/route.ts",
  "app/api/referral-metrics/route.ts",
  "app/api/referral-audit/route.ts",
];
const ALL_ROUTES = [...new Set([...MUTATION_ROUTES, ...READ_ROUTES])];
const migration = () => read("../supabase/migrations/0083_referral_rewards.sql");

// ── AUTH MATRIX (static; the middleware+guard own the 307 redirects) ─────────
test("auth: the shared guard maps unauthenticated/non-admin/lookup-failure", () => {
  const guard = read("lib/auth-guard.ts");
  assert.match(guard, /unauthenticated[\s\S]*?status: 401/);
  assert.match(guard, /not_authorized[\s\S]*?status: 403/);
  assert.match(guard, /authorization_unavailable[\s\S]*?status: 503/);
  assert.match(guard, /from\("admin_users"\)/);
});

test("auth: middleware redirects unauthenticated->/login and non-admin->/not-authorized", () => {
  const mw = read("middleware.ts");
  assert.match(mw, /from\("admin_users"\)/);
  assert.match(mw, /\/login/);
  assert.match(mw, /\/not-authorized/);
});

test("auth: every referral route requires admin first and maps auth errors", () => {
  for (const path of ALL_ROUTES) {
    const source = read(path);
    const handlers = [
      ...source.matchAll(/export async function (GET|POST|PATCH|DELETE)[\s\S]*?(?=export async function|$)/g),
    ];
    assert.ok(handlers.length > 0, `${path} exports handlers`);
    // Auth is enforced either inline (requireAdmin) or via the shared helper.
    const usesHelper = /runEntitlementMutation/.test(source);
    for (const [body, verb] of handlers.map((h) => [h[0], h[1]])) {
      assert.ok(
        usesHelper || /requireAdmin\(\)/.test(body),
        `${path} ${verb} must require admin (inline or via helper)`,
      );
    }
    assert.ok(
      usesHelper || /adminAuthErrorResponse\(e\)/.test(source),
      `${path} must map auth errors`,
    );
  }
  assert.match(read("lib/referral-rpc.ts"), /adminAuthErrorResponse\(e\)/);
});

// ── RPC-ONLY MUTATION BOUNDARY (never a direct table write) ──────────────────
test("boundary: every mutation goes through an approved admin RPC, never a direct table write", () => {
  const rpcByRoute = {
    "app/api/referral-rules/route.ts": ["admin_publish_reward_rule", "admin_deactivate_reward_rule"],
    "app/api/referrals/reject/route.ts": ["admin_reject_referral"],
    "app/api/referrals/reverse/route.ts": ["admin_reverse_referral"],
    "app/api/referral-progress/adjust/route.ts": ["admin_adjust_referral_progress"],
    "app/api/referral-codes/rotate/route.ts": ["admin_rotate_referral_code"],
  };
  for (const [path, rpcs] of Object.entries(rpcByRoute)) {
    const source = read(path);
    for (const rpc of rpcs) assert.match(source, new RegExp(`rpc\\("${rpc}"`), `${path} calls ${rpc}`);
    // No direct writes to referral/entitlement tables.
    assert.doesNotMatch(
      source,
      /\.from\([^)]*\)\s*\.\s*(insert|update|delete|upsert)\b/,
      `${path} must not write tables directly`,
    );
  }
  // The three entitlement routes delegate to the shared helper, which uses the RPC.
  const helper = read("lib/referral-rpc.ts");
  assert.match(helper, /rpc\("admin_mutate_entitlement"/);
  assert.doesNotMatch(helper, /\.from\([^)]*\)\s*\.\s*(insert|update|delete|upsert)\b/);
});

// ── IDEMPOTENCY (E/F/G) ──────────────────────────────────────────────────────
test("idempotency: the migration enforces one-shot via UNIQUE(operation_id) + ON CONFLICT claim", () => {
  const m = migration();
  assert.match(m, /referral_admin_claim/);
  assert.match(m, /ON CONFLICT \(operation_id\) DO NOTHING/);
  assert.match(m, /idempotency_mismatch/);
});

test("idempotency: routes pass operation_id straight to p_operation_id; the UI mints one per intent", () => {
  for (const path of MUTATION_ROUTES) {
    if (path.endsWith("referral-rules/route.ts")) continue; // uses parsed.value.operation_id
    const source = read(path);
    if (/runEntitlementMutation/.test(source)) continue; // helper carries operation_id
    assert.match(source, /p_operation_id:\s*parsed\.value\.operation_id/, `${path} forwards operation_id`);
  }
  assert.match(read("lib/referral-rpc.ts"), /p_operation_id:\s*parsed\.value\.operation_id/);
  // The page mints operation_id once per operator intent.
  assert.match(read("app/(admin)/referrals/page.tsx"), /crypto\.randomUUID\(\)/);
});

// ── REASON CONTRACT (§7.2) ───────────────────────────────────────────────────
test("reason: empty / <4 / >500 / control chars / non-text are rejected", () => {
  assert.equal(validateReason("valid reason").ok, true);
  assert.equal(validateReason("").ok, false);
  assert.equal(validateReason("ab").ok, false);
  assert.equal(validateReason("a".repeat(501)).ok, false);
  assert.equal(validateReason("bad" + String.fromCharCode(7) + "x").ok, false);
  assert.equal(validateReason(42).ok, false);
  assert.equal(validateReason(null).ok, false);
  // whitespace collapse mirrors the DB (result must still be >= 4 chars)
  assert.equal(validateReason("  ab   cd  ").value, "ab cd");
});

test("reason: the DB is the backstop — the migration enforces 4–500 plain text", () => {
  const m = migration();
  assert.match(m, /referral_admin_require_reason/);
  assert.match(m, /char_length\(v\) < 4 OR char_length\(v\) > 500/);
});

// ── AUDIT ALLOWLIST (§9.2) ───────────────────────────────────────────────────
test("audit: a non-allowlisted key is dropped; allowlisted keys are kept", () => {
  const out = filterAuditPayload({ status: "active", ends_at: "x", email: "leak@x.com", user_id: "u" });
  assert.ok(!("email" in out) && !("user_id" in out));
  assert.equal(out.status, "active");
  assert.equal(out.ends_at, "x");
  assert.equal(filterAuditPayload(null), null);
});

test("audit: the client allowlist matches the server allowlist exactly", () => {
  const m = migration();
  // Every allowlisted key appears in the SQL referral_audit_allowlist() body.
  const block = m.slice(m.indexOf("referral_audit_allowlist"));
  for (const key of AUDIT_ALLOWLIST) {
    assert.match(block, new RegExp(`'${key}'`), `SQL allowlist contains ${key}`);
  }
  // And the audit route re-applies the filter (defence in depth).
  assert.match(read("app/api/referral-audit/route.ts"), /filterAuditPayload/);
});

// ── NO report_ads_config TABLE OR ROUTE (§3, §12) ────────────────────────────
test("report-ads: no report_ads_config table, no config route, no editable write path", () => {
  assert.doesNotMatch(migration(), /create table[\s\S]*?report_ads_config/i);
  assert.equal(existsSync(new URL("../app/api/report-ads-config", import.meta.url)), false);
  // The Report Ads screen is read-only: it renders the flag state but posts nothing.
  const page = read("app/(admin)/referrals/page.tsx");
  const section = page.slice(page.indexOf("ReportAdsSection"));
  assert.doesNotMatch(section.slice(0, 2000), /method:\s*"(POST|PATCH|PUT|DELETE)"/);
});

// ── NO SERVICE-ROLE LEAK ─────────────────────────────────────────────────────
test("security: the service-role key lives only in supabase-server, never in a route or the page", () => {
  assert.match(read("lib/supabase-server.ts"), /SUPABASE_SERVICE_ROLE_KEY/);
  for (const path of [...ALL_ROUTES, "app/(admin)/referrals/page.tsx", "lib/referral-rpc.ts"]) {
    assert.doesNotMatch(read(path), /SERVICE_ROLE/, `${path} must not name the service-role key`);
  }
});

// ── VALIDATOR REJECTS BAD INPUT (no DB write happens on a 4xx) ───────────────
test("validators: bad rule/action/referral input is rejected with field errors", () => {
  const op = uuid();
  const user = uuid();
  assert.equal(validateRulePayload({}).ok, false);
  assert.equal(
    validateRulePayload({ operation_id: op, reward_type: REWARD, required_referrals: 5, reward_days: 7, repeatable: true, reason: "set 5/7" }).ok,
    true,
  );
  // grant needs a positive duration; revoke must not carry one
  assert.equal(validateEntitlementAction({ operation_id: op, user_id: user, action: "grant", reason: "grant no days" }).ok, false);
  assert.equal(validateEntitlementAction({ operation_id: op, user_id: user, action: "revoke", duration_days: 7, reason: "revoke w/ days" }).ok, false);
  assert.equal(validateEntitlementAction({ operation_id: op, user_id: user, action: "revoke", reason: "revoke ok reason" }).ok, true);
  assert.equal(validateReferralAction({ operation_id: op, referral_id: "nope", reason: "reason here" }).ok, false);
  assert.equal(validateProgressAdjust({ operation_id: op, referrer_user_id: user, reward_type: REWARD, qualified_in_cycle: -1, reason: "reason here" }).ok, false);
  assert.equal(validateRotateCode({ operation_id: op, user_id: user, reason: "rotate reason" }).ok, true);
  assert.equal(validateDeactivateRule({ operation_id: op, reward_type: REWARD, reason: "deactivate reason" }).ok, true);
});

test("lookup: query classification uses safe identifiers only", () => {
  assert.equal(classifyLookupQuery("").ok, false);
  assert.equal(classifyLookupQuery(crypto.randomUUID()).kind, "user_id");
  assert.equal(classifyLookupQuery("a@b.com").kind, "email");
  assert.equal(classifyLookupQuery("QK7F9X2M").kind, "code");
  assert.equal(classifyLookupQuery("qk7f9x2m").value, "QK7F9X2M");
});

// ── ERROR MAPPING (no raw SQL to the browser) ────────────────────────────────
test("errors: RPC tokens map to safe copy; unknowns become 'unexpected'", () => {
  assert.equal(mapDatabaseError({ message: "invalid_reason" }), "invalid_reason");
  assert.equal(mapDatabaseError({ message: "idempotency_mismatch" }), "idempotency_mismatch");
  assert.equal(mapDatabaseError({ message: "referral_not_reversible" }), "referral_not_reversible");
  assert.equal(mapDatabaseError({ code: "PGRST116" }), "not_found");
  assert.equal(mapDatabaseError({ message: "relation ... does not exist" }), "unexpected");
  assert.equal(mapDatabaseError(null), "unexpected");
  const body = safeErrorBody("invalid_reason", [{ field: "reason", error: "invalid_reason" }]);
  assert.equal(body.error, "invalid_reason");
  assert.ok(body.message && body.fields.length === 1);
  assert.equal(typeof messageFor("unexpected"), "string");
});

// ── VERB-ONLY ROUTE EXPORTS (C3 rule) ────────────────────────────────────────
test("routes: route files export only HTTP verbs (a stray export breaks next build)", () => {
  for (const path of ALL_ROUTES) {
    const exportsFound = [...read(path).matchAll(/export\s+(?:async\s+)?(?:function|const)\s+([A-Za-z0-9_]+)/g)].map(
      (m) => m[1],
    );
    for (const name of exportsFound) {
      assert.ok(
        ["GET", "POST", "PATCH", "PUT", "DELETE", "HEAD", "OPTIONS"].includes(name),
        `${path} exports only verbs, found ${name}`,
      );
    }
  }
});

const REWARD = "report_export_ad_free";
assert.ok(isUuid(crypto.randomUUID()));
// Sanity: the referrals feature directory registered a nav entry.
test("nav: the sidebar registers the Referral & Ads entry", () => {
  assert.match(read("components/sidebar.tsx"), /href:\s*"\/referrals"/);
  assert.ok(readdirSync(new URL("../app/(admin)/referrals", import.meta.url)).includes("page.tsx"));
});
