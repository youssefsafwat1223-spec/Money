// Referral & Ads Phase R2 — rotate a user's referral code (abuse remedy, spec §7).
// The old code stops attributing GOING FORWARD; past qualifications are never
// retroactively unqualified. A new cryptographically-secure code is generated
// server-side. Verb-only export.
import { NextRequest, NextResponse } from "next/server";
import { adminAuthErrorResponse, requireAdmin } from "@/lib/auth-guard";
import { createAdminClient } from "@/lib/supabase-server";
import { mapDatabaseError, safeErrorBody } from "@/lib/referral-errors.mjs";
import { validateRotateCode } from "@/lib/referral-validation.mjs";

export async function POST(req: NextRequest) {
  let user;
  try {
    user = await requireAdmin();
  } catch (e) {
    return adminAuthErrorResponse(e);
  }
  const body = (await req.json().catch(() => ({}))) as Record<string, unknown>;
  const parsed = validateRotateCode(body);
  if (!parsed.ok) {
    return NextResponse.json(safeErrorBody("validation_failed", parsed.errors as never), { status: 400 });
  }
  const supabase = await createAdminClient();
  const { data, error } = await supabase.rpc("admin_rotate_referral_code", {
    p_operation_id: parsed.value.operation_id,
    p_actor_admin_id: user.id,
    p_user_id: parsed.value.user_id,
    p_reason: parsed.value.reason,
  });
  if (error) {
    console.error("[referral-codes:rotate]", error);
    const code = mapDatabaseError(error as { code?: string; message?: string; details?: string });
    return NextResponse.json(safeErrorBody(code), { status: code === "unexpected" ? 500 : 400 });
  }
  return NextResponse.json({ result: data });
}
