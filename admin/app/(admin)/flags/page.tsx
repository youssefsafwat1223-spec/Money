"use client";
import { useEffect, useState } from "react";
import { Save } from "lucide-react";

type Flag = {
  id: string; key: string; value_type: string; value: string;
  description: string | null; rollout_percent: number; is_active: boolean;
};

export default function FlagsPage() {
  const [flags, setFlags] = useState<Flag[]>([]);
  const [saving, setSaving] = useState<string | null>(null);

  useEffect(() => {
    fetch("/api/admin-data?resource=feature_flags", { cache: "no-store" })
      .then(response => response.json())
      .then(body => setFlags(body.data ?? []));
  }, []);

  async function toggle(flag: Flag) {
    const activating = !flag.is_active;
    if (activating && flag.rollout_percent > 0) {
      const confirmed = window.confirm(
        `"${flag.key}" will go live to ${flag.rollout_percent}% of users immediately. Continue?`
      );
      if (!confirmed) return;
    }
    const updated = { ...flag, is_active: activating };
    const response = await fetch("/api/admin-data", {
      method: "PATCH",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ resource: "feature_flags", ...updated }),
    });
    if (response.ok) setFlags(prev => prev.map(f => f.id === flag.id ? updated : f));
  }

  async function updateRollout(flag: Flag, pct: number) {
    setFlags(prev => prev.map(f => f.id === flag.id ? { ...f, rollout_percent: pct } : f));
  }

  async function saveFlag(flag: Flag) {
    setSaving(flag.id);
    await fetch("/api/admin-data", {
      method: "PATCH",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ resource: "feature_flags", ...flag }),
    });
    setSaving(null);
  }

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold text-gray-900">Feature Flags</h1>
        <p className="text-sm text-gray-500 mt-1">Toggle features without an app update</p>
      </div>

      <div className="space-y-3">
        {flags.map(flag => (
          <div key={flag.id} className="bg-white rounded-xl border border-gray-100 p-5">
            <div className="flex items-start justify-between gap-4">
              <div className="flex-1">
                <div className="flex items-center gap-3">
                  <span className="font-mono text-sm font-semibold text-gray-900">{flag.key}</span>
                  <span className="px-2 py-0.5 bg-gray-100 text-gray-500 rounded text-xs">{flag.value_type}</span>
                </div>
                {flag.description && <p className="text-xs text-gray-400 mt-0.5">{flag.description}</p>}
              </div>

              {/* Toggle */}
              <button onClick={() => toggle(flag)}
                className={`relative inline-flex h-6 w-11 items-center rounded-full transition-colors ${flag.is_active ? "bg-brand-500" : "bg-gray-200"}`}>
                <span className={`inline-block h-4 w-4 transform rounded-full bg-white shadow transition-transform ${flag.is_active ? "translate-x-6" : "translate-x-1"}`} />
              </button>
            </div>

            {flag.is_active && (
              <div className="mt-4 grid grid-cols-2 gap-4 pt-4 border-t border-gray-50">
                <div>
                  <label className="block text-xs font-medium text-gray-500 mb-1">Value</label>
                  <input value={flag.value} onChange={e => setFlags(prev => prev.map(f => f.id === flag.id ? { ...f, value: e.target.value } : f))}
                    className="w-full px-3 py-1.5 border border-gray-200 rounded-lg text-sm font-mono focus:outline-none focus:ring-2 focus:ring-brand-500" />
                </div>
                <div>
                  <label className="block text-xs font-medium text-gray-500 mb-1">
                    Rollout — {flag.rollout_percent}%
                  </label>
                  <input type="range" min={0} max={100} value={flag.rollout_percent}
                    onChange={e => updateRollout(flag, Number(e.target.value))}
                    className="w-full accent-brand-500" />
                </div>
                <div className="col-span-2 flex justify-end">
                  <button onClick={() => saveFlag(flag)} disabled={saving === flag.id}
                    className="flex items-center gap-1.5 px-3 py-1.5 bg-brand-500 text-white rounded-lg text-xs font-medium hover:bg-brand-600 disabled:opacity-50 transition-colors">
                    <Save size={12} /> {saving === flag.id ? "Saving…" : "Save"}
                  </button>
                </div>
              </div>
            )}
          </div>
        ))}
      </div>
    </div>
  );
}
