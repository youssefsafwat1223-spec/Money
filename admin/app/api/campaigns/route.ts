import { NextRequest, NextResponse } from "next/server";
import { createAdminClient, createClient } from "@/lib/supabase-server";

type CampaignPayload = {
  id?: string;
  title_ar: string;
  title_en: string;
  body_ar?: string | null;
  body_en?: string | null;
  type: string;
  target_segment: string;
  action_label_ar?: string | null;
  action_label_en?: string | null;
  action_route?: string | null;
  action_url?: string | null;
  valid_from: string;
  valid_until?: string | null;
  max_impressions?: number | null;
  cooldown_hours: number;
  is_dismissible: boolean;
  once_per_user: boolean;
  priority: number;
  is_active: boolean;
};

async function requireUser() {
  const supabase = await createClient();
  const {
    data: { user },
    error,
  } = await supabase.auth.getUser();
  if (error || !user) return null;
  return user;
}

function normalizePayload(payload: CampaignPayload) {
  return {
    title_ar: payload.title_ar,
    title_en: payload.title_en,
    body_ar: payload.body_ar || null,
    body_en: payload.body_en || null,
    type: payload.type,
    target_segment: payload.target_segment,
    action_label_ar: payload.action_label_ar || null,
    action_label_en: payload.action_label_en || null,
    action_route: payload.action_route || null,
    action_url: payload.action_url || null,
    valid_from: payload.valid_from,
    valid_until: payload.valid_until || null,
    max_impressions: payload.max_impressions || null,
    cooldown_hours: payload.cooldown_hours,
    is_dismissible: payload.is_dismissible,
    once_per_user: payload.once_per_user,
    priority: payload.priority,
    is_active: payload.is_active,
  };
}

export async function GET() {
  if (!(await requireUser())) {
    return NextResponse.json({ error: "Unauthorized" }, { status: 401 });
  }

  const supabase = await createAdminClient();
  const { data, error } = await supabase
    .from("growth_campaigns")
    .select("*")
    .order("priority", { ascending: false });

  if (error) return NextResponse.json({ error: error.message }, { status: 500 });
  return NextResponse.json({ campaigns: data ?? [] });
}

export async function POST(req: NextRequest) {
  if (!(await requireUser())) {
    return NextResponse.json({ error: "Unauthorized" }, { status: 401 });
  }

  const payload = normalizePayload((await req.json()) as CampaignPayload);
  const supabase = await createAdminClient();
  const { data, error } = await supabase
    .from("growth_campaigns")
    .insert(payload)
    .select()
    .single();

  if (error) return NextResponse.json({ error: error.message }, { status: 500 });
  return NextResponse.json({ campaign: data });
}

export async function PATCH(req: NextRequest) {
  if (!(await requireUser())) {
    return NextResponse.json({ error: "Unauthorized" }, { status: 401 });
  }

  const body = (await req.json()) as CampaignPayload;
  if (!body.id) {
    return NextResponse.json({ error: "Missing campaign id" }, { status: 400 });
  }

  const payload = normalizePayload(body);
  const supabase = await createAdminClient();
  const { data, error } = await supabase
    .from("growth_campaigns")
    .update(payload)
    .eq("id", body.id)
    .select()
    .single();

  if (error) return NextResponse.json({ error: error.message }, { status: 500 });
  return NextResponse.json({ campaign: data });
}

export async function DELETE(req: NextRequest) {
  if (!(await requireUser())) {
    return NextResponse.json({ error: "Unauthorized" }, { status: 401 });
  }

  const id = new URL(req.url).searchParams.get("id");
  if (!id) {
    return NextResponse.json({ error: "Missing campaign id" }, { status: 400 });
  }

  const supabase = await createAdminClient();
  const { error } = await supabase.from("growth_campaigns").delete().eq("id", id);

  if (error) return NextResponse.json({ error: error.message }, { status: 500 });
  return NextResponse.json({ ok: true });
}
