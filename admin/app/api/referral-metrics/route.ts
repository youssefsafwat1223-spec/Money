// Referral & Ads Phase R2 — metrics (spec §10). Product funnel, NOT billing.
//
// Directional labelling is mandatory: these are attributed / qualified /
// rejected / reversed referral counts and active entitlements — never
// "conversions", "redemptions" or "sales". AdMob remains the authority for ad
// revenue/impressions; there is no shadow billing here. A single server-computed
// headline is returned (the carried C6 note: decide up front, don't client-sum).
import { NextResponse } from "next/server";
import { adminAuthErrorResponse, requireAdmin } from "@/lib/auth-guard";
import { createAdminClient } from "@/lib/supabase-server";
import { safeErrorBody } from "@/lib/referral-errors.mjs";

type AdminClient = Awaited<ReturnType<typeof createAdminClient>>;

/** Exact row count for a table, optionally filtered by an equality predicate. */
async function countRows(
  supabase: AdminClient,
  table: string,
  eq?: { column: string; value: string },
): Promise<number> {
  let q = supabase.from(table).select("*", { count: "exact", head: true });
  if (eq) q = q.eq(eq.column, eq.value);
  const { count, error } = await q;
  if (error) throw error;
  return count ?? 0;
}

export async function GET() {
  try {
    await requireAdmin();
  } catch (e) {
    return adminAuthErrorResponse(e);
  }
  const supabase = await createAdminClient();
  try {
    const [attributed, qualified, rejected, reversed, grants, activeRules] = await Promise.all([
      countRows(supabase, "referrals", { column: "status", value: "attributed" }),
      countRows(supabase, "referrals", { column: "status", value: "qualified" }),
      countRows(supabase, "referrals", { column: "status", value: "rejected" }),
      countRows(supabase, "referrals", { column: "status", value: "reversed" }),
      countRows(supabase, "referral_reward_grants"),
      countRows(supabase, "referral_reward_rules", { column: "is_active", value: "true" }),
    ]);

    // Active ad-free entitlements: derived (status='active' AND ends_at>now).
    const { data: activeEnt, error: entError } = await supabase
      .from("user_entitlement_state")
      .select("ends_at")
      .eq("status", "active")
      .gt("ends_at", new Date().toISOString());
    if (entError) throw entError;

    return NextResponse.json({
      referrals: { attributed, qualified, rejected, reversed },
      rewards_granted: grants,
      active_entitlements: activeEnt?.length ?? 0,
      active_rules: activeRules,
      // Qualified-invite conversion — a proportion, explicitly NOT a "sale".
      qualified_ratio: attributed + qualified > 0 ? qualified / (attributed + qualified) : 0,
    });
  } catch (e) {
    console.error("[referral-metrics]", e);
    return NextResponse.json(safeErrorBody("unexpected"), { status: 500 });
  }
}
