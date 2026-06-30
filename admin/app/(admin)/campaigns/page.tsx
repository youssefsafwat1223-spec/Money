"use client";

import { useEffect, useMemo, useState } from "react";

type Campaign = {
  id: string;
  title_ar: string;
  title_en: string;
  body_ar: string | null;
  body_en: string | null;
  type: string;
  target_segment: string;
  action_label_ar: string | null;
  action_label_en: string | null;
  action_route: string | null;
  action_url: string | null;
  valid_from: string;
  valid_until: string | null;
  max_impressions: number | null;
  cooldown_hours: number;
  is_dismissible: boolean;
  once_per_user: boolean;
  priority: number;
  is_active: boolean;
};

const TYPES = ["notification", "dashboard_banner", "settings_card", "modal"];
const SEGMENTS = [
  "all",
  "new_user",
  "no_shortcut",
  "has_first_transaction",
  "inactive_3_days",
  "active_user",
  "budget_user",
];

const initialForm = {
  title_ar: "قرش لسه مستني أول رسالة بنك",
  title_en: "Qirsh is waiting for your first bank message",
  body_ar: "فعّل Shortcut وخليه يرتب مصاريفك بدل النسخ واللصق.",
  body_en: "Turn on the Shortcut and let Qirsh organize expenses for you.",
  type: "dashboard_banner",
  target_segment: "no_shortcut",
  action_label_ar: "افتح الإعدادات",
  action_label_en: "Open settings",
  action_route: "/settings",
  action_url: "",
  valid_from: new Date().toISOString(),
  valid_until: "",
  max_impressions: "3",
  cooldown_hours: "24",
  is_dismissible: true,
  once_per_user: false,
  priority: "50",
  is_active: true,
};

export default function CampaignsPage() {
  const [campaigns, setCampaigns] = useState<Campaign[]>([]);
  const [form, setForm] = useState(initialForm);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const activeCount = useMemo(
    () => campaigns.filter((campaign) => campaign.is_active).length,
    [campaigns],
  );

  useEffect(() => {
    void load();
  }, []);

  async function load() {
    setError(null);
    const res = await fetch("/api/campaigns");
    const json = await res.json();
    if (!res.ok) {
      setError(json.error ?? "Failed to load campaigns");
      return;
    }
    setCampaigns((json.campaigns ?? []) as Campaign[]);
  }

  async function createCampaign() {
    setBusy(true);
    setError(null);
    const res = await fetch("/api/campaigns", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        ...form,
        valid_until: form.valid_until || null,
        max_impressions: form.max_impressions ? Number(form.max_impressions) : null,
        cooldown_hours: Number(form.cooldown_hours),
        priority: Number(form.priority),
      }),
    });
    const json = await res.json();
    setBusy(false);
    if (!res.ok) {
      setError(json.error ?? "Failed to create campaign");
      return;
    }
    setForm(initialForm);
    await load();
  }

  async function updateCampaign(campaign: Campaign, patch: Partial<Campaign>) {
    const next = { ...campaign, ...patch };
    const res = await fetch("/api/campaigns", {
      method: "PATCH",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(next),
    });
    if (!res.ok) {
      const json = await res.json();
      setError(json.error ?? "Failed to update campaign");
      return;
    }
    await load();
  }

  async function deleteCampaign(id: string) {
    const res = await fetch(`/api/campaigns?id=${encodeURIComponent(id)}`, {
      method: "DELETE",
    });
    if (!res.ok) {
      const json = await res.json();
      setError(json.error ?? "Failed to delete campaign");
      return;
    }
    await load();
  }

  return (
    <div className="p-8 space-y-8">
      <div>
        <p className="text-sm text-slate-500">Growth</p>
        <h1 className="text-2xl font-semibold text-slate-900">Campaigns</h1>
        <p className="text-sm text-slate-500">{activeCount} active campaigns</p>
      </div>

      {error && (
        <div className="rounded-lg border border-red-200 bg-red-50 px-4 py-3 text-sm text-red-700">
          {error}
        </div>
      )}

      <section className="rounded-xl border border-slate-200 bg-white p-5 shadow-sm">
        <h2 className="mb-4 text-lg font-semibold text-slate-900">Create campaign</h2>
        <div className="grid gap-4 md:grid-cols-2">
          <Input label="Arabic title" value={form.title_ar} onChange={(v) => setForm({ ...form, title_ar: v })} />
          <Input label="English title" value={form.title_en} onChange={(v) => setForm({ ...form, title_en: v })} />
          <Input label="Arabic body" value={form.body_ar} onChange={(v) => setForm({ ...form, body_ar: v })} />
          <Input label="English body" value={form.body_en} onChange={(v) => setForm({ ...form, body_en: v })} />
          <Select label="Type" value={form.type} options={TYPES} onChange={(v) => setForm({ ...form, type: v })} />
          <Select label="Segment" value={form.target_segment} options={SEGMENTS} onChange={(v) => setForm({ ...form, target_segment: v })} />
          <Input label="Arabic action label" value={form.action_label_ar} onChange={(v) => setForm({ ...form, action_label_ar: v })} />
          <Input label="Action route" value={form.action_route} onChange={(v) => setForm({ ...form, action_route: v })} />
          <Input label="Action URL" value={form.action_url} onChange={(v) => setForm({ ...form, action_url: v })} />
          <Input label="Priority" value={form.priority} onChange={(v) => setForm({ ...form, priority: v })} />
          <Input label="Max impressions" value={form.max_impressions} onChange={(v) => setForm({ ...form, max_impressions: v })} />
          <Input label="Cooldown hours" value={form.cooldown_hours} onChange={(v) => setForm({ ...form, cooldown_hours: v })} />
        </div>
        <div className="mt-4 flex flex-wrap gap-5 text-sm text-slate-700">
          <label className="flex items-center gap-2">
            <input type="checkbox" checked={form.is_dismissible} onChange={(e) => setForm({ ...form, is_dismissible: e.target.checked })} />
            Dismissible
          </label>
          <label className="flex items-center gap-2">
            <input type="checkbox" checked={form.once_per_user} onChange={(e) => setForm({ ...form, once_per_user: e.target.checked })} />
            Once per user
          </label>
          <label className="flex items-center gap-2">
            <input type="checkbox" checked={form.is_active} onChange={(e) => setForm({ ...form, is_active: e.target.checked })} />
            Active
          </label>
        </div>
        <button
          className="mt-5 rounded-lg bg-brand-600 px-4 py-2 text-sm font-semibold text-white disabled:opacity-50"
          disabled={busy}
          onClick={createCampaign}
        >
          Create campaign
        </button>
      </section>

      <section className="space-y-3">
        {campaigns.map((campaign) => (
          <article key={campaign.id} className="rounded-xl border border-slate-200 bg-white p-5 shadow-sm">
            <div className="flex items-start justify-between gap-4">
              <div>
                <div className="flex flex-wrap gap-2 text-xs text-slate-500">
                  <span>{campaign.type}</span>
                  <span>{campaign.target_segment}</span>
                  <span>priority {campaign.priority}</span>
                </div>
                <h3 className="mt-2 text-lg font-semibold text-slate-900">{campaign.title_ar}</h3>
                <p className="mt-1 text-sm text-slate-600">{campaign.body_ar}</p>
              </div>
              <div className="flex shrink-0 gap-2">
                <button className="rounded-lg border px-3 py-2 text-sm" onClick={() => updateCampaign(campaign, { is_active: !campaign.is_active })}>
                  {campaign.is_active ? "Pause" : "Activate"}
                </button>
                <button className="rounded-lg border border-red-200 px-3 py-2 text-sm text-red-600" onClick={() => deleteCampaign(campaign.id)}>
                  Delete
                </button>
              </div>
            </div>
          </article>
        ))}
      </section>
    </div>
  );
}

function Input({ label, value, onChange }: { label: string; value: string; onChange: (value: string) => void }) {
  return (
    <label className="block text-sm">
      <span className="mb-1 block font-medium text-slate-700">{label}</span>
      <input className="w-full rounded-lg border border-slate-200 px-3 py-2" value={value} onChange={(e) => onChange(e.target.value)} />
    </label>
  );
}

function Select({ label, value, options, onChange }: { label: string; value: string; options: string[]; onChange: (value: string) => void }) {
  return (
    <label className="block text-sm">
      <span className="mb-1 block font-medium text-slate-700">{label}</span>
      <select className="w-full rounded-lg border border-slate-200 px-3 py-2" value={value} onChange={(e) => onChange(e.target.value)}>
        {options.map((option) => (
          <option key={option} value={option}>
            {option}
          </option>
        ))}
      </select>
    </label>
  );
}
