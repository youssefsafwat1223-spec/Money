// Referral & Ads Phase R2 — reject a PENDING referral (fraud case A, spec §8).
// attributed -> rejected with a required reason. No progress was counted, no
// grant existed. The referral row is never deleted. Verb-only export.
import { NextRequest, NextResponse } from "next/server";
import { adminAuthErrorResponse, requireAdmin } from "@/lib/auth-guard";
import { createAdminClient } from "@/lib/supabase-server";
import { mapDatabaseError, safeErrorBody } from "@/lib/referral-errors.mjs";
import { validateReferralAction } from "@/lib/referral-validation.mjs";

export async function POST(req: NextRequest) {
  let user;
  try {
    user = await requireAdmin();
  } catch (e) {
    return adminAuthErrorResponse(e);
  }
  const body = (await req.json().catch(() => ({}))) as Record<string, unknown>;
  const parsed = validateReferralAction(body);
  if (!parsed.ok) {
    return NextResponse.json(safeErrorBody("validation_failed", parsed.errors as never), { status: 400 });
  }
  const supabase = await createAdminClient();
  const { data, error } = await supabase.rpc("admin_reject_referral", {
    p_operation_id: parsed.value.operation_id,
    p_actor_admin_id: user.id,
    p_referral_id: parsed.value.referral_id,
    p_reason: parsed.value.reason,
  });
  if (error) {
    console.error("[referrals:reject]", error);
    const code = mapDatabaseError(error as { code?: string; message?: string; details?: string });
    return NextResponse.json(safeErrorBody(code), { status: code === "unexpected" ? 500 : 400 });
  }
  return NextResponse.json({ result: data });
}
