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
 * @param {{severity?: string, is_active?: boolean}} payload
 * @returns {boolean} true when this write ARMS a client-blocking force-update.
 */
export function armsForceUpdate(payload) {
  return payload?.severity === "force_update" && payload?.is_active === true;
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
  // A partial PATCH leaves absent keys untouched, so the effective row is the
  // stored row overlaid with the payload.
  const effective = stored ? { ...stored, ...payload } : payload;
  const wasArmed = stored ? armsForceUpdate(stored) : false;

  if (armsForceUpdate(effective) && !wasArmed &&
      options.confirmForceUpdate !== true) {
    return { ok: false, error: FORCE_UPDATE_CONFIRMATION_REQUIRED };
  }
  return { ok: true };
}
