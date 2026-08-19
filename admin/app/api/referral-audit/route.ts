// Referral & Ads Phase R2 — audit history (spec §9). Append-only, de-identified.
//
// Read-only: NO admin UPDATE or DELETE on audit rows exists anywhere. Rows are
// already de-identified by construction (target_user_id nulled on purge;
// before/after are the server allowlisted schema). This route re-applies the
// allowlist as defence in depth so a non-allowlisted key can never surface even
// if one somehow reached the table.
import { NextRequest, NextResponse } from "next/server";
import { adminAuthErrorResponse, requireAdmin } from "@/lib/auth-guard";
import { createAdminClient } from "@/lib/supabase-server";
import { mapDatabaseError, safeErrorBody } from "@/lib/referral-errors.mjs";
import { filterAuditPayload, isUuid } from "@/lib/referral-validation.mjs";

const AUDIT_SELECT =
  "id, actor_admin_id, action, target_user_id, target_ref, operation_id, reason, " +
  "before_state, after_state, created_at";
const DEFAULT_LIMIT = 100;
const MAX_LIMIT = 500;

function dbFail(context: string, error: unknown) {
  console.error(`[referral-audit] ${context}`, error);
  const code = mapDatabaseError(error as { code?: string; message?: string; details?: string });
  return NextResponse.json(safeErrorBody(code), { status: code === "unexpected" ? 500 : 400 });
}

export async function GET(req: NextRequest) {
  try {
    await requireAdmin();
  } catch (e) {
    return adminAuthErrorResponse(e);
  }
  const params = req.nextUrl.searchParams;
  const rawLimit = Number(params.get("limit"));
  const limit = Number.isInteger(rawLimit) && rawLimit > 0 ? Math.min(rawLimit, MAX_LIMIT) : DEFAULT_LIMIT;
  const targetUserId = params.get("target_user_id");

  const supabase = await createAdminClient();
  let query = supabase
    .from("referral_admin_audit")
    .select(AUDIT_SELECT)
    .order("created_at", { ascending: false })
    .limit(limit);
  if (targetUserId) {
    if (!isUuid(targetUserId)) {
      return NextResponse.json(safeErrorBody("invalid_user_id"), { status: 400 });
    }
    query = query.eq("target_user_id", targetUserId);
  }

  const { data, error } = await query;
  if (error) return dbFail("list", error);

  type AuditRow = {
    id: string;
    actor_admin_id: string | null;
    action: string;
    target_user_id: string | null;
    target_ref: string | null;
    operation_id: string;
    reason: string;
    before_state: Record<string, unknown> | null;
    after_state: Record<string, unknown> | null;
    created_at: string;
  };
  const rows = ((data ?? []) as unknown as AuditRow[]).map((r) => ({
    ...r,
    before_state: filterAuditPayload(r.before_state),
    after_state: filterAuditPayload(r.after_state),
  }));
  return NextResponse.json({ audit: rows });
}
