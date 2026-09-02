import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

// Phase-7 Batch-1 — the skip/ignore manifest checker (tools/check_test_skips.mjs) must
// FAIL on an unexpected skip, an expected skip that disappeared, and partial/malformed
// credentials. Runs the checker as a subprocess (no recursion into node --test).

const root = process.cwd();
const checker = join(root, "tools/check_test_skips.mjs");

function runChecker({ tap, deno, env = {} }) {
  const dir = mkdtempSync(join(tmpdir(), "skipman-"));
  const args = [];
  if (tap != null) {
    const p = join(dir, "node.tap");
    writeFileSync(p, tap);
    args.push("--node", p);
  }
  if (deno != null) {
    const p = join(dir, "deno.txt");
    writeFileSync(p, deno);
    args.push("--deno", p);
  }
  return spawnSync("node", [checker, ...args], {
    cwd: root,
    encoding: "utf8",
    // Start from a clean credential env, then apply overrides.
    env: {
      ...process.env,
      SUPABASE_URL: "",
      SUPABASE_ANON_KEY: "",
      SUPABASE_SERVICE_ROLE_KEY: "",
      ...env,
    },
  });
}

// A minimal valid node TAP: one skip matching EVERY manifest entry.
//
// It must cover every entry, not merely one per credential group: the checker
// also fails an entry that matches NOTHING, so that a manifest line outliving
// the test it excused is caught rather than quietly accumulating. That means
// this fixture has to grow whenever the manifest does — which is the point, and
// is how the 0093/0094 entry was caught the day it was added.
const validTap = [
  "TAP version 13",
  "ok 1 - a purge test # SKIP requires SUPABASE_URL, SUPABASE_ANON_KEY, and SUPABASE_SERVICE_ROLE_KEY",
  "ok 2 - a process-ios-sms test # SKIP requires SUPABASE_URL + SUPABASE_ANON_KEY (deployed process-ios-sms)",
  "ok 3 - a storage test # SKIP requires SUPABASE_URL + SUPABASE_ANON_KEY + SUPABASE_SERVICE_ROLE_KEY and a project with migrations 0075+0076 + the backups bucket deployed",
  "ok 4 - a coupons catalog test # SKIP requires SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY (live PostgreSQL: migrations 0093/0094 must be applied)",
].join("\n");

test("valid manifest-matched skips with credentials ABSENT → pass", () => {
  const r = runChecker({ tap: validTap });
  assert.equal(r.status, 0, r.stdout + r.stderr);
});

test("an UNEXPECTED skip fails", () => {
  const bad = validTap + "\nok 9 - mystery test # SKIP no reason";
  const r = runChecker({ tap: bad });
  assert.equal(r.status, 1);
  assert.match(r.stderr, /UNEXPECTED node skip/);
});

test("PARTIAL/malformed credentials fail (not a silent skip)", () => {
  const r = runChecker({ tap: validTap, env: { SUPABASE_URL: "https://x" } });
  assert.equal(r.status, 1);
  assert.match(r.stderr, /PARTIAL\/malformed/);
});

test("credentials PRESENT but the test still skipped → fail (must run)", () => {
  const r = runChecker({
    tap: "ok 1 - a purge test # SKIP requires SUPABASE_URL, SUPABASE_ANON_KEY, and SUPABASE_SERVICE_ROLE_KEY",
    env: {
      SUPABASE_URL: "https://x",
      SUPABASE_ANON_KEY: "a",
      SUPABASE_SERVICE_ROLE_KEY: "s",
    },
  });
  assert.equal(r.status, 1);
  assert.match(r.stderr, /credentials \(supabaseServiceRole\) are PRESENT/);
});

// A crafted manifest (via SKIP_MANIFEST_PATH) exercises the resolved-known-failure
// guard without polluting the real committed manifest (which is honestly empty).
function runWithManifest(manifestObj, tap) {
  const dir = mkdtempSync(join(tmpdir(), "skipman-rkf-"));
  const mPath = join(dir, "manifest.json");
  writeFileSync(mPath, JSON.stringify(manifestObj));
  const tPath = join(dir, "node.tap");
  writeFileSync(tPath, tap);
  return spawnSync("node", [checker, "--node", tPath], {
    cwd: root,
    encoding: "utf8",
    env: {
      ...process.env,
      SKIP_MANIFEST_PATH: mPath,
      SUPABASE_URL: "",
      SUPABASE_ANON_KEY: "",
      SUPABASE_SERVICE_ROLE_KEY: "",
    },
  });
}

const rkfManifest = {
  credentialGroups: { supabaseServiceRole: ["SUPABASE_URL", "SUPABASE_ANON_KEY", "SUPABASE_SERVICE_ROLE_KEY"] },
  node: { expectedSkips: [] },
  deno: { expectedIgnored: [] },
  resolvedKnownFailures: [{ suite: "node", nameContains: "MALI-999 resolved probe", finding: "MALI-999" }],
};

test("a RESOLVED known-failure re-quarantined as a skip → fail", () => {
  const r = runWithManifest(
    rkfManifest,
    "ok 1 - MALI-999 resolved probe # SKIP re-hidden",
  );
  assert.equal(r.status, 1);
  assert.match(r.stderr, /resolved known-failure.*SKIPPED again/);
});

test("a RESOLVED known-failure that is failing again → fail", () => {
  const r = runWithManifest(
    rkfManifest,
    "not ok 1 - MALI-999 resolved probe\n  ---\n  ...",
  );
  assert.equal(r.status, 1);
  assert.match(r.stderr, /resolved known-failure.*FAILING again/);
});

test("a RESOLVED known-failure that passes normally → ok", () => {
  const r = runWithManifest(rkfManifest, "ok 1 - MALI-999 resolved probe");
  assert.equal(r.status, 0, r.stdout + r.stderr);
});
