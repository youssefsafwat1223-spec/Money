// Coupons Phase C3 — trusted Admin read of coupon_metrics_daily.
//
// The aggregate is unreachable from any browser or mobile client (0082: RLS on,
// zero policies, privileges revoked). This route is the only read path, and it
// verifies admin membership before touching the table.
//
// IMPORTANT — these are PRODUCT / DIRECTIONAL analytics, not billing-grade
// accounting: 0082 deliberately stores no user/install identifier, so repeated
// events cannot be attributed or de-duplicated. The UI must never present these
// as "redemptions", "sales" or "verified conversions".
import { NextRequest, NextResponse } from "next/server";
import { adminAuthErrorResponse, requireAdmin } from "@/lib/auth-guard";
import { createAdminClient } from "@/lib/supabase-server";
import { mapDatabaseError, safeErrorBody } from "@/lib/coupon-errors.mjs";

/** The four 0082 events (route-local: Next.js route files export only verbs). */
const COUPON_EVENTS = ["impression", "detail_view", "code_copy", "cta_click"] as const;
/** Hard bound on the queried window — no unbounded scans. */
const MAX_RANGE_DAYS = 90;
const DEFAULT_RANGE_DAYS = 30;

type Row = { day: string; coupon_id: string; event: string; count: number };

function emptyTotals(): Record<string, number> {
  return { impression: 0, detail_view: 0, code_copy: 0, cta_click: 0 };
}

export async function GET(req: NextRequest) {
  try {
    await requireAdmin();
  } catch (e) {
    return adminAuthErrorResponse(e);
  }

  const params = req.nextUrl.searchParams;

  // Bounded, server-clamped date range (0082 rows are daily aggregates, so this
  // stays cheap by construction).
  const requested = Number(params.get("days") ?? DEFAULT_RANGE_DAYS);
  const days = Number.isFinite(requested)
    ? Math.min(Math.max(Math.trunc(requested), 1), MAX_RANGE_DAYS)
    : DEFAULT_RANGE_DAYS;
  const since = new Date(Date.now() - days * 86_400_000).toISOString().slice(0, 10);

  // Optional single-coupon scope — validated as a UUID, never interpolated raw.
  const couponId = params.get("coupon_id");
  if (couponId !== null && !/^[0-9a-f-]{36}$/i.test(couponId)) {
    return NextResponse.json(safeErrorBody("not_found"), { status: 400 });
  }

  const supabase = await createAdminClient();
  let query = supabase
    .from("coupon_metrics_daily")
    .select("day, coupon_id, event, count")
    .gte("day", since)
    .order("day", { ascending: true });
  if (couponId) query = query.eq("coupon_id", couponId);

  const { data, error } = await query;
  if (error) {
    console.error("[coupon-analytics] read", error);
    return NextResponse.json(safeErrorBody(mapDatabaseError(error)), { status: 500 });
  }

  const rows = (data ?? []) as Row[];

  // Per-coupon totals for the list view.
  const totals: Record<string, Record<string, number>> = {};
  // Daily breakdown (only when a single coupon is requested — keeps payloads small).
  const daily: Array<Record<string, string | number>> = [];
  const byDay = new Map<string, Record<string, number>>();

  for (const row of rows) {
    totals[row.coupon_id] ??= emptyTotals();
    if (row.event in totals[row.coupon_id]) {
      totals[row.coupon_id][row.event] += Number(row.count) || 0;
    }
    if (couponId) {
      const bucket = byDay.get(row.day) ?? emptyTotals();
      if (row.event in bucket) bucket[row.event] += Number(row.count) || 0;
      byDay.set(row.day, bucket);
    }
  }
  if (couponId) {
    for (const [day, counts] of Array.from(byDay.entries()).sort((a, b) => a[0].localeCompare(b[0]))) {
      daily.push({ day, ...counts });
    }
  }

  return NextResponse.json({
    totals,
    daily,
    range: { since, days },
    // Consumed by the UI to label the panel honestly.
    classification: "directional",
  });
}
