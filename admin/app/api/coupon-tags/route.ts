// Coupons Phase C3 — normalized Coupon tag management (coupon_tags). Tag
// attachment itself is part of the coupon payload (`tag_ids`), which the
// coupons route syncs into coupon_tag_links; there is no tags[] array anywhere.
import { NextRequest, NextResponse } from "next/server";
import { adminAuthErrorResponse, requireAdmin } from "@/lib/auth-guard";
import { createAdminClient } from "@/lib/supabase-server";
import { mapDatabaseError, safeErrorBody } from "@/lib/coupon-errors.mjs";
import { validateTagPayload } from "@/lib/coupon-validation.mjs";

function dbFail(context: string, error: unknown) {
  console.error(`[coupon-tags] ${context}`, error);
  const code = mapDatabaseError(error as { code?: string; message?: string; details?: string });
  return NextResponse.json(safeErrorBody(code), { status: code === "unexpected" ? 500 : 400 });
}

/** Search-as-you-type over the tag universe (admin-only). */
export async function GET(req: NextRequest) {
  try {
    await requireAdmin();
  } catch (e) {
    return adminAuthErrorResponse(e);
  }
  const supabase = await createAdminClient();
  let query = supabase
    .from("coupon_tags")
    .select("id, key, label_ar, label_en, sort_order")
    .order("sort_order", { ascending: true })
    .order("key", { ascending: true })
    .limit(200);

  const q = (req.nextUrl.searchParams.get("q") ?? "").trim();
  if (q) {
    // Escape PostgREST pattern metacharacters and the value separator so the
    // search box can never alter the filter expression.
    const safe = q.replace(/[%,()*]/g, "").slice(0, 40);
    if (safe) query = query.or(`key.ilike.%${safe}%,label_ar.ilike.%${safe}%`);
  }

  const { data, error } = await query;
  if (error) return dbFail("list", error);
  return NextResponse.json({ tags: data ?? [] });
}

/** Create a tag; the key is normalized server-side and uniqueness is the DB's. */
export async function POST(req: NextRequest) {
  try {
    await requireAdmin();
  } catch (e) {
    return adminAuthErrorResponse(e);
  }
  const parsed = validateTagPayload(await req.json());
  if (!parsed.ok) {
    return NextResponse.json(safeErrorBody("invalid_payload", parsed.errors), { status: 400 });
  }
  const value = parsed.value as Record<string, unknown>;
  const supabase = await createAdminClient();
  const { data, error } = await supabase
    .from("coupon_tags")
    .insert(value)
    .select("id, key, label_ar, label_en, sort_order")
    .single();
  if (error) return dbFail("create", error);
  return NextResponse.json({ tag: data });
}

export async function PATCH(req: NextRequest) {
  try {
    await requireAdmin();
  } catch (e) {
    return adminAuthErrorResponse(e);
  }
  const body = (await req.json()) as Record<string, unknown>;
  const id = typeof body.id === "string" ? body.id : "";
  if (!/^[0-9a-f-]{36}$/i.test(id)) {
    return NextResponse.json(safeErrorBody("not_found"), { status: 400 });
  }
  const parsed = validateTagPayload({ ...body, key: body.key ?? body.label_ar });
  if (!parsed.ok) {
    return NextResponse.json(safeErrorBody("invalid_payload", parsed.errors), { status: 400 });
  }
  const value = parsed.value as Record<string, unknown>;
  const supabase = await createAdminClient();
  const { error } = await supabase.from("coupon_tags").update(value).eq("id", id);
  if (error) return dbFail("update", error);
  return NextResponse.json({ ok: true });
}
