// Referral & Ads Phase R2 — user lookup (spec §5).
//
// Search by SAFE existing identifiers only — user_id, referral code, or auth
// email. NO financial information anywhere. Results carry only: short user_id,
// code, current-cycle progress, and an active-entitlement badge. Service-role
// reads bypass RLS; the key never reaches the browser.
import { NextRequest, NextResponse } from "next/server";
import { adminAuthErrorResponse, requireAdmin } from "@/lib/auth-guard";
import { createAdminClient } from "@/lib/supabase-server";
import { mapDatabaseError, safeErrorBody } from "@/lib/referral-errors.mjs";
import { classifyLookupQuery } from "@/lib/referral-validation.mjs";

/** How many auth users to scan when resolving an email (no silent cap). */
const EMAIL_SCAN_PAGES = 10;
const EMAIL_SCAN_PER_PAGE = 200;

type AdminClient = Awaited<ReturnType<typeof createAdminClient>>;

function fail(code: string, status: number) {
  return NextResponse.json(safeErrorBody(code), { status });
}
function dbFail(context: string, error: unknown) {
  console.error(`[referral-users] ${context}`, error);
  const code = mapDatabaseError(error as { code?: string; message?: string; details?: string });
  return NextResponse.json(safeErrorBody(code), { status: code === "unexpected" ? 500 : 400 });
}

/** Resolve an email to a user id via the service-role auth admin API. */
async function resolveEmail(
  supabase: AdminClient,
  email: string,
): Promise<{ userId: string | null; truncated: boolean }> {
  for (let page = 1; page <= EMAIL_SCAN_PAGES; page++) {
    const { data, error } = await supabase.auth.admin.listUsers({ page, perPage: EMAIL_SCAN_PER_PAGE });
    if (error) throw error;
    const users = data?.users ?? [];
    const hit = users.find((u) => (u.email ?? "").toLowerCase() === email);
    if (hit) return { userId: hit.id, truncated: false };
    if (users.length < EMAIL_SCAN_PER_PAGE) return { userId: null, truncated: false };
  }
  return { userId: null, truncated: true };
}

/** Build the safe lookup card for a resolved user id. No financial data. */
async function cardFor(supabase: AdminClient, userId: string) {
  const [{ data: codeRow }, { data: progress }, { data: ent }] = await Promise.all([
    supabase.from("referral_codes").select("code, status").eq("user_id", userId).maybeSingle(),
    supabase
      .from("referral_reward_progress")
      .select("reward_type, cycle_index, qualified_in_cycle, pinned_rule_version, cycle_state")
      .eq("referrer_user_id", userId),
    supabase
      .from("user_entitlement_state")
      .select("entitlement_type, status, ends_at")
      .eq("user_id", userId),
  ]);
  const now = Date.now();
  const activeEntitlement = (ent ?? []).some(
    (e) => e.status === "active" && e.ends_at && new Date(e.ends_at).getTime() > now,
  );
  return {
    user_id: userId,
    code: codeRow?.code ?? null,
    code_status: codeRow?.status ?? null,
    progress: progress ?? [],
    active_entitlement: activeEntitlement,
  };
}

export async function GET(req: NextRequest) {
  try {
    await requireAdmin();
  } catch (e) {
    return adminAuthErrorResponse(e);
  }
  const classified = classifyLookupQuery(req.nextUrl.searchParams.get("query"));
  if (!classified.ok) return fail(classified.error, 400);

  const supabase = await createAdminClient();
  try {
    let userId: string | null = null;
    let truncated = false;

    if (classified.kind === "user_id") {
      userId = classified.value;
    } else if (classified.kind === "code") {
      const { data, error } = await supabase
        .from("referral_codes")
        .select("user_id")
        .eq("code", classified.value)
        .maybeSingle();
      if (error) return dbFail("code-lookup", error);
      userId = data?.user_id ?? null;
    } else {
      const r = await resolveEmail(supabase, classified.value);
      userId = r.userId;
      truncated = r.truncated;
    }

    if (!userId) return NextResponse.json({ results: [], truncated });
    const card = await cardFor(supabase, userId);
    return NextResponse.json({ results: [card], truncated });
  } catch (e) {
    return dbFail("lookup", e);
  }
}
