// WP5-Lite — dry run: validate + before/after diff. NEVER writes.
import { NextRequest, NextResponse } from "next/server";
import { adminAuthErrorResponse, requireAdmin } from "@/lib/auth-guard";
import { createAdminClient } from "@/lib/supabase-server";
import { previewPlan, type ChangeRequest } from "@/lib/flag-registry";
import { acceptedByColumnExists, loadFlagRows } from "@/lib/feature-flags-server";

export async function POST(req: NextRequest) {
  try {
    await requireAdmin();
  } catch (e) {
    return adminAuthErrorResponse(e);
  }
  const body = (await req.json().catch(() => ({}))) as { changes?: ChangeRequest[] };
  if (!Array.isArray(body.changes)) {
    return NextResponse.json({ error: "changes_invalid" }, { status: 400 });
  }
  const supabase = await createAdminClient();
  const { rows, error } = await loadFlagRows(supabase, body.changes);
  if (error) return NextResponse.json({ error: "flags_unavailable" }, { status: 500 });

  const plan = previewPlan(rows, body.changes);
  if (
    plan.ok &&
    plan.rpcChanges.some((c) => c.key === "ai_sender_mapping_auto") &&
    plan.warnings.some((w) => w.key === "ai_sender_mapping_auto" && w.code === "has_dependency") &&
    !(await acceptedByColumnExists(supabase))
  ) {
    plan.ok = false;
    plan.errors.push({
      key: "ai_sender_mapping_auto",
      code: "dependency_missing",
      detail: "sender_bank_mappings.accepted_by (migration 0100) غير منشورة",
    });
  }
  return NextResponse.json({
    ok: plan.ok,
    errors: plan.errors,
    warnings: plan.warnings,
    diffs: plan.diffs,
    high_risk_keys: plan.highRiskKeys,
  });
}
