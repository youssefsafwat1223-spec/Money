// F-017 — the force-update kill switch must never publish on a single click.
//
// QA evidence (demo QA, DEMO_FINDINGS F-017): `severity=force_update` — the
// one control that can block every installed client — published with no guard
// beyond a non-empty Arabic title, while plain DELETE had a typed
// confirmation (inverted risk gradient). These tests exercise the REAL shared
// guard the API route now enforces, plus structural contracts proving the
// route and the form actually use it.

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import {
  FORCE_UPDATE_CONFIRMATION_REQUIRED,
  FORCE_UPDATE_CONFIRM_PHRASE,
  armsForceUpdate,
  validateAnnouncementPublish,
} from "../lib/announcement-guard.mjs";

const read = (path) => readFileSync(new URL(`../${path}`, import.meta.url), "utf8");

// ── behavioural: the guard itself ──────────────────────────────────────────

test("an unconfirmed force-update arm is refused — accidental single click cannot publish", () => {
  const armed = { severity: "force_update", is_active: true };
  assert.equal(armsForceUpdate(armed), true);
  assert.deepEqual(validateAnnouncementPublish(armed), {
    ok: false,
    error: FORCE_UPDATE_CONFIRMATION_REQUIRED,
  });
  // No options object at all — the plain legacy call — is also refused.
  assert.equal(validateAnnouncementPublish(armed, {}).ok, false);
});

test("a confirmed force-update arm is allowed", () => {
  const armed = { severity: "force_update", is_active: true };
  assert.deepEqual(
    validateAnnouncementPublish(armed, { confirmForceUpdate: true }),
    { ok: true },
  );
});

test("ordinary announcements keep single-click semantics", () => {
  for (const payload of [
    { severity: "info", is_active: true },
    { severity: "warning", is_active: true },
    { severity: "maintenance", is_active: true },
  ]) {
    assert.deepEqual(validateAnnouncementPublish(payload), { ok: true });
  }
});

test("DISARMING a force-update needs no confirmation — that direction unblocks users", () => {
  assert.deepEqual(
    validateAnnouncementPublish({ severity: "force_update", is_active: false }),
    { ok: true },
  );
});

test("the confirmation token cannot be smuggled as a truthy non-boolean", () => {
  const armed = { severity: "force_update", is_active: true };
  for (const bad of ["true", 1, {}, []]) {
    assert.equal(
      validateAnnouncementPublish(armed, { confirmForceUpdate: bad }).ok,
      false,
      `confirmForceUpdate=${JSON.stringify(bad)} must not arm`,
    );
  }
});

// ── structural: the route and the form actually enforce/use the guard ──────

test("the announcements API enforces the guard on BOTH create and update", () => {
  const route = read("app/api/announcements/route.ts");
  assert.match(route, /announcement-guard\.mjs/);
  const posts = /export async function POST[\s\S]*?(?=export async function)/.exec(route);
  const patches = /export async function PATCH[\s\S]*?(?=export async function)/.exec(route);
  assert.match(posts[0], /validateAnnouncementPublish/, "POST must run the guard");
  assert.match(patches[0], /validateAnnouncementPublish/, "PATCH must run the guard");
  assert.match(route, /confirm_force_update/);
});

test("the form arms only through the typed consequence dialog and states the version constraint", () => {
  const page = read("app/(admin)/announcements/page.tsx");
  assert.match(page, /typeToConfirm:\s*FORCE_UPDATE_CONFIRM_PHRASE/,
    "arming must require typing the confirmation phrase");
  assert.match(page, /يمنع المستخدمين من متابعة استخدام التطبيق/,
    "the dialog must state the consequence, not «هل أنت متأكد؟»");
  assert.match(page, /min_app_version[\s\S]*max_app_version/,
    "the dialog/form must carry the actual version constraint being published");
  assert.match(page, /بدون قيود إصدار — سيُحجب كل مستخدم/,
    "an unbounded constraint must be called out as blocking everyone");
  assert.match(page, /onClick=\{requestSave\}/,
    "the save button must route through the gate, never straight to save()");
  assert.equal(FORCE_UPDATE_CONFIRM_PHRASE, "تحديث إجباري");
});

// ── C-2 — the guard must judge the EFFECTIVE post-write state ──────────────
//
// Independent review (QIRSH_MASTER_PLAN_V2.md §9.1) found the guard evaluates
// only the incoming payload and never reads the stored row. `armsForceUpdate`
// needs severity AND is_active in the SAME object, and a partial PATCH omits
// one of them — so a force-update can be armed with no token at all:
//
//   PATCH {id, is_active:true}        on a dormant force_update row
//   PATCH {id, severity:'force_update'} on an already-active row
//
// Both arm a control that blocks every installed client.

test("C-2: arming a DORMANT force-update by flipping is_active alone is refused", () => {
  const stored = { severity: "force_update", is_active: false };
  const patch = { is_active: true }; // severity absent — untouched, stays force_update

  assert.equal(
    armsForceUpdate({ ...stored, ...patch }),
    true,
    "the effective post-write row IS an armed force-update",
  );
  assert.deepEqual(
    validateAnnouncementPublish(patch, { stored }),
    { ok: false, error: FORCE_UPDATE_CONFIRMATION_REQUIRED },
    "the guard must refuse it without the typed token",
  );
});

test("C-2: arming by setting severity on an ALREADY-ACTIVE row is refused", () => {
  const stored = { severity: "info", is_active: true };
  const patch = { severity: "force_update" }; // is_active absent — stays true

  assert.deepEqual(
    validateAnnouncementPublish(patch, { stored }),
    { ok: false, error: FORCE_UPDATE_CONFIRMATION_REQUIRED },
  );
});

test("C-2: a partial edit that does NOT arm stays frictionless", () => {
  const stored = { severity: "force_update", is_active: false };
  // Editing the copy of a dormant force-update must not demand the token.
  assert.deepEqual(
    validateAnnouncementPublish({ title_ar: "x" }, { stored }),
    { ok: true },
  );
  // Disarming must never require it — that direction unblocks users.
  assert.deepEqual(
    validateAnnouncementPublish(
      { is_active: false },
      { stored: { severity: "force_update", is_active: true } },
    ),
    { ok: true },
  );
});

test("C-2: an already-armed row edited without re-arming stays frictionless", () => {
  const stored = { severity: "force_update", is_active: true };
  assert.deepEqual(
    validateAnnouncementPublish({ title_ar: "new copy" }, { stored }),
    { ok: true },
    "the documented contract: editing an armed force-update is not re-arming",
  );
});

test("C-2: the PATCH route reads the stored row before judging", () => {
  const route = read("app/api/announcements/route.ts");
  const patchBody = route.slice(route.indexOf("export async function PATCH"));
  assert.match(
    patchBody,
    /\.from\("announcements"\)[\s\S]*?\.select\([\s\S]*?\.eq\("id"/,
    "PATCH must load the existing row — a payload-only guard is bypassable",
  );
  assert.match(
    patchBody,
    /validateAnnouncementPublish\([\s\S]*?stored/,
    "and must pass it to the guard",
  );
});
