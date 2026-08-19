// Referral & Ads Phase R2 — adjust current-cycle progress (spec §8, case B).
// An explicit, audited Admin action. The DB enforces the invariants: never below
// zero, never across a completed cycle boundary (a completed cycle's grant
// stands). Verb-only export.
import { NextRequest, NextResponse } from "next/server";
import { adminAuthErrorResponse, requireAdmin } from "@/lib/auth-guard";
import { createAdminClient } from "@/lib/supabase-server";
import { mapDatabaseError, safeErrorBody } from "@/lib/referral-errors.mjs";
import { validateProgressAdjust } from "@/lib/referral-validation.mjs";

export async function POST(req: NextRequest) {
  let user;
  try {
    user = await requireAdmin();
  } catch (e) {
    return adminAuthErrorResponse(e);
  }
  const body = (await req.json().catch(() => ({}))) as Record<string, unknown>;
  const parsed = validateProgressAdjust(body);
  if (!parsed.ok) {
    return NextResponse.json(safeErrorBody("validation_failed", parsed.errors as never), { status: 400 });
  }
  const supabase = await createAdminClient();
  const { data, error } = await supabase.rpc("admin_adjust_referral_progress", {
    p_operation_id: parsed.value.operation_id,
    p_actor_admin_id: user.id,
    p_referrer_user_id: parsed.value.referrer_user_id,
    p_reward_type: parsed.value.reward_type,
    p_qualified_in_cycle: parsed.value.qualified_in_cycle,
    p_reason: parsed.value.reason,
  });
  if (error) {
    console.error("[referral-progress:adjust]", error);
    const code = mapDatabaseError(error as { code?: string; message?: string; details?: string });
    return NextResponse.json(safeErrorBody(code), { status: code === "unexpected" ? 500 : 400 });
  }
  return NextResponse.json({ result: data });
}
