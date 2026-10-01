// WP5-Lite — the flag registry must agree with the RUNTIME. This test re-derives
// the reader inventory from the Dart app and the Edge Functions on every run, so
// a new getBool('x') or resolveUserBooleanFlag(…, 'x') that is not registered (or
// a registry entry that claims a reader that does not exist) fails CI.
import assert from "node:assert/strict";
import { readdirSync, readFileSync, statSync } from "node:fs";
import { join } from "node:path";
import test from "node:test";
import { FLAG_REGISTRY, flagMeta, missingRowKeys } from "../lib/flag-registry.ts";

const ROOT = new URL("../../", import.meta.url).pathname;

function walk(dir, ext, out = []) {
  for (const name of readdirSync(dir)) {
    const p = join(dir, name);
    const st = statSync(p);
    if (st.isDirectory()) {
      if (name === "node_modules" || name === ".dart_tool") continue;
      walk(p, ext, out);
    } else if (name.endsWith(ext)) out.push(p);
  }
  return out;
}
const stripLineComments = (src) => src.replace(/^\s*\/\/.*$/gm, "").replace(/\s\/\/.*$/gm, "");

const dartFiles = walk(join(ROOT, "app/lib"), ".dart").filter((f) => !f.endsWith("_test.dart"));
const tsFiles = walk(join(ROOT, "supabase/functions"), ".ts").filter(
  (f) => !/_test\.ts$|\.test\.ts$/.test(f),
);

function deriveAppReads() {
  const keys = new Set();
  const dynamicArgs = new Set();
  for (const file of dartFiles) {
    const src = stripLineComments(readFileSync(file, "utf8"));
    for (const m of src.matchAll(/\.\s*(getBool|getInt|getString|getJson)\(\s*([^)]*?)\s*\)/g)) {
      const arg = m[2];
      const lit = /^'([a-z0-9_]+)'$/.exec(arg);
      if (lit) keys.add(lit[1]);
      else if (arg) dynamicArgs.add(`${file.replace(ROOT, "")}:${arg}`);
    }
  }
  // The only dynamic read is AdPlacement.flagKey => 'enable_banner_<placement key>'.
  const placement = readFileSync(join(ROOT, "app/lib/features/ads/ad_placement.dart"), "utf8");
  const prefix = /String get flagKey => '(enable_banner_)\$key'/.exec(placement);
  assert.ok(prefix, "AdPlacement.flagKey spelling changed — update this scan");
  const enumBody = /enum AdPlacement[\s\S]*?;\s*\n\s*const AdPlacement/.exec(placement);
  assert.ok(enumBody, "AdPlacement enum shape changed — update this scan");
  const placementKeys = [...enumBody[0].matchAll(/\w+\('([a-z_]+)'\)/g)].map((m) => m[1]);
  assert.ok(placementKeys.length >= 6, "expected the six banner placements");
  for (const k of placementKeys) keys.add(`${prefix[1]}${k}`);
  return { keys, dynamicArgs, placementKeys };
}

function deriveServerReads() {
  const keys = new Set();
  for (const file of tsFiles) {
    const src = stripLineComments(readFileSync(file, "utf8"));
    for (const m of src.matchAll(/resolveUserBooleanFlag\(\s*[A-Za-z_.]+\s*,\s*'([a-z0-9_]+)'/g)) keys.add(m[1]);
  }
  return keys;
}

const appReads = deriveAppReads();
const serverReads = deriveServerReads();

test("derivation sanity: the scan finds the known readers", () => {
  for (const k of ["enable_coupons", "enable_proof_autocommit", "proof_parser_confidence_min", "enable_banner_dashboard"]) {
    assert.ok(appReads.keys.has(k), `app scan should find ${k}`);
  }
  for (const k of ["ledger_dual_write", "capture_direct_supabase_write", "transactions_supabase_primary"]) {
    assert.ok(serverReads.has(k), `server scan should find ${k}`);
  }
});

test("every app-side flag read is a literal key or AdPlacement.flagKey (nothing dynamic is unaccounted for)", () => {
  const unexpected = [...appReads.dynamicArgs].filter((a) => !/placement\.flagKey$/.test(a));
  assert.deepEqual(unexpected, [], "a dynamic flag read the registry cannot know about");
});

test("every read key is registered with the correct readers", () => {
  for (const key of new Set([...appReads.keys, ...serverReads])) {
    const meta = FLAG_REGISTRY[key];
    assert.ok(meta, `${key} is read by code but missing from the registry`);
    assert.equal(meta.readers.includes("app"), appReads.keys.has(key), `${key}: app reader mismatch`);
    assert.equal(meta.readers.includes("server"), serverReads.has(key), `${key}: server reader mismatch`);
  }
});

test("every registry entry's claimed readers exist, and not_wired keys have NO reader", () => {
  for (const [key, meta] of Object.entries(FLAG_REGISTRY)) {
    const app = appReads.keys.has(key);
    const server = serverReads.has(key);
    assert.deepEqual(meta.readers, [app && "app", server && "server"].filter(Boolean), `${key}: readers`);
    if (meta.status === "not_wired") {
      assert.equal(meta.readers.length, 0, `${key} is not_wired but has a reader`);
      assert.equal(meta.rolloutSemantics, "none", `${key}: not_wired must have rolloutSemantics none`);
    } else {
      assert.ok(meta.readers.length > 0, `${key} is wired but has no reader`);
    }
    const expectedStatus =
      meta.status === "retired_but_read" ? "retired_but_read" : app && server ? "both" : app ? "app_read" : server ? "server_read" : "not_wired";
    assert.equal(meta.status, expectedStatus, `${key}: status`);
    assert.equal(
      meta.rolloutSemantics,
      server ? "server_all_or_nothing" : app ? "app_percent_country" : "none",
      `${key}: rollout semantics`,
    );
  }
});

test("not_wired keys appear in code only as FeatureFlagService._defaults seeds (never read)", () => {
  const notWired = Object.entries(FLAG_REGISTRY).filter(([, m]) => m.status === "not_wired").map(([k]) => k);
  assert.ok(notWired.length >= 20);
  for (const key of notWired) {
    for (const file of [...dartFiles, ...tsFiles]) {
      const src = stripLineComments(readFileSync(file, "utf8"));
      const lines = src.split("\n").filter((l) => l.includes(`'${key}'`) || l.includes(`"${key}"`));
      for (const line of lines) {
        assert.ok(
          file.endsWith("feature_flag_service.dart") && new RegExp(`^\\s*'${key}':`).test(line),
          `${key} is referenced outside the defaults map in ${file}: ${line.trim()}`,
        );
      }
    }
  }
});

test("server-read flags: retired_but_read is high risk and all-or-nothing; the three money-path keys are high", () => {
  for (const k of ["ledger_dual_write", "capture_direct_supabase_write", "transactions_supabase_primary", "enable_proof_autocommit"]) {
    assert.equal(FLAG_REGISTRY[k].risk, "high", k);
  }
  for (const k of ["capture_direct_supabase_write", "transactions_supabase_primary"]) {
    assert.equal(FLAG_REGISTRY[k].status, "retired_but_read");
    assert.equal(FLAG_REGISTRY[k].rolloutSemantics, "server_all_or_nothing");
  }
  assert.equal(FLAG_REGISTRY.enable_proof_autocommit.unsafeToArm, true);
  assert.match(FLAG_REGISTRY.enable_proof_autocommit.notes, /يُرفع الحظر فقط عند ربط محرك الإثبات/);
  assert.deepEqual(FLAG_REGISTRY.proof_parser_confidence_min.intRange, [991, 1000]);
  assert.ok(FLAG_REGISTRY.ai_sender_mapping_auto.dependencies?.join(" ").includes("0100"));
});

test("labels.ts no longer calls a still-read key 'retired / no effect'", () => {
  const labels = readFileSync(new URL("../lib/labels.ts", import.meta.url), "utf8");
  const set = /RETIRED_FLAG_KEYS = new Set\(\[([\s\S]*?)\]\)/.exec(labels)[1];
  for (const key of serverReads) assert.ok(!set.includes(`"${key}"`), `${key} is still read but labelled retired`);
  for (const key of [...set.matchAll(/"([a-z_]+)"/g)].map((m) => m[1])) {
    assert.equal(flagMeta(key).status, "not_wired", `${key} retired in labels but wired in registry`);
  }
});

test("missing-row list = wired registry keys without a DB row; never auto-creates not_wired", () => {
  const missing = missingRowKeys(["enable_coupons"]);
  assert.ok(missing.includes("enable_referrals"));
  assert.ok(!missing.includes("enable_coupons"));
  assert.ok(!missing.includes("enable_goals"), "not_wired keys are never offered for creation");
});
