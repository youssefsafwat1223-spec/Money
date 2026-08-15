// Coupons Phase C3 — Coupon display-category management (Coupon-owned taxonomy;
// entirely independent of the financial transaction categories).
import { NextRequest, NextResponse } from "next/server";
import { adminAuthErrorResponse, requireAdmin } from "@/lib/auth-guard";
import { createAdminClient } from "@/lib/supabase-server";
import { mapDatabaseError, safeErrorBody } from "@/lib/coupon-errors.mjs";
import { validateCategoryPayload } from "@/lib/coupon-validation.mjs";

function dbFail(context: string, error: unknown) {
  console.error(`[coupon-categories] ${context}`, error);
  const code = mapDatabaseError(error as { code?: string; message?: string; details?: string });
  return NextResponse.json(safeErrorBody(code), { status: code === "unexpected" ? 500 : 400 });
}

export async function GET() {
  try {
    await requireAdmin();
  } catch (e) {
    return adminAuthErrorResponse(e);
  }
  const supabase = await createAdminClient();
  // Deterministic order, identical to the catalog contract: sort_order, key.
  const { data, error } = await supabase
    .from("coupon_categories")
    .select("key, label_ar, label_en, sort_order, is_active")
    .order("sort_order", { ascending: true })
    .order("key", { ascending: true });
  if (error) return dbFail("list", error);
  return NextResponse.json({ categories: data ?? [] });
}

export async function POST(req: NextRequest) {
  try {
    await requireAdmin();
  } catch (e) {
    return adminAuthErrorResponse(e);
  }
  const parsed = validateCategoryPayload(await req.json(), { mode: "create" });
  if (!parsed.ok) {
    return NextResponse.json(safeErrorBody("invalid_payload", parsed.errors), { status: 400 });
  }
  const value = parsed.value as Record<string, unknown>;
  const supabase = await createAdminClient();
  const { data, error } = await supabase
    .from("coupon_categories")
    .insert(value)
    .select("key")
    .single();
  if (error) return dbFail("create", error);
  return NextResponse.json({ category: data });
}

/**
 * Update labels / sort_order / activation. Deactivating a category that a LIVE
 * coupon still references is refused by the 0081 trigger; that refusal is
 * surfaced as the controlled `category_in_use` message — the trigger is never
 * bypassed and raw Postgres text never reaches the browser.
 */
export async function PATCH(req: NextRequest) {
  try {
    await requireAdmin();
  } catch (e) {
    return adminAuthErrorResponse(e);
  }
  const body = (await req.json()) as Record<string, unknown>;
  const key = typeof body.key === "string" ? body.key : "";
  if (!/^[a-z0-9_]{2,32}$/.test(key)) {
    return NextResponse.json(safeErrorBody("invalid_category_key"), { status: 400 });
  }
  const parsed = validateCategoryPayload(body, { mode: "update" });
  if (!parsed.ok) {
    return NextResponse.json(safeErrorBody("invalid_payload", parsed.errors), { status: 400 });
  }
  const value = parsed.value as Record<string, unknown>;
  const supabase = await createAdminClient();
  const { error } = await supabase.from("coupon_categories").update(value).eq("key", key);
  if (error) return dbFail("update", error);
  return NextResponse.json({ ok: true });
}
