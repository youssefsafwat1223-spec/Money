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
  assert.match(sh, /node --test supabase\/tests/, "node contract gate");
  assert.match(sh, /npm run --silent test:auth/, "admin authorization gate");
  assert.match(sh, /check_migrations\.sh/, "migration lint gate");
  // It must be able to report UNAVAILABLE separately from pass.
  assert.match(sh, /unavail/);
});

test("the CI workflow invokes the canonical gate (local/CI parity)", () => {
  const yml = readFileSync(`${root}/.github/workflows/ci.yml`, "utf8");
  assert.match(yml, /bash tools\/ci_gates\.sh/, "CI runs the canonical gate");
  // No CI-only shortcut: the freshness + admin + backend gates are present.
  assert.match(yml, /Generated-code freshness/);
});

test("the gate cannot print an all-passed banner while a mandatory suite failed", () => {
  const sh = readFileSync(`${root}/tools/ci_gates.sh`, "utf8");
  // The success banner is guarded by `fail -eq 0`.
  assert.match(sh, /if \[ "\$fail" -eq 0 \]; then/);
  assert.match(sh, /SOME GATES FAILED/);
});
