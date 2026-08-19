// Referral & Ads Phase R2 — reward-rule config API.
//
// SECURITY CHAIN (non-negotiable): admin browser session -> this trusted server
// route -> requireAdmin() verifies the authenticated UUID is in
// public.admin_users -> service-role DB operation. The service-role key is read
// only here on the server (createAdminClient); it never reaches a client bundle.
//
// GET lists every rule version (read model). Mutations (publish a new version,
// deactivate) go through the approved 0083 RPC wrappers in ./mutations — this
// route never writes referral_reward_rules directly.
import { NextRequest, NextResponse } from "next/server";
import { adminAuthErrorResponse, requireAdmin } from "@/lib/auth-guard";
import { createAdminClient } from "@/lib/supabase-server";
import { mapDatabaseError, safeErrorBody } from "@/lib/referral-errors.mjs";
import { validateRulePayload, validateDeactivateRule } from "@/lib/referral-validation.mjs";

const RULE_SELECT =
  "id, version, reward_type, required_referrals, reward_days, repeatable, " +
  "is_active, effective_from, effective_until, created_at, updated_at";

function fail(code: string, status: number, fields?: unknown[]) {
  return NextResponse.json(safeErrorBody(code, fields as never), { status });
}

function dbFail(context: string, error: unknown) {
  console.error(`[referral-rules] ${context}`, error);
  const code = mapDatabaseError(error as { code?: string; message?: string; details?: string });
  return NextResponse.json(safeErrorBody(code), { status: code === "unexpected" ? 500 : 400 });
}

/** List all rule versions, newest first within each reward type. */
export async function GET() {
  try {
    await requireAdmin();
  } catch (e) {
    return adminAuthErrorResponse(e);
  }
  const supabase = await createAdminClient();
  const { data, error } = await supabase
    .from("referral_reward_rules")
    .select(RULE_SELECT)
    .order("reward_type", { ascending: true })
    .order("version", { ascending: false });
  if (error) return dbFail("list", error);
  return NextResponse.json({ rules: data ?? [] });
}

/** Publish a NEW rule version via admin_publish_reward_rule (versioning). */
export async function POST(req: NextRequest) {
  let user;
  try {
    user = await requireAdmin();
  } catch (e) {
    return adminAuthErrorResponse(e);
  }
  const body = (await req.json().catch(() => ({}))) as Record<string, unknown>;
  const parsed = validateRulePayload(body);
  if (!parsed.ok) return fail("validation_failed", 400, parsed.errors);

  const supabase = await createAdminClient();
  const { data, error } = await supabase.rpc("admin_publish_reward_rule", {
    p_operation_id: parsed.value.operation_id,
    p_actor_admin_id: user.id,
    p_reward_type: parsed.value.reward_type,
    p_required_referrals: parsed.value.required_referrals,
    p_reward_days: parsed.value.reward_days,
    p_repeatable: parsed.value.repeatable,
    p_reason: parsed.value.reason,
    p_effective_until: parsed.value.effective_until,
  });
  if (error) return dbFail("publish", error);
  return NextResponse.json({ result: data });
}

/** Deactivate the active rule for a reward type via admin_deactivate_reward_rule. */
export async function PATCH(req: NextRequest) {
  let user;
  try {
    user = await requireAdmin();
  } catch (e) {
    return adminAuthErrorResponse(e);
  }
  const body = (await req.json().catch(() => ({}))) as Record<string, unknown>;
  const parsed = validateDeactivateRule(body);
  if (!parsed.ok) return fail("validation_failed", 400, parsed.errors);

  const supabase = await createAdminClient();
  const { data, error } = await supabase.rpc("admin_deactivate_reward_rule", {
    p_operation_id: parsed.value.operation_id,
    p_actor_admin_id: user.id,
    p_reward_type: parsed.value.reward_type,
    p_reason: parsed.value.reason,
  });
  if (error) return dbFail("deactivate", error);
  return NextResponse.json({ result: data });
}
