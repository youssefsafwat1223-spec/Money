import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";
import test from "node:test";

// Phase-7 Batch-1 — the canonical gate (tools/ci_gates.sh) must be truthful: a failed
// gate produces a non-zero exit, the mandatory suites are wired in, and CI invokes the
// same gate. (Uses --self-test, which exercises only the failure-propagation machinery,
// so this test — itself run BY the gate — does not recurse.)

const root = process.cwd(); // the gate runs node tests from the repo root

test("ci_gates --self-test proves a failed gate exits non-zero", () => {
  const r = spawnSync("bash", ["tools/ci_gates.sh", "--self-test"], {
    cwd: root,
    encoding: "utf8",
  });
  assert.equal(r.status, 0, "self-test itself passes (machinery is correct)");
  assert.match(r.stdout, /SELF-TEST PASS/);
});

test("the canonical gate wires in the previously CI-invisible mandatory suites", () => {
  const sh = readFileSync(`${root}/tools/ci_gates.sh`, "utf8");
  assert.match(sh, /deno lint/, "deno lint gate");
  assert.match(sh, /node --test/, "node test runner");
  assert.match(sh, /supabase\/tests\/\*\.mjs/, "node contract gate");
  assert.match(sh, /check_test_skips\.mjs/, "skip/ignore manifest gate");
  assert.match(sh, /npm run --silent test:auth/, "admin authorization gate");
  assert.match(sh, /check_migrations\.sh/, "migration lint gate");
  assert.match(sh, /flutter gen-l10n/, "l10n freshness gate");
  // Reports UNAVAILABLE separately from pass, and a truthful nested summary.
  assert.match(sh, /unavail/);
  assert.match(sh, /node tests skipped/);
  assert.match(sh, /deno tests ignored/);
  assert.match(sh, /CI_GATES_JSON/);
});

test("the CI workflow invokes the canonical gate as its only validation step", () => {
  const yml = readFileSync(`${root}/.github/workflows/ci.yml`, "utf8");
  assert.match(yml, /bash tools\/ci_gates\.sh/, "CI runs the canonical gate");
  assert.match(yml, /Run canonical CI gates/);
  // No competing CI-only validation step (freshness now lives inside the gate).
  assert.doesNotMatch(yml, /git diff --exit-code/);
});

test("the gate cannot print an all-passed banner while a mandatory suite failed", () => {
  const sh = readFileSync(`${root}/tools/ci_gates.sh`, "utf8");
  assert.match(sh, /if \[ "\$fail" -eq 0 \]; then/);
  assert.match(sh, /SOME GATES FAILED/);
  // pass_count is only ever incremented by ok() — skipped/ignored increment their
  // own counters, never pass_count.
  assert.match(sh, /ok\(\)\s*\{[^}]*pass_count=/);
  assert.match(sh, /unavail\(\)\s*\{[^}]*unavail_count=/);
});
