// WP5-Lite — feature-flag admin API, planner and page contracts.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import {
  buildPlan,
  editableFields,
  isBulkEligible,
  previewPlan,
  validateValue,
} from "../lib/flag-registry.ts";
import { isRpcNotDeployed, rpcErrorStatus } from "../lib/feature-flags-server.ts";

const read = (p) => readFileSync(new URL(`../${p}`, import.meta.url), "utf8");
const T0 = "2026-01-01T00:00:00+00:00";
const row = (key, over = {}) => ({
  key, value_type: "boolean", value: "false", description: null,
  rollout_percent: 0, target_countries: [], is_active: false, updated_at: T0, ...over,
});
const codes = (plan) => plan.errors.map((e) => e.code);

// ── routes ───────────────────────────────────────────────────────────────────
const ROUTES = [
  "app/api/feature-flags/route.ts",
  "app/api/feature-flags/preview/route.ts",
  "app/api/feature-flags/apply/route.ts",
];

test("every feature-flag route calls requireAdmin and maps auth errors (never 500)", () => {
  for (const path of ROUTES) {
    const src = read(path);
    const handlers = [...src.matchAll(/export async function (GET|POST)[\s\S]*?(?=export async function|$)/g)];
    assert.ok(handlers.length > 0, path);
    for (const h of handlers) {
      assert.match(h[0], /try\s*{\s*(user = )?await requireAdmin\(\);\s*}\s*catch \(e\) {\s*return adminAuthErrorResponse\(e\);/, `${path} ${h[1]}`);
    }
  }
  const auth = read("lib/auth-guard.ts");
  for (const s of ["401", "403", "503"]) assert.match(auth, new RegExp(`status: ${s}`));
});

test("admin-data: every handler wraps requireAdmin; feature_flags can no longer be PATCHed", () => {
  const src = read("app/api/admin-data/route.ts");
  const handlers = [...src.matchAll(/export async function (GET|POST|PATCH|DELETE)[\s\S]*?(?=export async function|$)/g)];
  assert.equal(handlers.length, 4);
  for (const h of handlers) {
    assert.match(h[0], /catch \(e\) {\s*return adminAuthErrorResponse\(e\);/, `${h[1]} must map auth errors`);
  }
  assert.doesNotMatch(src, /from\("feature_flags"\)\.update/);
  assert.match(src, /resource === "feature_flags"[\s\S]{0,200}405/);
});

test("apply re-validates server-side and only writes through the RPC with the admin's id", () => {
  const src = read("app/api/feature-flags/apply/route.ts");
  assert.match(src, /buildPlan\(/);
  assert.match(src, /rpc\("admin_apply_feature_flag_changes"/);
  assert.match(src, /p_actor: user\.id/);
  assert.match(src, /p_operation_id: body\.operation_id/);
  assert.doesNotMatch(src, /from\("feature_flags"\)\s*\.\s*(update|insert|upsert|delete)/);
  assert.match(read("lib/feature-flags-server.ts"), /case "P0409":\s*return 409/);
  assert.doesNotMatch(read("app/api/feature-flags/preview/route.ts"), /\.rpc\(|\.update\(|\.insert\(/);
});

// ── validation ───────────────────────────────────────────────────────────────
const one = (key, set, rows = [row(key)], extra = {}) =>
  buildPlan(rows, [{ key, expected_updated_at: T0, set, ...extra }]);

test("rollout 150 is rejected; fractions too", () => {
  assert.ok(codes(one("enable_coupons", { rollout_percent: 150 })).includes("rollout_percent_invalid"));
  assert.ok(codes(one("enable_coupons", { rollout_percent: 10.5 })).includes("rollout_percent_invalid"));
  assert.ok(one("enable_coupons", { rollout_percent: 40 }).ok);
});

test("value_type mismatch is rejected", () => {
  assert.ok(codes(one("enable_coupons", { value: "banana" })).includes("value_type_mismatch"));
  assert.equal(validateValue("number", "12x"), "value_type_mismatch");
  assert.equal(validateValue("json", "{bad"), "value_type_mismatch");
  assert.equal(validateValue("boolean", "true"), null);
  const num = row("proof_parser_confidence_min", { value_type: "number", value: "1000" });
  assert.ok(codes(one("proof_parser_confidence_min", { value: "abc" }, [num])).includes("value_type_mismatch"));
});

test("proof_parser_confidence_min only accepts 991..1000", () => {
  const num = row("proof_parser_confidence_min", { value_type: "number", value: "1000" });
  assert.ok(codes(one("proof_parser_confidence_min", { value: "990" }, [num])).includes("value_out_of_range"));
  assert.ok(codes(one("proof_parser_confidence_min", { value: "99" }, [num])).includes("value_out_of_range"));
  const ok = buildPlan([num], [{ key: "proof_parser_confidence_min", expected_updated_at: T0, set: { value: "995" } }], { typedConfirmation: "proof_parser_confidence_min" });
  assert.ok(ok.ok, JSON.stringify(ok.errors));
});

test("bad country codes are rejected; ISO alpha-2 upper-case accepted", () => {
  for (const bad of [["eg"], ["EGY"], ["E1"], [1], ["EG", "EG"]]) {
    assert.ok(codes(one("enable_coupons", { target_countries: bad })).includes("target_country_invalid"), JSON.stringify(bad));
  }
  assert.ok(one("enable_coupons", { target_countries: ["EG", "SA"] }).ok);
});

test("server-read flags reject partial rollout, countries, and activation without full rollout", () => {
  const r = row("ledger_dual_write");
  const arm = (set) => buildPlan([r], [{ key: "ledger_dual_write", expected_updated_at: T0, set }], { typedConfirmation: "ledger_dual_write" });
  assert.ok(codes(arm({ rollout_percent: 50 })).includes("server_read_partial_rollout_unsupported"));
  assert.ok(codes(arm({ target_countries: ["EG"] })).includes("field_not_editable"), "countries are not even an editable field for server-read flags");
  assert.ok(codes(arm({ is_active: true, value: "true" })).includes("server_read_requires_full_rollout"));
  assert.ok(arm({ is_active: true, value: "true", rollout_percent: 100 }).ok);
  assert.ok(!editableFields("ledger_dual_write").includes("target_countries"));
  assert.ok(editableFields("enable_coupons").includes("target_countries"));
  // RPC marks server-read keys
  assert.equal(arm({ is_active: true, value: "true", rollout_percent: 100 }).rpcChanges[0].server_read, true);
});

test("not_wired: only description is editable; unregistered keys are read-only too", () => {
  assert.deepEqual(editableFields("ledger_push_sync"), ["description"]);
  assert.ok(codes(one("ledger_push_sync", { is_active: true })).includes("not_wired_description_only"));
  assert.ok(one("ledger_push_sync", { description: "no effect" }).ok);
  assert.ok(codes(one("some_new_key", { is_active: true })).includes("unregistered_flag"));
  assert.ok(codes(buildPlan([], [{ key: "ledger_push_sync", create: true, set: {} }])).includes("not_wired_cannot_create"));
});

test("stale concurrency input and missing expected_updated_at are rejected before the RPC", () => {
  const p = buildPlan([row("enable_coupons")], [{ key: "enable_coupons", set: { is_active: true } }]);
  assert.ok(codes(p).includes("expected_updated_at_required"));
});

test("create: inactive only, defaults only, never for an existing key", () => {
  const p = buildPlan([], [{ key: "enable_referrals", create: true, set: {} }]);
  assert.ok(p.ok, JSON.stringify(p.errors));
  assert.equal(p.rpcChanges[0].create, true);
  assert.equal(p.rpcChanges[0].value_type, "boolean");
  assert.ok(codes(buildPlan([], [{ key: "enable_referrals", create: true, set: { is_active: true } }])).includes("create_must_be_inactive"));
  assert.ok(codes(buildPlan([row("enable_referrals")], [{ key: "enable_referrals", create: true, set: {} }])).includes("flag_exists"));
});

// ── bulk ─────────────────────────────────────────────────────────────────────
test("bulk excludes not_wired (and high-risk / unregistered) flags", () => {
  assert.equal(isBulkEligible("enable_coupons"), true);
  assert.equal(isBulkEligible("enable_banner_goals"), true);
  for (const k of ["ledger_push_sync", "planning_goals_sync", "enable_goals", "enable_proof_autocommit", "ledger_dual_write", "transactions_supabase_primary", "brand_new_key"]) {
    assert.equal(isBulkEligible(k), false, k);
  }
  const rows = [row("enable_coupons"), row("ledger_push_sync")];
  const p = buildPlan(rows, [
    { key: "enable_coupons", expected_updated_at: T0, set: { is_active: true } },
    { key: "ledger_push_sync", expected_updated_at: T0, set: { is_active: true } },
  ]);
  assert.ok(!p.ok);
  assert.ok(codes(p).some((c) => c === "bulk_ineligible" || c === "not_wired_description_only"));
  const ok = buildPlan([row("enable_coupons"), row("enable_referrals")], [
    { key: "enable_coupons", expected_updated_at: T0, set: { is_active: true } },
    { key: "enable_referrals", expected_updated_at: T0, set: { is_active: true } },
  ]);
  assert.ok(ok.ok, JSON.stringify(ok.errors));
  // the page has no "enable all sync" action and only shows checkboxes for eligible flags
  const page = read("app/(admin)/flags/page.tsx");
  assert.match(page, /isBulkEligible\(flag\.key\) &&/);
  assert.doesNotMatch(page, /Enable all|تفعيل كل المزامنة|enableAll/i);
});

// ── high risk ────────────────────────────────────────────────────────────────
test("high-risk changes need the typed key; bulk with a high-risk key is refused", () => {
  const rows = [row("enable_proof_autocommit")];
  const req = [{ key: "enable_proof_autocommit", expected_updated_at: T0, set: { is_active: true, value: "true", rollout_percent: 100 } }];
  const hr = [row("local_auto_confirm_v2")];
  const hrReq = [{ key: "local_auto_confirm_v2", expected_updated_at: T0, set: { is_active: true, value: "true", rollout_percent: 100 } }];
  assert.ok(codes(buildPlan(hr, hrReq)).includes("typed_confirmation_required"));
  assert.ok(codes(buildPlan(hr, hrReq, { typedConfirmation: "wrong" })).includes("typed_confirmation_required"));
  assert.ok(buildPlan(hr, hrReq, { typedConfirmation: "local_auto_confirm_v2" }).ok);
  assert.ok(previewPlan(hr, hrReq).ok);
  // enable_proof_autocommit is hard-blocked: even the correct typed key cannot arm it
  const armed = buildPlan(rows, req, { typedConfirmation: "enable_proof_autocommit" });
  assert.ok(codes(armed).includes("unsafe_to_arm"));
  assert.ok(codes(previewPlan(rows, req)).includes("unsafe_to_arm"));
  const armValue = [{ key: "enable_proof_autocommit", expected_updated_at: T0, set: { is_active: true, value: "true", rollout_percent: 10 } }];
  assert.ok(codes(buildPlan(rows, armValue, { typedConfirmation: "enable_proof_autocommit" })).includes("unsafe_to_arm"));
  // turning it OFF and editing the description stay allowed (typed key still required: high risk)
  const on = [row("enable_proof_autocommit", { is_active: true, value: "true", rollout_percent: 100 })];
  const off = buildPlan(on, [{ key: "enable_proof_autocommit", expected_updated_at: T0, set: { is_active: false } }], { typedConfirmation: "enable_proof_autocommit" });
  assert.ok(off.ok, JSON.stringify(off.errors));
  const desc = buildPlan(on, [{ key: "enable_proof_autocommit", expected_updated_at: T0, set: { description: "note" } }], { typedConfirmation: "enable_proof_autocommit" });
  assert.ok(desc.ok, JSON.stringify(desc.errors));
  assert.deepEqual(off.highRiskKeys, ["enable_proof_autocommit"]);
  // bulk
  const bulk = buildPlan([...rows, row("enable_coupons")], [...req, { key: "enable_coupons", expected_updated_at: T0, set: { is_active: true } }], { typedConfirmation: "enable_proof_autocommit" });
  assert.ok(codes(bulk).includes("bulk_ineligible"));
  // the page requires typing and apply passes it through
  assert.match(read("app/(admin)/flags/page.tsx"), /modal\.typed\.trim\(\) === modalHigh/);
  assert.match(read("app/api/feature-flags/apply/route.ts"), /typedConfirmation: body\.typed_confirmation/);
});

test("ai_sender_mapping_auto carries its 0100 dependency warning; preview probes the column", () => {
  const p = buildPlan([row("ai_sender_mapping_auto")], [{ key: "ai_sender_mapping_auto", expected_updated_at: T0, set: { is_active: true, value: "true", rollout_percent: 100 } }]);
  assert.ok(p.warnings.some((w) => w.code === "has_dependency" && w.detail.includes("0100")));
  assert.match(read("app/api/feature-flags/preview/route.ts"), /acceptedByColumnExists/);
});

test("no-op edits are rejected", () => {
  assert.ok(codes(one("enable_coupons", { is_active: false })).includes("no_effective_changes"));
});

// ── migration contract (static) ──────────────────────────────────────────────
test("0101 is deferred, gapless-safe, service-role-only, append-only, idempotent", () => {
  const sql = read("../supabase/deferred/0101_feature_flag_admin_audit.sql");
  assert.match(sql, /REVOKE ALL ON FUNCTION public\.admin_apply_feature_flag_changes\(UUID, TEXT, UUID, JSONB\)\s+FROM PUBLIC, anon, authenticated/);
  assert.match(sql, /GRANT EXECUTE ON FUNCTION public\.admin_apply_feature_flag_changes[\s\S]*TO service_role/);
  assert.match(sql, /REVOKE ALL ON TABLE public\.feature_flag_admin_audit FROM PUBLIC, anon, authenticated/);
  assert.match(sql, /ENABLE ROW LEVEL SECURITY/);
  assert.match(sql, /pg_advisory_xact_lock/);
  assert.match(sql, /FOR UPDATE/);
  assert.match(sql, /admin_can_change_flag/);
  assert.match(sql, /set_updated_at\(\)/);
  assert.doesNotMatch(sql.replace(/^--.*$/gm, ""), /updated_by/, "no actor column on feature_flags (anon SELECT policy)");
  assert.match(sql, /RAISE EXCEPTION 'unsafe_to_arm: %'/);
  assert.match(sql, /BETWEEN 4 AND 500/);
  assert.match(read("../supabase/deferred/README.md"), /0101_feature_flag_admin_audit\.sql — DEFERRED/);
});

test("apply: RPC not deployed (PGRST202 / 42883) -> 503 audit_not_deployed, no console.error", () => {
  assert.equal(isRpcNotDeployed("PGRST202"), true);
  assert.equal(isRpcNotDeployed("42883"), true);
  assert.equal(isRpcNotDeployed("P0409"), false);
  assert.equal(isRpcNotDeployed(undefined), false);
  assert.equal(rpcErrorStatus("PGRST202"), 500); // would be noisy 500 without the dedicated branch
  const src = read("app/api/feature-flags/apply/route.ts");
  const i = src.indexOf("isRpcNotDeployed(error.code)");
  assert.ok(i > 0);
  assert.match(src.slice(i, i + 200), /audit_not_deployed[\s\S]*status: 503/);
  assert.ok(i < src.indexOf("console.error"), "not-deployed branch must precede console.error");
});
