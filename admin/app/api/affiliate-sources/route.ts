// COUPONS Phase 2 — the affiliate review queue and the publish action.
//
// Same security chain as every admin route. The publish path is the important
// one: it is the ONLY way a provider-supplied offer becomes something a user
// sees, and it is deliberately a human action with no automatic counterpart.
//
// A provider feed is an untrusted input — expired offers, wrong currencies, dead
// links, copy written for a different market. The ingestion worker stages; a
// person decides. Making publishing automatic would take a schema change rather
// than a config flag, and this route is the other half of that guarantee.
import { NextRequest, NextResponse } from "next/server";
import { adminAuthErrorResponse, requireAdmin } from "@/lib/auth-guard";
import { createAdminClient } from "@/lib/supabase-server";
import { mapDatabaseError, safeErrorBody } from "@/lib/coupon-errors.mjs";
import { buildCouponFromSource } from "@/lib/affiliate-publish.mjs";

const SOURCE_SELECT =
  "id, program_id, coupon_id, external_offer_id, source_fingerprint, normalized, " +
  "provider_status, review_state, review_note, first_seen_at, last_seen_at";

function fail(code: string, status: number, fields?: unknown[]) {
  return NextResponse.json(safeErrorBody(code, fields), { status });
}

function dbFail(context: string, error: unknown) {
  console.error(`[affiliate-sources] ${context}`, error);
  const code = mapDatabaseError(error as { code?: string; message?: string; details?: string });
  return NextResponse.json(safeErrorBody(code), { status: code === "unexpected" ? 500 : 400 });
}

export async function GET(request: NextRequest) {
  try {
    await requireAdmin();
  } catch (e) {
    return adminAuthErrorResponse(e);
  }

  const state = new URL(request.url).searchParams.get("state") ?? "pending";
  const supabase = await createAdminClient();
  let query = supabase.from("affiliate_offer_sources").select(SOURCE_SELECT);
  if (state !== "all") query = query.eq("review_state", state);

  const { data, error } = await query.order("last_seen_at", { ascending: false }).limit(200);
  if (error) return dbFail("list", error);
  return NextResponse.json({ items: data ?? [] });
}

export async function PATCH(request: NextRequest) {
  try {
    await requireAdmin();
  } catch (e) {
    return adminAuthErrorResponse(e);
  }

  let body: Record<string, unknown>;
  try {
    body = (await request.json()) as Record<string, unknown>;
  } catch {
    return fail("invalid_json", 400);
  }

  const id = typeof body.id === "string" ? body.id.trim() : "";
  const action = typeof body.action === "string" ? body.action : "";
  if (!id) return fail("validation_failed", 400, [{ field: "id", code: "required" }]);

  const supabase = await createAdminClient();
  const { data: rawSource, error: loadError } = await supabase
    .from("affiliate_offer_sources")
    .select(SOURCE_SELECT + ", affiliate_programs(merchant_id)")
    .eq("id", id)
    .single();
  if (loadError) return dbFail("load", loadError);
  // The generated row type does not model the embedded join, and `normalized`
  // is a JSONB column that is `unknown` by construction. Narrowed once here so
  // the rest of the handler reads plainly rather than casting at every use.
  const source = rawSource as unknown as {
    normalized: unknown;
    affiliate_programs: { merchant_id: string | null } | null;
  };

  if (action === "reject") {
    const note = typeof body.review_note === "string" ? body.review_note.trim() : null;
    const { data, error } = await supabase
      .from("affiliate_offer_sources")
      .update({ review_state: "rejected", review_note: note })
      .eq("id", id)
      .select(SOURCE_SELECT)
      .single();
    if (error) return dbFail("reject", error);
    return NextResponse.json({ item: data });
  }

  if (action !== "publish") return fail("validation_failed", 400, [{ field: "action", code: "unknown" }]);

  // A staged offer becomes a coupon only once its programme is bound to a
  // CANONICAL merchant. Without that binding there is nothing to attribute the
  // offer to — it would publish as an unlinked coupon and silently miss every
  // merchant surface, which looks like the feature not working rather than like
  // a missing decision.
  const program = source.affiliate_programs as { merchant_id: string | null } | null;
  if (!program?.merchant_id) {
    return fail("merchant_not_bound", 400, [{ field: "program_id", code: "merchant_not_bound" }]);
  }

  const built = buildCouponFromSource(source.normalized, {
    merchantId: program.merchant_id,
    displayCategoryKey: typeof body.display_category_key === "string"
      ? body.display_category_key
      : null,
  });
  if (!built.ok) return fail("validation_failed", 400, built.fields);

  // Insert the coupon first, then link. If the link write fails the coupon
  // exists unreferenced — recoverable, and visible in the coupons list. The
  // reverse order would mark a source published with no coupon behind it, which
  // the 0096 CHECK forbids anyway and which would break the withdraw sweep.
  const { data: coupon, error: couponError } = await supabase
    .from("coupons")
    .insert(built.value!)
    .select("id")
    .single();
  if (couponError) return dbFail("publish_coupon", couponError);

  const { data, error } = await supabase
    .from("affiliate_offer_sources")
    .update({ review_state: "published", coupon_id: coupon.id })
    .eq("id", id)
    .select(SOURCE_SELECT)
    .single();
  if (error) return dbFail("publish_link", error);

  return NextResponse.json({ item: data, coupon_id: coupon.id });
}
