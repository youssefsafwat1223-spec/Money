// COUPONS Phase 1 — canonical merchant Admin API.
//
// SECURITY CHAIN (non-negotiable, identical to the coupon routes): admin browser
// session -> this trusted server route -> requireAdmin() verifies the
// authenticated UUID is in public.admin_users -> service-role DB operation. The
// service-role key is read only here on the server and never reaches a client
// bundle. Mobile users keep zero write authority (0094 grants them SELECT on
// live rows only).
import { NextRequest, NextResponse } from "next/server";
import { adminAuthErrorResponse, requireAdmin } from "@/lib/auth-guard";
import { createAdminClient } from "@/lib/supabase-server";
import { mapDatabaseError, safeErrorBody } from "@/lib/coupon-errors.mjs";
import { validateMerchantPayload } from "@/lib/merchant-validation.mjs";

const ADMIN_SELECT =
  "id, slug, name_ar, name_en, primary_domain, logo_path, " +
  "default_display_category_key, country_codes, is_active, is_deleted, " +
  "updated_version, created_at, updated_at";

function fail(code: string, status: number, fields?: unknown[]) {
  return NextResponse.json(safeErrorBody(code, fields), { status });
}

/** Log the raw failure server-side; return only a safe mapped message. */
function dbFail(context: string, error: unknown) {
  console.error(`[merchants] ${context}`, error);
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
  // Tombstoned merchants are INCLUDED. An admin needs to see that a merchant
  // was withdrawn — and that its aliases are therefore dormant — rather than
  // watch it silently disappear and wonder where the offers went.
  const { data, error } = await supabase
    .from("catalog_merchants")
    .select(ADMIN_SELECT)
    .order("slug", { ascending: true });
  if (error) return dbFail("list", error);
  return NextResponse.json({ items: data ?? [] });
}

export async function POST(request: NextRequest) {
  try {
    await requireAdmin();
  } catch (e) {
    return adminAuthErrorResponse(e);
  }

  let body: unknown;
  try {
    body = await request.json();
  } catch {
    return fail("invalid_json", 400);
  }

  const validated = validateMerchantPayload(body);
  if (!validated.ok) return fail("validation_failed", 400, validated.fields);

  const supabase = await createAdminClient();
  const { data, error } = await supabase
    .from("catalog_merchants")
    .insert(validated.value!)
    .select(ADMIN_SELECT)
    .single();
  if (error) return dbFail("create", error);
  return NextResponse.json({ item: data }, { status: 201 });
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
  if (!id) return fail("validation_failed", 400, [{ field: "id", code: "required" }]);

  const validated = validateMerchantPayload(body);
  if (!validated.ok) return fail("validation_failed", 400, validated.fields);

  const supabase = await createAdminClient();
  const { data, error } = await supabase
    .from("catalog_merchants")
    .update(validated.value!)
    .eq("id", id)
    .select(ADMIN_SELECT)
    .single();
  if (error) return dbFail("update", error);
  return NextResponse.json({ item: data });
}

export async function DELETE(request: NextRequest) {
  try {
    await requireAdmin();
  } catch (e) {
    return adminAuthErrorResponse(e);
  }

  const id = new URL(request.url).searchParams.get("id")?.trim();
  if (!id) return fail("validation_failed", 400, [{ field: "id", code: "required" }]);

  const supabase = await createAdminClient();
  // TOMBSTONE, never a hard delete. A device applies deltas, so a row that
  // simply vanishes is a row it keeps forever — the merchant would stay on
  // every synced phone with no way to remove it. Setting is_deleted also bumps
  // deleted_version through the 0094 trigger, which is what actually tells
  // devices to drop it.
  const { data, error } = await supabase
    .from("catalog_merchants")
    .update({ is_deleted: true, is_active: false })
    .eq("id", id)
    .select(ADMIN_SELECT)
    .single();
  if (error) return dbFail("tombstone", error);
  return NextResponse.json({ item: data });
}
