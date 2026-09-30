// WP5-Lite — feature-flag control plane (read model).
//
// requireAdmin() -> service-role read. Writes never happen here: they go through
// /apply -> admin_apply_feature_flag_changes (audited, optimistic, atomic).
import { NextResponse } from "next/server";
import { adminAuthErrorResponse, requireAdmin } from "@/lib/auth-guard";
import { createAdminClient } from "@/lib/supabase-server";
import { FLAG_REGISTRY, missingRowKeys } from "@/lib/flag-registry";

const AUDIT_PER_FLAG = 10;

export async function GET() {
  try {
    await requireAdmin();
  } catch (e) {
    return adminAuthErrorResponse(e);
  }
  const supabase = await createAdminClient();
  const { data: flags, error } = await supabase.from("feature_flags").select("*").order("key");
  if (error) return NextResponse.json({ error: "flags_unavailable" }, { status: 500 });

  // The audit table ships with deferred migration 0102. Until it is deployed the
  // page still lists flags, but reports that history/apply are unavailable.
  const { data: auditRows, error: auditError } = await supabase
    .from("feature_flag_admin_audit")
    .select("operation_id, actor_admin_id, flag_key, field, old_value, new_value, reason, created_at")
    .order("created_at", { ascending: false })
    .limit(500);
  const audit: Record<string, unknown[]> = {};
  for (const row of auditRows ?? []) {
    const list = (audit[row.flag_key] ??= []);
    if (list.length < AUDIT_PER_FLAG) list.push(row);
  }

  return NextResponse.json({
    flags: flags ?? [],
    registry: FLAG_REGISTRY,
    missing_keys: missingRowKeys((flags ?? []).map((f) => f.key as string)),
    audit,
    audit_available: !auditError,
  });
}
