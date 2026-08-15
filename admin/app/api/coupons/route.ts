// Coupons Phase C3 — Coupon Admin API.
//
// SECURITY CHAIN (non-negotiable): admin browser session
//   -> this trusted server route -> requireAdmin() verifies the authenticated
//   UUID is in public.admin_users -> service-role DB/Storage operation.
// The service-role key is read only here on the server (createAdminClient); it
// never reaches a client bundle. Normal authenticated/mobile users keep zero
// Coupon write authority (0081 RLS grants them SELECT on live rows only).
import { NextRequest, NextResponse } from "next/server";
import { adminAuthErrorResponse, requireAdmin } from "@/lib/auth-guard";
import { createAdminClient } from "@/lib/supabase-server";
import { mapDatabaseError, safeErrorBody } from "@/lib/coupon-errors.mjs";
import { resolveSort, validateCouponPayload } from "@/lib/coupon-validation.mjs";

/** Columns the Admin list/editor needs (analytics are fetched separately). */
const ADMIN_SELECT =
  "id, slug, partner_name, title_ar, title_en, description_ar, description_en, " +
  "terms_ar, redemption_type, code, partner_url, display_category_key, " +
  "spend_hint_category_keys, country_codes, accent_hex, image_path, featured, " +
  "priority, valid_from, valid_until, is_active, created_at, updated_at, " +
  "coupon_tag_links(tag_id)";

function fail(code: string, status: number, fields?: unknown[]) {
  return NextResponse.json(safeErrorBody(code, fields), { status });
}

/** Log the raw failure server-side; return only a safe mapped message. */
function dbFail(context: string, error: unknown) {
  console.error(`[coupons] ${context}`, error);
  const code = mapDatabaseError(error as { code?: string; message?: string; details?: string });
  return NextResponse.json(safeErrorBody(code), { status: code === "unexpected" ? 500 : 400 });
}

/** Replace a coupon's tag links with exactly `tagIds` (attach + detach). */
async function syncTagLinks(
  supabase: Awaited<ReturnType<typeof createAdminClient>>,
  couponId: string,
  tagIds: string[],
) {
  const { error: delError } = await supabase
    .from("coupon_tag_links")
    .delete()
    .eq("coupon_id", couponId);
  if (delError) return delError;
  if (tagIds.length === 0) return null;
  const rows = tagIds.map((tag_id) => ({ coupon_id: couponId, tag_id }));
  const { error: insError } = await supabase.from("coupon_tag_links").insert(rows);
  return insError ?? null;
}

export async function GET(req: NextRequest) {
  try {
    await requireAdmin();
  } catch (e) {
    return adminAuthErrorResponse(e);
  }

  const params = req.nextUrl.searchParams;
  const supabase = await createAdminClient();

  // Controlled ordering only — a client can never supply a raw column name.
  const sort = resolveSort(params.get("sort") ?? "priority");
  let query = supabase
    .from("coupons")
    .select(ADMIN_SELECT)
    .order(sort.column, { ascending: sort.ascending });

  // Server-side filters that map to real columns; everything else (status,
  // search) is applied below so the SQL surface stays small and safe.
  const type = params.get("redemption_type");
  if (type === "code" || type === "link") query = query.eq("redemption_type", type);
  const category = params.get("display_category_key");
  if (category && /^[a-z0-9_]{2,32}$/.test(category)) {
    query = query.eq("display_category_key", category);
  }
  if (params.get("featured") === "true") query = query.eq("featured", true);

  const { data, error } = await query;
  if (error) return dbFail("list", error);
  return NextResponse.json({ coupons: data ?? [] });
}

export async function POST(req: NextRequest) {
  try {
    await requireAdmin();
  } catch (e) {
    return adminAuthErrorResponse(e);
  }

  const body = (await req.json()) as Record<string, unknown>;
  // Server validation is authoritative — client-side checks are UX only.
  const parsed = validateCouponPayload(body, { mode: "create" });
  if (!parsed.ok) return fail("invalid_payload", 400, parsed.errors);

  const { __tag_ids: tagIds, ...row } = parsed.value as Record<string, unknown> & {
    __tag_ids: string[];
  };

  const supabase = await createAdminClient();
  const { data, error } = await supabase.from("coupons").insert(row).select("id").single();
  if (error) return dbFail("create", error);

  const linkError = await syncTagLinks(supabase, data.id as string, tagIds);
  if (linkError) return dbFail("create.tags", linkError);

  return NextResponse.json({ coupon: { id: data.id } });
}

export async function PATCH(req: NextRequest) {
  try {
    await requireAdmin();
  } catch (e) {
    return adminAuthErrorResponse(e);
  }

  const body = (await req.json()) as Record<string, unknown>;
  const id = typeof body.id === "string" ? body.id : "";
  if (!id) return fail("not_found", 400);

  // The SAME schema as create — one authority, no drift between the two paths.
  const parsed = validateCouponPayload(body, { mode: "update" });
  if (!parsed.ok) return fail("invalid_payload", 400, parsed.errors);

  const { __tag_ids: tagIds, ...row } = parsed.value as Record<string, unknown> & {
    __tag_ids: string[];
  };

  const supabase = await createAdminClient();
  const { error } = await supabase.from("coupons").update(row).eq("id", id);
  if (error) return dbFail("update", error);

  const linkError = await syncTagLinks(supabase, id, tagIds);
  if (linkError) return dbFail("update.tags", linkError);

  return NextResponse.json({ coupon: { id } });
}

/**
 * PERMANENT delete — the destructive path, not the everyday one. Routine
 * retirement is `is_active=false` (PATCH), which preserves the coupon, its tag
 * links, its analytics and its image. This removes the row (tag links and
 * metrics cascade per 0081/0082) and then the coupon's Storage prefix.
 * The caller must pass `confirm=permanent`.
 */
export async function DELETE(req: NextRequest) {
  try {
    await requireAdmin();
  } catch (e) {
    return adminAuthErrorResponse(e);
  }

  const params = req.nextUrl.searchParams;
  const id = params.get("id") ?? "";
  if (!/^[0-9a-f-]{36}$/i.test(id)) return fail("not_found", 400);
  if (params.get("confirm") !== "permanent") return fail("unexpected", 400);

  const supabase = await createAdminClient();
  const { error } = await supabase.from("coupons").delete().eq("id", id);
  if (error) return dbFail("delete", error);

  // Best-effort asset cleanup, scoped strictly to THIS coupon's prefix.
  const { data: objects } = await supabase.storage.from("coupon-assets").list(`coupons/${id}`);
  if (objects && objects.length > 0) {
    await supabase.storage
      .from("coupon-assets")
      .remove(objects.map((o: { name: string }) => `coupons/${id}/${o.name}`));
  }

  return NextResponse.json({ ok: true });
}
