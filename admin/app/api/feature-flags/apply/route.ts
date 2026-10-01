// WP5-Lite — the ONLY write path for feature flags.
//
// requireAdmin() -> re-validate the plan server-side (never trust /preview) ->
// admin_apply_feature_flag_changes with the admin's id. The RPC is authoritative
// for atomicity, stale-write detection (409), per-field validation, the
// ai_sender_mapping_auto dependency and operation_id idempotency.
import { NextRequest, NextResponse } from "next/server";
import { adminAuthErrorResponse, requireAdmin } from "@/lib/auth-guard";
import { createAdminClient } from "@/lib/supabase-server";
import { buildPlan, type ChangeRequest } from "@/lib/flag-registry";
import { isRpcNotDeployed, loadFlagRows, rpcErrorStatus, UUID_RE } from "@/lib/feature-flags-server";

type ApplyBody = {
  changes?: ChangeRequest[];
  reason?: string;
  operation_id?: string;
  typed_confirmation?: string;
};

export async function POST(req: NextRequest) {
  let user;
  try {
    user = await requireAdmin();
  } catch (e) {
    return adminAuthErrorResponse(e);
  }
  const body = (await req.json().catch(() => ({}))) as ApplyBody;
  if (!Array.isArray(body.changes)) {
    return NextResponse.json({ error: "changes_invalid" }, { status: 400 });
  }
  const reason = typeof body.reason === "string" ? body.reason.trim() : "";
  if (reason.length < 4 || reason.length > 500) {
    return NextResponse.json({ error: "reason_invalid" }, { status: 400 });
  }
  if (typeof body.operation_id !== "string" || !UUID_RE.test(body.operation_id)) {
    return NextResponse.json({ error: "operation_id_invalid" }, { status: 400 });
  }

  const supabase = await createAdminClient();
  const { rows, error: loadError } = await loadFlagRows(supabase, body.changes);
  if (loadError) return NextResponse.json({ error: "flags_unavailable" }, { status: 500 });

  const plan = buildPlan(rows, body.changes, { typedConfirmation: body.typed_confirmation ?? null });
  if (!plan.ok) {
    return NextResponse.json({ error: "validation_failed", errors: plan.errors }, { status: 422 });
  }

  const { data, error } = await supabase.rpc("admin_apply_feature_flag_changes", {
    p_actor: user.id,
    p_reason: reason,
    p_operation_id: body.operation_id,
    p_changes: plan.rpcChanges,
  });
  if (error) {
    // Migration 0102 (audited RPC) not deployed yet: clear 503, no log noise.
    if (isRpcNotDeployed(error.code)) {
      return NextResponse.json({ error: "audit_not_deployed" }, { status: 503 });
    }
    const status = rpcErrorStatus(error.code);
    if (status === 500) console.error("[feature-flags/apply]", error);
    return NextResponse.json(
      { error: status === 409 ? "stale_or_conflict" : status === 500 ? "unexpected" : "rejected", detail: status === 500 ? undefined : error.message },
      { status },
    );
  }
  return NextResponse.json({ ok: true, result: data });
}
