/**
 * F-017 — the force-update publish guard, shared by the API route (authority)
 * and the form (UX). `severity = 'force_update'` with `is_active = true` is
 * the most destructive control in the dashboard: it blocks every in-range
 * installed app until the user updates. Publishing/arming it therefore
 * requires an EXPLICIT confirmation token that a plain form submit never
 * carries — an accidental single click cannot produce it.
 *
 * Everything else stays frictionless by design (the risk gradient must not
 * invert again): ordinary severities, editing an already-armed force-update
 * without re-arming it, and DISARMING one (is_active=false) — that direction
 * unblocks users.
 */

/** The exact text the operator must type in the confirmation dialog. */
export const FORCE_UPDATE_CONFIRM_PHRASE = "تحديث إجباري";

export const FORCE_UPDATE_CONFIRMATION_REQUIRED =
  "force_update_confirmation_required";

/**
 * Arming a force-update with no `action_url` blocks every client behind a
 * button that goes nowhere: `ForceUpdateScreen` falls back to a PLACEHOLDER
 * store URL carrying a fake app id (`id0000000000`). Unlike version bounds —
 * which cannot work at all while no build defines `APP_VERSION` — this is a
 * real precondition, so it is enforced rather than merely warned about.
 */
export const FORCE_UPDATE_ACTION_URL_REQUIRED =
  "force_update_action_url_required";

/**
 * @param {{severity?: string, is_active?: boolean}} payload
 * @returns {boolean} true when this write ARMS a client-blocking force-update.
 */
export function armsForceUpdate(payload) {
  return payload?.severity === "force_update" && payload?.is_active === true;
}

/**
 * Whether a row actually BLOCKS clients — the only definition that matters.
 *
 * `catalog-announcements` serves a row only while `valid_from <= now` and
 * (`valid_until` IS NULL OR `valid_until >= now`). So severity + is_active is
 * not sufficient: a force-update whose `valid_until` is in the past blocks
 * nobody, and moving that date forward takes it from harmless to blocking every
 * client WITHOUT ever crossing the naive armed→armed boundary. That was a live
 * bypass of the confirmation requirement.
 *
 * `valid_from` in the future still counts as blocking: a scheduled block is a
 * block, and it must not be armable without confirmation just because it lands
 * later.
 */
export function blocksClients(row, now = new Date()) {
  if (!armsForceUpdate(row)) return false;
  const until = row?.valid_until;
  if (until == null) return true; // never expires
  const untilMs = Date.parse(until);
  if (Number.isNaN(untilMs)) return true; // unparseable → assume blocking
  return untilMs > now.getTime();
}

/**
 * The audience a row applies to. `catalog-announcements` treats an EMPTY
 * `target_countries` as "every country", so emptying it widens blast radius.
 */
function widensAudience(before, after) {
  const list = (r) => (Array.isArray(r?.target_countries) ? r.target_countries : []);
  const b = list(before);
  const a = list(after);
  if (b.length === 0) return false; // already worldwide — cannot widen further
  if (a.length === 0) return true; // scoped → worldwide
  return a.some((c) => !b.includes(c));
}

/**
 * Validates a create/update payload for the announcements API.
 *
 * C-2 — the decision is made on the EFFECTIVE POST-WRITE ROW, not on the
 * payload alone. `armsForceUpdate` needs `severity` and `is_active` together,
 * and a partial PATCH carries only one of them, so a payload-only guard was
 * bypassable in both directions:
 *
 *   PATCH {id, is_active:true}          on a dormant force_update row
 *   PATCH {id, severity:'force_update'} on an already-active row
 *
 * Each armed a control that blocks every installed client, with no token.
 * Callers MUST pass `options.stored` for updates; omitting it on an update
 * degrades to the old payload-only behaviour, so the route is contract-tested
 * to supply it.
 *
 * Arming is judged as a TRANSITION: only a write that takes the row from
 * not-armed to armed needs the token. Editing an already-armed announcement,
 * and disarming one, both stay frictionless by design.
 *
 * @param {{severity?: string, is_active?: boolean}} payload
 * @param {{confirmForceUpdate?: boolean,
 *          stored?: {severity?: string, is_active?: boolean} | null}} [options]
 * @returns {{ok: true} | {ok: false, error: string}}
 */
export function validateAnnouncementPublish(payload, options = {}) {
  const stored = options.stored ?? null;
  const now = options.now ?? new Date();
  // A partial PATCH leaves absent keys untouched, so the effective row is the
  // stored row overlaid with the payload.
  const effective = stored ? { ...stored, ...payload } : payload;

  const wasBlocking = stored ? blocksClients(stored, now) : false;
  const willBlock = blocksClients(effective, now);

  // Confirmation is required whenever a write causes a force-update to block
  // clients it was not already blocking. That is one rule covering: flipping
  // is_active, setting severity, resurrecting an expired window, clearing
  // valid_until, scheduling a future block, and widening the target audience.
  //
  // Narrowing is always frictionless — reducing blast radius must never be
  // harder than increasing it, or operators will avoid doing it.
  const escalates =
    (willBlock && !wasBlocking) ||
    (willBlock && wasBlocking && widensAudience(stored, effective));

  if (escalates && options.confirmForceUpdate !== true) {
    return { ok: false, error: FORCE_UPDATE_CONFIRMATION_REQUIRED };
  }

  // Even a confirmed arm is refused without somewhere for the user to go.
  //
  // Scoped to writes that ESCALATE, or that strip the URL off a row which will
  // still be blocking. Enforcing it on every edit of an already-blocking row
  // would trap an operator: a legacy row armed without a URL could then not be
  // edited at all — including edits made to defuse it.
  const touchesActionUrl = Object.hasOwn(payload ?? {}, "action_url");
  if (willBlock && (escalates || touchesActionUrl)) {
    const url = effective?.action_url;
    if (typeof url !== "string" || url.trim() === "") {
      return { ok: false, error: FORCE_UPDATE_ACTION_URL_REQUIRED };
    }
  }
  return { ok: true };
}
