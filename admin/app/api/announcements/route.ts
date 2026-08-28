import { NextRequest, NextResponse } from "next/server";
import { requireAdmin } from "@/lib/auth-guard";
import { validateAnnouncementPublish } from "@/lib/announcement-guard.mjs";
import { createAdminClient } from "@/lib/supabase-server";

type AnnouncementPayload = {
  id?: string;
  /** F-017 — required (true) only when arming a force-update. Not persisted. */
  confirm_force_update?: boolean;
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
  min_app_version?: string | null;
  max_app_version?: string | null;
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
    min_app_version: payload.min_app_version || null,
    max_app_version: payload.max_app_version || null,
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

  const body = (await req.json()) as AnnouncementPayload;
  const payload = normalizePayload(body);
  // F-017 — arming a client-blocking force-update requires the explicit
  // confirmation token; an ordinary form submit never carries it.
  const guard = validateAnnouncementPublish(payload, {
    confirmForceUpdate: body.confirm_force_update === true,
  });
  if (!guard.ok) {
    return NextResponse.json({ error: guard.error }, { status: 400 });
  }
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

  // C-2 — judge the EFFECTIVE post-write row, not the payload alone. A partial
  // PATCH omits one half of the arming condition, so a payload-only guard let a
  // force-update be armed with no token:
  //   {id, is_active:true}          on a dormant force_update row
  //   {id, severity:'force_update'} on an already-active row
  // Load the stored row first and let the guard decide on the transition.
  // C-2a — the guard's notion of "armed" is "blocks clients", which depends on
  // the serving window and the target audience as well as severity/is_active.
  // Selecting only the latter two made the temporal fields invisible to the
  // guard, so resurrecting an expired force-update read as an ordinary edit.
  const { data: stored, error: storedError } = await supabase
    .from("announcements")
    .select("severity, is_active, valid_from, valid_until, target_countries, action_url")
    .eq("id", body.id)
    .maybeSingle();

  if (storedError) {
    return NextResponse.json({ error: storedError.message }, { status: 500 });
  }
  if (!stored) {
    return NextResponse.json({ error: "Announcement not found" }, { status: 404 });
  }

  // F-017 — same guard on updates: editing an announcement INTO an armed
  // force-update needs the same explicit confirmation as creating one.
  const guard = validateAnnouncementPublish(payload, {
    confirmForceUpdate: body.confirm_force_update === true,
    stored,
  });
  if (!guard.ok) {
    return NextResponse.json({ error: guard.error }, { status: 400 });
  }
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
