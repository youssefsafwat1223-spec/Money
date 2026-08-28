import { NextRequest, NextResponse } from "next/server";
import { requireAdmin } from "@/lib/auth-guard";
import { createAdminClient } from "@/lib/supabase-server";
import { guardParserWrite, ParserValidationError } from "@/lib/parser-validation-guard.mjs";

type Resource = "banks" | "sms_parsers" | "feature_flags";

function resourceFrom(value: string | null): Resource | null {
  return value === "banks" || value === "sms_parsers" || value === "feature_flags"
    ? value
    : null;
}

function cleanBank(input: Record<string, unknown>) {
  return {
    name_ar: input.name_ar,
    name_en: input.name_en,
    short_code: input.short_code,
    country_code: input.country_code,
    sms_senders: input.sms_senders,
    supported_currencies: input.supported_currencies,
    color_hex: input.color_hex,
    is_active: input.is_active,
    sort_order: input.sort_order,
  };
}

function cleanParser(input: Record<string, unknown>) {
  return {
    bank_id: input.bank_id,
    sender_pattern: input.sender_pattern,
    message_pattern: input.message_pattern,
    transaction_type: input.transaction_type,
    language: input.language,
    priority: input.priority,
    extracted_fields: input.extracted_fields,
    is_active: input.is_active,
    validation_status: input.validation_status,
  };
}

export async function GET(req: NextRequest) {
  await requireAdmin();
  const resource = resourceFrom(req.nextUrl.searchParams.get("resource"));
  if (!resource) return NextResponse.json({ error: "invalid_resource" }, { status: 400 });

  const id = req.nextUrl.searchParams.get("id");
  const supabase = await createAdminClient();
  let query = supabase.from(resource).select("*");
  if (id) query = query.eq("id", id);
  const { data, error } = id
    ? await query.maybeSingle()
    : await query.order(resource === "feature_flags" ? "key" : "created_at");
  if (error) return NextResponse.json({ error: error.message }, { status: 500 });

  if (resource === "sms_parsers") {
    const { data: banks, error: banksError } = await supabase
      .from("banks")
      .select("id,name_ar")
      .order("name_ar");
    if (banksError) return NextResponse.json({ error: banksError.message }, { status: 500 });
    return NextResponse.json({ data, banks: banks ?? [] });
  }
  return NextResponse.json({ data });
}

export async function POST(req: NextRequest) {
  await requireAdmin();
  const body = await req.json() as Record<string, unknown>;
  const resource = resourceFrom(typeof body.resource === "string" ? body.resource : null);
  if (resource !== "banks" && resource !== "sms_parsers") {
    return NextResponse.json({ error: "invalid_resource" }, { status: 400 });
  }
  const client = await createAdminClient();
  // F-011: a new rule may not be born trusted.
  let parserRow: Record<string, unknown> | null = null;
  if (resource === "sms_parsers") {
    try {
      parserRow = guardParserWrite(cleanParser(body), null);
    } catch (e) {
      if (e instanceof ParserValidationError) {
        return NextResponse.json({ error: e.message, code: e.code }, { status: 422 });
      }
      throw e;
    }
  }
  const result = resource === "banks"
    ? await client.from("banks").insert(cleanBank(body)).select().single()
    : await client.from("sms_parsers").insert(parserRow!).select().single();
  const { data, error } = result;
  if (error) return NextResponse.json({ error: error.message }, { status: 500 });
  return NextResponse.json({ data });
}

export async function PATCH(req: NextRequest) {
  await requireAdmin();
  const body = await req.json() as Record<string, unknown>;
  const resource = resourceFrom(typeof body.resource === "string" ? body.resource : null);
  const id = typeof body.id === "string" ? body.id : "";
  if (!resource || !id) return NextResponse.json({ error: "invalid_request" }, { status: 400 });
  const client = await createAdminClient();
  // F-011: promotion to `passed` is not an editing operation. The guard needs
  // the CURRENT row, because "may this edit change the status" depends on what
  // the status already is — and on whether its evidence is real.
  let parserPatch: Record<string, unknown> | null = null;
  if (resource === "sms_parsers") {
    const { data: existing } = await client
      .from("sms_parsers")
      .select("validation_status, validated_at, golden_test_count")
      .eq("id", id)
      .maybeSingle();
    try {
      parserPatch = guardParserWrite(cleanParser(body), existing ?? null);
    } catch (e) {
      if (e instanceof ParserValidationError) {
        return NextResponse.json({ error: e.message, code: e.code }, { status: 422 });
      }
      throw e;
    }
  }
  const result = resource === "banks"
    ? await client.from("banks").update(cleanBank(body)).eq("id", id).select().single()
    : resource === "sms_parsers"
      ? await client.from("sms_parsers").update(parserPatch!).eq("id", id).select().single()
      : await client.from("feature_flags").update({
          is_active: body.is_active,
          value: body.value,
          rollout_percent: body.rollout_percent,
        }).eq("id", id).select().single();
  const { data, error } = result;
  if (error) return NextResponse.json({ error: error.message }, { status: 500 });
  return NextResponse.json({ data });
}

export async function DELETE(req: NextRequest) {
  await requireAdmin();
  const resource = resourceFrom(req.nextUrl.searchParams.get("resource"));
  const id = req.nextUrl.searchParams.get("id");
  if ((resource !== "banks" && resource !== "sms_parsers") || !id) {
    return NextResponse.json({ error: "invalid_request" }, { status: 400 });
  }
  const { error } = await (await createAdminClient()).from(resource).delete().eq("id", id);
  if (error) return NextResponse.json({ error: error.message }, { status: 500 });
  return NextResponse.json({ ok: true });
}
