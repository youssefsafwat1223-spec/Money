#!/usr/bin/env node
// Phase-7 Batch-1 — enforce tools/test_skip_manifest.json against the actual node
// (TAP) + deno test output. FAILS (exit 1) on: an unexpected skip/ignore, a skip
// whose reason matches no manifest entry, partial/malformed credential config, or a
// group whose credentials are present but whose tests still skipped.
//
// Usage: node tools/check_test_skips.mjs --node <node.tap> --deno <deno.txt>
// Either input may be omitted (that surface is then not checked).
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const root = dirname(dirname(fileURLToPath(import.meta.url)));
// The committed manifest by default; SKIP_MANIFEST_PATH lets contract tests exercise
// the enforcement logic against a crafted manifest without touching the real one.
const manifestPath = process.env.SKIP_MANIFEST_PATH || join(root, "tools/test_skip_manifest.json");
const manifest = JSON.parse(readFileSync(manifestPath, "utf8"));
const resolvedKnownFailures = manifest.resolvedKnownFailures || [];
const errors = [];
const notes = [];

function arg(name) {
  const i = process.argv.indexOf(name);
  return i >= 0 ? process.argv[i + 1] : null;
}

// eslint-disable-next-line no-control-regex
const stripAnsi = (s) => s.replace(/\x1b\[[0-9;]*m/g, "");

// --- credential-group state: absent | partial | present -------------------------
const groupState = {};
for (const [group, vars] of Object.entries(manifest.credentialGroups)) {
  const set = vars.filter((v) => (process.env[v] ?? "").length > 0);
  const state = set.length === 0
    ? "absent"
    : set.length === vars.length
    ? "present"
    : "partial";
  groupState[group] = state;
  if (state === "partial") {
    errors.push(
      `credential group '${group}' is PARTIAL/malformed: set=[${set.join(",")}] ` +
        `missing=[${vars.filter((v) => !set.includes(v)).join(",")}] — ` +
        `configure all or none`,
    );
  }
}

// --- node TAP: collect SKIP directives -------------------------------------------
const nodeTap = arg("--node");
if (nodeTap) {
  const tap = stripAnsi(readFileSync(nodeTap, "utf8"));
  // node --test TAP emits skips as: `ok N - <name> # SKIP <reason>`
  const skipRe = /^ok\s+\d+\s+-\s+(.*?)\s+#\s+SKIP\s*(.*)$/gm;
  let m;
  const skips = [];
  while ((m = skipRe.exec(tap)) !== null) skips.push({ name: m[1].trim(), reason: (m[2] || "").trim() });
  // node --test TAP emits failures as: `not ok N - <name>`
  const failRe = /^not ok\s+\d+\s+-\s+(.*)$/gm;
  const failures = [];
  while ((m = failRe.exec(tap)) !== null) failures.push(m[1].trim());
  // A finding that was a known failure and is now RESOLVED must be neither skipped nor
  // failing on the node surface — re-quarantining or re-breaking it is a regression.
  for (const rkf of resolvedKnownFailures) {
    if (rkf.suite && rkf.suite !== "node") continue;
    const pat = rkf.nameContains || rkf.reasonContains || "";
    if (skips.some((s) => s.name.includes(pat) || s.reason.includes(pat))) {
      errors.push(`resolved known-failure "${pat}" (${rkf.finding || "?"}) is SKIPPED again — a resolved test must run and pass, not be re-quarantined`);
    }
    if (failures.some((f) => f.includes(pat))) {
      errors.push(`resolved known-failure "${pat}" (${rkf.finding || "?"}) is FAILING again — regression`);
    }
  }
  for (const s of skips) {
    const entry = (manifest.node.expectedSkips || []).find((e) =>
      s.reason.includes(e.reasonContains) || s.name.includes(e.reasonContains),
    );
    if (!entry) {
      errors.push(`UNEXPECTED node skip: "${s.name}" (reason: "${s.reason}") — add a manifest entry or fix the skip`);
      continue;
    }
    if (entry.mustRunWhenPrereq && groupState[entry.group] === "present") {
      errors.push(`node test "${s.name}" SKIPPED but its credentials (${entry.group}) are PRESENT — it must run`);
    }
  }
  // Expected-skip-disappeared: a manifest pattern that should match (its group is
  // absent) but matched nothing is a stale entry or a removed test.
  for (const e of manifest.node.expectedSkips || []) {
    if (groupState[e.group] !== "absent") continue;
    if (!skips.some((s) => s.reason.includes(e.reasonContains) || s.name.includes(e.reasonContains))) {
      errors.push(`expected node skip pattern matched NOTHING: "${e.reasonContains}" (${e.finding}) — remove the stale manifest entry or restore the test`);
    }
  }
  notes.push(`node: ${skips.length} skip(s), all manifest-matched (unless errored above)`);
}

// --- deno text output: collect ignored tests -------------------------------------
const denoOut = arg("--deno");
if (denoOut) {
  const out = stripAnsi(readFileSync(denoOut, "utf8"));
  const ignoreRe = /^(.*?)\s+\.\.\.\s+ignored/gm;
  let m;
  const ignored = [];
  while ((m = ignoreRe.exec(out)) !== null) ignored.push(m[1].trim());
  for (const name of ignored) {
    const entry = (manifest.deno.expectedIgnored || []).find((e) => name.includes(e.nameContains));
    if (!entry) {
      errors.push(`UNEXPECTED deno ignored test: "${name}" — add a manifest entry or fix the ignore`);
      continue;
    }
    if (entry.mustRunWhenPrereq && groupState[entry.group] === "present") {
      errors.push(`deno test "${name}" IGNORED but its credentials (${entry.group}) are PRESENT — it must run`);
    }
  }
  for (const e of manifest.deno.expectedIgnored || []) {
    if (groupState[e.group] !== "absent") continue;
    if (!ignored.some((name) => name.includes(e.nameContains))) {
      errors.push(`expected deno ignore matched NOTHING: "${e.nameContains}" (${e.finding}) — remove the stale entry or restore the test`);
    }
  }
  notes.push(`deno: ${ignored.length} ignored, all manifest-matched (unless errored above)`);
}

for (const n of notes) console.log(`  · ${n}`);
if (errors.length) {
  console.error("skip/ignore manifest violations:");
  for (const e of errors) console.error(`  ✗ ${e}`);
  process.exit(1);
}
console.log("  ✓ skip/ignore manifest satisfied");
