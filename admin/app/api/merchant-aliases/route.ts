// COUPONS Phase 1 — merchant alias Admin API.
//
// Same security chain as every other admin route. The interesting part here is
// what this route deliberately does NOT do.
//
// It never sends `alias_normalized`. That column is GENERATED ALWAYS ... STORED
// in 0094, and PostgreSQL rejects an explicit value for one outright — there is
// no OVERRIDING escape hatch as there is for identity columns. So an admin
// request structurally cannot store a lookup key that disagrees with its own
// raw text, which is the property the whole exact-match design rests on.
import { NextRequest, NextResponse } from "next/server";
import { adminAuthErrorResponse, requireAdmin } from "@/lib/auth-guard";
import { createAdminClient } from "@/lib/supabase-server";
import { mapDatabaseError, safeErrorBody } from "@/lib/coupon-errors.mjs";
import { validateAliasPayload } from "@/lib/merchant-validation.mjs";

const ADMIN_SELECT =
  "id, merchant_id, alias_raw, alias_normalized, alias_kind, country_code, " +
  "priority, key_version, provenance, is_reviewed, is_active, is_deleted, " +
  "created_at, updated_at";

function fail(code: string, status: number, fields?: unknown[]) {
  return NextResponse.json(safeErrorBody(code, fields), { status });
}

function dbFail(context: string, error: unknown) {
  console.error(`[merchant-aliases] ${context}`, error);
  const code = mapDatabaseError(error as { code?: string; message?: string; details?: string });
  return NextResponse.json(safeErrorBody(code), { status: code === "unexpected" ? 500 : 400 });
}

export async function GET(request: NextRequest) {
  try {
    await requireAdmin();
  } catch (e) {
    return adminAuthErrorResponse(e);
  }

  const params = new URL(request.url).searchParams;
  const merchantId = params.get("merchant_id")?.trim();
  // `?review=pending` is the review queue: unreviewed aliases are invisible to
  // devices, so this list is the only place they can be seen at all.
  const pendingOnly = params.get("review") === "pending";

  const supabase = await createAdminClient();
  let query = supabase
    .from("catalog_merchant_aliases")
    .select(ADMIN_SELECT)
    .eq("is_deleted", false);
  if (merchantId) query = query.eq("merchant_id", merchantId);
  if (pendingOnly) query = query.eq("is_reviewed", false);

  const { data, error } = await query.order("created_at", { ascending: false });
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

  const validated = validateAliasPayload(body);
  if (!validated.ok) return fail("validation_failed", 400, validated.fields);

  const supabase = await createAdminClient();
  const { data, error } = await supabase
    .from("catalog_merchant_aliases")
    .insert(validated.value!)
    .select(ADMIN_SELECT)
    .single();
  // A unique violation here is the COLLISION case: another merchant already
  // holds this reviewed alias. mapDatabaseError turns it into a message rather
  // than a constraint name, because the admin's next action is to decide which
  // merchant is right, not to read SQL.
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

  const supabase = await createAdminClient();

  // A review decision is its own operation, not an edit. Approving an alias is
  // the moment it becomes visible to every device, so it is kept separate from
  // changing its text — which would silently re-approve something under review.
  if (Object.keys(body).length === 2 && typeof body.is_reviewed === "boolean") {
    const { data, error } = await supabase
      .from("catalog_merchant_aliases")
      .update({ is_reviewed: body.is_reviewed })
      .eq("id", id)
      .select(ADMIN_SELECT)
      .single();
    if (error) return dbFail("review", error);
    return NextResponse.json({ item: data });
  }

  const validated = validateAliasPayload(body);
  if (!validated.ok) return fail("validation_failed", 400, validated.fields);

  // Editing the text UNREVIEWS it. The previous approval was for the previous
  // string; carrying it over would let an approved alias be repointed at a
  // different merchant without anyone looking at it again.
  const { data, error } = await supabase
    .from("catalog_merchant_aliases")
    .update({ ...validated.value!, is_reviewed: false })
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
  // Tombstone, for the same delta reason as merchants: a vanished row is a row
  // every synced device keeps resolving against forever.
  const { data, error } = await supabase
    .from("catalog_merchant_aliases")
    .update({ is_deleted: true, is_active: false })
    .eq("id", id)
    .select(ADMIN_SELECT)
    .single();
  if (error) return dbFail("tombstone", error);
  return NextResponse.json({ item: data });
}
