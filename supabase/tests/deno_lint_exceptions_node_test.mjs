import assert from "node:assert/strict";
import { readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";
import test from "node:test";

// Phase-7 Batch-1 §Blocker-6 — the retained Deno-lint exception allowlist must be
// EXACT, so a new suppression cannot silently hide neighbouring findings. `deno lint
// _shared/` is otherwise 0 findings, and the canonical gate fails on any new finding.

const root = process.cwd();
const sharedDir = join(root, "supabase/functions/_shared");

// The EXACT sanctioned suppression set (all `no-explicit-any`, all keeping the loosely
// typed Supabase Edge client), documented in PHASE_7_TEST_AND_CI_CONTRACT.md. Keyed by
// file → count so it is stable against line shifts but catches any new suppression.
// 2 are production Edge helpers; 5 are test doubles.
const ALLOWLIST = {
  "notification_logs.ts": 1, // SupabaseClientLike type alias (production)
  "notification_policy.ts": 1, // loadNotificationPolicy(supabase) param (production)
  "ai_endpoint_test.ts": 2, // test doubles
  "notification_policy_test.ts": 3, // test doubles
};

test("deno-lint-ignore directives in _shared exactly match the allowlist", () => {
  const found = {};
  for (const file of readdirSync(sharedDir)) {
    if (!file.endsWith(".ts")) continue;
    const src = readFileSync(join(sharedDir, file), "utf8");
    const count = (src.match(/deno-lint-ignore/g) || []).length;
    if (count > 0) found[file] = count;
  }
  assert.deepEqual(
    found,
    ALLOWLIST,
    `deno-lint-ignore set drifted from the documented allowlist. Found: ${JSON.stringify(found)}`,
  );
  // Every suppression is the one sanctioned rule.
  for (const file of Object.keys(ALLOWLIST)) {
    const src = readFileSync(join(sharedDir, file), "utf8");
    const rules = [...src.matchAll(/deno-lint-ignore\s+([a-z-]+)/g)].map((m) => m[1]);
    for (const r of rules) assert.equal(r, "no-explicit-any", `${file}: only no-explicit-any is sanctioned`);
  }
});
