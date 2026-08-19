// Referral & Ads Phase R2 — shared server helpers for the mutation routes.
// NOT a route file (no HTTP-verb exports): imported by the entitlement routes so
// grant/extend/revoke cannot drift apart. Every mutation goes through an
// approved 0083 RPC wrapper; no route ever writes a referral/entitlement table
// directly.
import { NextRequest, NextResponse } from "next/server";
import { adminAuthErrorResponse, requireAdmin } from "@/lib/auth-guard";
import { createAdminClient } from "@/lib/supabase-server";
import { mapDatabaseError, safeErrorBody } from "@/lib/referral-errors.mjs";
import { validateEntitlementAction } from "@/lib/referral-validation.mjs";

type EntitlementAction = "grant" | "extend" | "shorten" | "revoke";

/**
 * Run a manual entitlement mutation (grant | extend | shorten | revoke) through
 * admin_mutate_entitlement. `allowed` is the set this route may perform: a
 * verb-specific route passes exactly its own action(s), so hitting the revoke
 * endpoint with action:'grant' is rejected before any DB call. When the caller
 * passes a single action it is also pinned onto the body. The client-minted
 * operation_id is passed straight through — the DB enforces idempotency; a
 * replay returns the stored result unchanged.
 */
export async function runEntitlementMutation(
  req: NextRequest,
  allowed: EntitlementAction[],
): Promise<NextResponse> {
  let user;
  try {
    user = await requireAdmin();
  } catch (e) {
    return adminAuthErrorResponse(e);
  }

  const body = (await req.json().catch(() => ({}))) as Record<string, unknown>;
  // A single-action route pins the action; a multi-action route (revoke|shorten)
  // keeps the client's choice but only from its own allowlist.
  if (allowed.length === 1) body.action = allowed[0];
  if (!allowed.includes(body.action as EntitlementAction)) {
    return NextResponse.json(safeErrorBody("invalid_action"), { status: 400 });
  }

  const parsed = validateEntitlementAction(body);
  if (!parsed.ok) {
    return NextResponse.json(safeErrorBody("validation_failed", parsed.errors as never), { status: 400 });
  }

  const supabase = await createAdminClient();
  const { data, error } = await supabase.rpc("admin_mutate_entitlement", {
    p_operation_id: parsed.value.operation_id,
    p_actor_admin_id: user.id,
    p_user_id: parsed.value.user_id,
    p_entitlement_type: parsed.value.entitlement_type,
    p_action: parsed.value.action,
    p_reason: parsed.value.reason,
    p_duration_days: parsed.value.duration_days,
  });
  if (error) {
    console.error(`[entitlements:${parsed.value.action}]`, error);
    const code = mapDatabaseError(error as { code?: string; message?: string; details?: string });
    return NextResponse.json(safeErrorBody(code), { status: code === "unexpected" ? 500 : 400 });
  }
  // data = { applied, duplicate, audit_id, result }. duplicate:true is success.
  return NextResponse.json({ result: data });
}
