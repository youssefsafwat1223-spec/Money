import { NextRequest, NextResponse } from "next/server";
import { requireAdmin } from "@/lib/auth-guard";
import { createAdminClient } from "@/lib/supabase-server";

type AnnouncementPayload = {
  id?: string;
  title_ar: string;
  title_en: string;
  body_ar?: string | null;
  body_en?: string | null;
  severity: string;
  action_label_ar?: string | null;
  action_label_en?: string | null;
  action_url?: string | null;
  valid_from: string;
  valid_until?: string | null;
  is_dismissible: boolean;
  priority: number;
  is_active: boolean;
};

function normalizePayload(payload: AnnouncementPayload) {
  return {
    title_ar: payload.title_ar,
    title_en: payload.title_en,
    body_ar: payload.body_ar || null,
    body_en: payload.body_en || null,
    severity: payload.severity,
    action_label_ar: payload.action_label_ar || null,
    action_label_en: payload.action_label_en || null,
    action_url: payload.action_url || null,
    valid_from: payload.valid_from,
    valid_until: payload.valid_until || null,
    is_dismissible: payload.is_dismissible,
    priority: payload.priority,
    is_active: payload.is_active,
  };
}

export async function GET() {
  await requireAdmin();

  const supabase = await createAdminClient();
  const { data, error } = await supabase
    .from("announcements")
    .select("*")
    .order("priority", { ascending: false });

  if (error) {
    return NextResponse.json({ error: error.message }, { status: 500 });
  }
  return NextResponse.json({ announcements: data ?? [] });
}

export async function POST(req: NextRequest) {
  await requireAdmin();

  const payload = normalizePayload((await req.json()) as AnnouncementPayload);
  const supabase = await createAdminClient();
  const { data, error } = await supabase
    .from("announcements")
    .insert(payload)
    .select()
    .single();

  if (error) {
    return NextResponse.json({ error: error.message }, { status: 500 });
  }
  return NextResponse.json({ announcement: data });
}

export async function PATCH(req: NextRequest) {
  await requireAdmin();

  const body = (await req.json()) as AnnouncementPayload;
  if (!body.id) {
    return NextResponse.json({ error: "Missing announcement id" }, { status: 400 });
  }

  const payload = normalizePayload(body);
  const supabase = await createAdminClient();
  const { data, error } = await supabase
    .from("announcements")
    .update(payload)
    .eq("id", body.id)
    .select()
    .single();

  if (error) {
    return NextResponse.json({ error: error.message }, { status: 500 });
  }
  return NextResponse.json({ announcement: data });
}

export async function DELETE(req: NextRequest) {
  await requireAdmin();

  const id = new URL(req.url).searchParams.get("id");
  if (!id) {
    return NextResponse.json({ error: "Missing announcement id" }, { status: 400 });
  }

  const supabase = await createAdminClient();
  const { error } = await supabase.from("announcements").delete().eq("id", id);

  if (error) {
    return NextResponse.json({ error: error.message }, { status: 500 });
  }
  return NextResponse.json({ ok: true });
}
