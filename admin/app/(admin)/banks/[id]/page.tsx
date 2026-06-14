"use client";
import { useEffect, useState } from "react";
import { useParams, useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase";
import { ArrowLeft, Save, Trash2 } from "lucide-react";
import Link from "next/link";

type Bank = {
  id?: string;
  name_ar: string;
  name_en: string;
  short_code: string;
  country_code: string;
  sms_senders: string;
  supported_currencies: string;
  color_hex: string;
  is_active: boolean;
  sort_order: number;
};

const empty: Bank = {
  name_ar: "", name_en: "", short_code: "", country_code: "EG",
  sms_senders: "[]", supported_currencies: '["EGP"]',
  color_hex: "#056A95", is_active: true, sort_order: 0,
};

export default function BankFormPage() {
  const { id } = useParams<{ id: string }>();
  const isNew = id === "new";
  const router = useRouter();
  const supabase = createClient();
  const [bank, setBank] = useState<Bank>(empty);
  const [loading, setLoading] = useState(!isNew);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState("");

  useEffect(() => {
    if (isNew) return;
    supabase.from("banks").select("*").eq("id", id).single().then(({ data }) => {
      if (data) setBank({ ...data, sms_senders: JSON.stringify(data.sms_senders), supported_currencies: JSON.stringify(data.supported_currencies) });
      setLoading(false);
    });
  }, [id]);

  function set(field: keyof Bank, value: unknown) {
    setBank(prev => ({ ...prev, [field]: value }));
  }

  async function save() {
    setSaving(true); setError("");
    try {
      const payload = {
        ...bank,
        sms_senders: JSON.parse(bank.sms_senders),
        supported_currencies: JSON.parse(bank.supported_currencies),
      };
      if (isNew) {
        const { error } = await supabase.from("banks").insert(payload);
        if (error) throw error;
      } else {
        const { error } = await supabase.from("banks").update(payload).eq("id", id);
        if (error) throw error;
      }
      router.push("/banks");
    } catch (e: unknown) {
      setError(e instanceof Error ? e.message : "Save failed");
    } finally {
      setSaving(false);
    }
  }

  async function remove() {
    if (!confirm("Delete this bank?")) return;
    await supabase.from("banks").delete().eq("id", id);
    router.push("/banks");
  }

  if (loading) return <div className="text-gray-400 text-sm">Loading…</div>;

  return (
    <div className="max-w-2xl space-y-6">
      <div className="flex items-center gap-3">
        <Link href="/banks" className="text-gray-400 hover:text-gray-600">
          <ArrowLeft size={20} />
        </Link>
        <h1 className="text-2xl font-semibold text-gray-900">
          {isNew ? "Add Bank" : "Edit Bank"}
        </h1>
      </div>

      <div className="bg-white rounded-xl border border-gray-100 p-6 space-y-4">
        <div className="grid grid-cols-2 gap-4">
          <Field label="Name (Arabic)" value={bank.name_ar} onChange={v => set("name_ar", v)} dir="rtl" />
          <Field label="Name (English)" value={bank.name_en} onChange={v => set("name_en", v)} />
        </div>
        <div className="grid grid-cols-2 gap-4">
          <Field label="Short Code" value={bank.short_code} onChange={v => set("short_code", v)} mono />
          <Field label="Country Code" value={bank.country_code} onChange={v => set("country_code", v)} />
        </div>
        <Field label='SMS Senders (JSON array, e.g. ["NBE","02NBE"])' value={bank.sms_senders} onChange={v => set("sms_senders", v)} mono />
        <Field label='Supported Currencies (JSON array, e.g. ["EGP","USD"])' value={bank.supported_currencies} onChange={v => set("supported_currencies", v)} mono />
        <div className="grid grid-cols-2 gap-4">
          <Field label="Color Hex" value={bank.color_hex} onChange={v => set("color_hex", v)} mono />
          <Field label="Sort Order" value={String(bank.sort_order)} onChange={v => set("sort_order", Number(v))} />
        </div>
        <label className="flex items-center gap-3 cursor-pointer">
          <input type="checkbox" checked={bank.is_active} onChange={e => set("is_active", e.target.checked)}
            className="w-4 h-4 rounded border-gray-300 text-brand-500" />
          <span className="text-sm font-medium text-gray-700">Active</span>
        </label>
      </div>

      {error && <p className="text-sm text-red-600 bg-red-50 px-3 py-2 rounded-lg">{error}</p>}

      <div className="flex items-center justify-between">
        <div>
          {!isNew && (
            <button onClick={remove} className="flex items-center gap-2 px-4 py-2 text-red-600 hover:bg-red-50 rounded-lg text-sm transition-colors">
              <Trash2 size={16} /> Delete
            </button>
          )}
        </div>
        <button onClick={save} disabled={saving}
          className="flex items-center gap-2 px-5 py-2 bg-brand-500 text-white rounded-lg text-sm font-medium hover:bg-brand-600 disabled:opacity-50 transition-colors">
          <Save size={16} /> {saving ? "Saving…" : "Save"}
        </button>
      </div>
    </div>
  );
}

function Field({ label, value, onChange, mono, dir }: {
  label: string; value: string; onChange: (v: string) => void; mono?: boolean; dir?: string;
}) {
  return (
    <div>
      <label className="block text-xs font-medium text-gray-500 mb-1">{label}</label>
      <input value={value} onChange={e => onChange(e.target.value)} dir={dir}
        className={`w-full px-3 py-2 border border-gray-200 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-brand-500 ${mono ? "font-mono" : ""}`} />
    </div>
  );
}
