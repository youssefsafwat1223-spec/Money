"use client";
import { useEffect, useState } from "react";
import { createClient } from "@/lib/supabase";
import { Plus, Trash2, Save, Megaphone } from "lucide-react";
import { fmtDate } from "@/lib/utils";

type Announcement = {
  id?: string; title_ar: string; title_en: string; body_ar: string; body_en: string;
  severity: string; action_label_ar: string; action_label_en: string; action_url: string;
  valid_from: string; valid_until: string; is_dismissible: boolean; priority: number; is_active: boolean;
};

const empty: Announcement = {
  title_ar: "", title_en: "", body_ar: "", body_en: "", severity: "info",
  action_label_ar: "", action_label_en: "", action_url: "",
  valid_from: new Date().toISOString().slice(0, 16),
  valid_until: "", is_dismissible: true, priority: 0, is_active: true,
};

const severityStyle: Record<string, string> = {
  info: "bg-blue-50 text-blue-700",
  warning: "bg-amber-50 text-amber-700",
  maintenance: "bg-purple-50 text-purple-700",
  force_update: "bg-red-100 text-red-700 font-semibold",
};

export default function AnnouncementsPage() {
  const supabase = createClient();
  const [announcements, setAnnouncements] = useState<Announcement[]>([]);
  const [form, setForm] = useState<Announcement | null>(null);
  const [saving, setSaving] = useState(false);

  useEffect(() => {
    supabase.from("announcements").select("*").order("priority", { ascending: false })
      .then(({ data }) => setAnnouncements((data ?? []) as Announcement[]));
  }, []);

  function set(field: keyof Announcement, value: unknown) {
    setForm(prev => prev ? { ...prev, [field]: value } : prev);
  }

  async function save() {
    if (!form) return;
    setSaving(true);
    const payload = { ...form, valid_until: form.valid_until || null };
    if (form.id) {
      const { data } = await supabase.from("announcements").update(payload).eq("id", form.id).select().single();
      setAnnouncements(prev => prev.map(a => a.id === form.id ? data as Announcement : a));
    } else {
      const { data } = await supabase.from("announcements").insert(payload).select().single();
      if (data) setAnnouncements(prev => [data as Announcement, ...prev]);
    }
    setSaving(false);
    setForm(null);
  }

  async function remove(id: string) {
    if (!confirm("Delete announcement?")) return;
    await supabase.from("announcements").delete().eq("id", id);
    setAnnouncements(prev => prev.filter(a => a.id !== id));
  }

  return (
    <div className="space-y-6">
      <div className="flex items-center justify-between">
        <div>
          <h1 className="text-2xl font-semibold text-gray-900">Announcements</h1>
          <p className="text-sm text-gray-500 mt-1">Banners and force-update notices shown inside the app</p>
        </div>
        <button onClick={() => setForm(empty)}
          className="flex items-center gap-2 px-4 py-2 bg-brand-500 text-white rounded-lg text-sm font-medium hover:bg-brand-600 transition-colors">
          <Plus size={16} /> New Announcement
        </button>
      </div>

      {/* Form */}
      {form && (
        <div className="bg-white rounded-xl border border-gray-100 p-6 space-y-4">
          <h2 className="text-sm font-semibold text-gray-700">{form.id ? "Edit" : "New"} Announcement</h2>
          <div className="grid grid-cols-2 gap-4">
            <F label="Title (Arabic)" value={form.title_ar} onChange={v => set("title_ar", v)} dir="rtl" />
            <F label="Title (English)" value={form.title_en} onChange={v => set("title_en", v)} />
          </div>
          <div className="grid grid-cols-2 gap-4">
            <F label="Body (Arabic)" value={form.body_ar} onChange={v => set("body_ar", v)} dir="rtl" multiline />
            <F label="Body (English)" value={form.body_en} onChange={v => set("body_en", v)} multiline />
          </div>
          <div className="grid grid-cols-3 gap-4">
            <div>
              <label className="block text-xs font-medium text-gray-500 mb-1">Severity</label>
              <select value={form.severity} onChange={e => set("severity", e.target.value)}
                className="w-full px-3 py-2 border border-gray-200 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-brand-500">
                <option value="info">info</option>
                <option value="warning">warning</option>
                <option value="maintenance">maintenance</option>
                <option value="force_update">force_update ⛔</option>
              </select>
            </div>
            <F label="Valid From" value={form.valid_from} onChange={v => set("valid_from", v)} type="datetime-local" />
            <F label="Valid Until (leave blank = no expiry)" value={form.valid_until} onChange={v => set("valid_until", v)} type="datetime-local" />
          </div>
          <div className="grid grid-cols-3 gap-4">
            <F label="Action Label (AR)" value={form.action_label_ar} onChange={v => set("action_label_ar", v)} dir="rtl" />
            <F label="Action Label (EN)" value={form.action_label_en} onChange={v => set("action_label_en", v)} />
            <F label="Action URL" value={form.action_url} onChange={v => set("action_url", v)} mono />
          </div>
          <div className="flex items-center gap-6">
            <label className="flex items-center gap-2 cursor-pointer">
              <input type="checkbox" checked={form.is_dismissible} onChange={e => set("is_dismissible", e.target.checked)} className="w-4 h-4 rounded" />
              <span className="text-sm text-gray-700">Dismissible</span>
            </label>
            <label className="flex items-center gap-2 cursor-pointer">
              <input type="checkbox" checked={form.is_active} onChange={e => set("is_active", e.target.checked)} className="w-4 h-4 rounded" />
              <span className="text-sm text-gray-700">Active</span>
            </label>
          </div>
          <div className="flex justify-end gap-2">
            <button onClick={() => setForm(null)} className="px-4 py-2 text-sm text-gray-600 hover:bg-gray-100 rounded-lg">Cancel</button>
            <button onClick={save} disabled={saving}
              className="flex items-center gap-2 px-4 py-2 bg-brand-500 text-white rounded-lg text-sm disabled:opacity-50">
              <Save size={14} /> {saving ? "Saving…" : "Save"}
            </button>
          </div>
        </div>
      )}

      {/* List */}
      <div className="space-y-3">
        {announcements.length === 0 && (
          <div className="bg-white rounded-xl border border-gray-100 p-10 text-center text-gray-400">
            <Megaphone size={32} className="mx-auto mb-2 opacity-30" />
            <p className="text-sm">No announcements yet</p>
          </div>
        )}
        {announcements.map(a => (
          <div key={a.id} className={`bg-white rounded-xl border p-5 ${a.is_active ? "border-gray-100" : "border-gray-50 opacity-60"}`}>
            <div className="flex items-start justify-between gap-4">
              <div className="flex-1">
                <div className="flex items-center gap-2 mb-1">
                  <span className={`px-2 py-0.5 rounded-full text-xs ${severityStyle[a.severity] ?? "bg-gray-100 text-gray-500"}`}>{a.severity}</span>
                  {!a.is_active && <span className="px-2 py-0.5 rounded-full text-xs bg-gray-100 text-gray-400">inactive</span>}
                </div>
                <p className="font-medium text-gray-900">{a.title_ar}</p>
                {a.body_ar && <p className="text-sm text-gray-500 mt-0.5" dir="rtl">{a.body_ar}</p>}
                <p className="text-xs text-gray-400 mt-1">
                  {fmtDate(a.valid_from)} → {a.valid_until ? fmtDate(a.valid_until) : "∞"}
                </p>
              </div>
              <div className="flex items-center gap-2">
                <button onClick={() => setForm(a)} className="text-gray-400 hover:text-brand-500 text-xs">Edit</button>
                <button onClick={() => remove(a.id!)} className="text-gray-300 hover:text-red-500">
                  <Trash2 size={14} />
                </button>
              </div>
            </div>
          </div>
        ))}
      </div>
    </div>
  );
}

function F({ label, value, onChange, dir, multiline, mono, type }: {
  label: string; value: string; onChange: (v: string) => void;
  dir?: string; multiline?: boolean; mono?: boolean; type?: string;
}) {
  const cls = `w-full px-3 py-2 border border-gray-200 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-brand-500 ${mono ? "font-mono" : ""}`;
  return (
    <div>
      <label className="block text-xs font-medium text-gray-500 mb-1">{label}</label>
      {multiline
        ? <textarea value={value} onChange={e => onChange(e.target.value)} rows={2} dir={dir} className={cls} />
        : <input type={type ?? "text"} value={value} onChange={e => onChange(e.target.value)} dir={dir} className={cls} />}
    </div>
  );
}
