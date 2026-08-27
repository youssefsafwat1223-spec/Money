// F-014 — Parser Lab parity, compiled-artifact side of the contract.
//
// Loads the ACTUAL public/parser_lab.js the Lab page executes (a dart2js build
// of the device engine) and proves it reproduces the same goldens the Dart
// engine test (app/test/engine/parser_lab_parity_test.dart) asserts. A stale
// or divergent compiled artifact fails HERE while the Dart side stays green —
// the exact F-014 failure mode, made visible in CI instead of in production.

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import vm from "node:vm";

const here = dirname(fileURLToPath(import.meta.url));
const fixtures = JSON.parse(
  readFileSync(join(here, "fixtures/parser_parity_fixtures.json"), "utf8"),
);
const goldens = JSON.parse(
  readFileSync(join(here, "fixtures/parser_parity_goldens.json"), "utf8"),
);

// dart2js targets a browser-ish global; give it `self` in a fresh VM context.
const context = vm.createContext({});
context.self = context;
context.globalThis = context;
vm.runInContext(
  readFileSync(join(here, "../public/parser_lab.js"), "utf8"),
  context,
  { filename: "parser_lab.js" },
);

test("compiled parser_lab.js exposes the rules-aware entry", () => {
  assert.equal(typeof context.parseSmsWithRules, "function");
  assert.equal(typeof context.parseSms, "function");
  assert.ok(String(context.parserLabContract).includes("catalog-rules"),
    "compiled artifact predates the catalog-rules contract — recompile");
});

test("compiled engine reproduces the shared parity goldens", () => {
  const rulesJson = JSON.stringify(fixtures.rules);
  fixtures.cases.forEach((c, i) => {
    const g = goldens[i];
    const raw = context.parseSmsWithRules(c.body, c.sender, rulesJson);
    const r = JSON.parse(raw);
    const why = `case ${c.name}: compiled artifact diverges from the Dart ` +
      `engine goldens — recompile parser_lab.js from current app source`;
    assert.equal(r.isTransaction, g.isTransaction, why);
    assert.equal(r.catalogRuleId ?? null, g.catalogRuleId, why);
    assert.equal(r.amount ?? null, g.amount, why);
    assert.equal(r.currency ?? null, g.currency, why);
    assert.equal(r.type ?? null, g.type, why);
    assert.equal(r.merchant ?? null, g.merchant, why);
    assert.equal(r.balanceAfter ?? null, g.balanceAfter, why);
    assert.equal(r.parseConfidence ?? null, g.parseConfidence, why);
  });
});
