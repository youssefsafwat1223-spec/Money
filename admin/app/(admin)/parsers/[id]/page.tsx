"use client";
import { useEffect, useState } from "react";
import { useParams, useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase";
import { ArrowLeft, Save, Trash2, Play, CheckCircle, XCircle, Clock } from "lucide-react";
import Link from "next/link";

type Parser = {
  id?: string; bank_id: string; sender_pattern: string; message_pattern: string;
  transaction_type: string; language: string; priority: number;
  extracted_fields: string; is_active: boolean; validation_status: string;
};

const empty: Parser = {
  bank_id: "", sender_pattern: "", message_pattern: "", transaction_type: "debit",
  language: "ar", priority: 5, extracted_fields: '{"amount":"amount","currency":"currency"}',
  is_active: true, validation_status: "pending",
};

export default function ParserFormPage() {
  const { id } = useParams<{ id: string }>();
  const isNew = id === "new";
  const router = useRouter();
  const supabase = createClient();
  const [parser, setParser] = useState<Parser>(empty);
  const [banks, setBanks] = useState<{ id: string; name_ar: string }[]>([]);
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);
  const [testing, setTesting] = useState(false);
  const [testResult, setTestResult] = useState<Record<string, unknown> | null>(null);
  const [error, setError] = useState("");

  useEffect(() => {
    const load = async () => {
      const { data: b } = await supabase.from("banks").select("id, name_ar").order("name_ar");
      setBanks(b ?? []);
      if (!isNew) {
        const { data } = await supabase.from("sms_parsers").select("*").eq("id", id).single();
        if (data) setParser({ ...data, extracted_fields: JSON.stringify(data.extracted_fields) });
      }
      setLoading(false);
    };
    load();
  }, [id]);

  function set(field: keyof Parser, value: unknown) {
    setParser(prev => ({ ...prev, [field]: value }));
  }

  async function save() {
    setSaving(true); setError("");
    try {
      const payload = { ...parser, extracted_fields: JSON.parse(parser.extracted_fields) };
      if (isNew) {
        const { error } = await supabase.from("sms_parsers").insert(payload);
        if (error) throw error;
      } else {
        const { error } = await supabase.from("sms_parsers").update(payload).eq("id", id);
        if (error) throw error;
      }
      router.push("/parsers");
    } catch (e: unknown) {
      setError(e instanceof Error ? e.message : "Save failed");
    } finally { setSaving(false); }
  }

  async function runTest() {
    if (isNew || !id) return;
    setTesting(true); setTestResult(null);
    const { data: { session } } = await supabase.auth.getSession();
    const res = await fetch(`${process.env.NEXT_PUBLIC_SUPABASE_URL}/functions/v1/parser-test`, {
      method: "POST",
      headers: { "Content-Type": "application/json", "Authorization": `Bearer ${session?.access_token}` },
      body: JSON.stringify({ parser_id: id }),
    });
    const json = await res.json();
    setTestResult(json);
    setTesting(false);
  }

  if (loading) return <div className="text-gray-400 text-sm">Loading…</div>;

  const statusColor = { passed: "text-green-600", failed: "text-red-600", pending: "text-amber-600" };
  const StatusIcon = parser.validation_status === "passed" ? CheckCircle : parser.validation_status === "failed" ? XCircle : Clock;

  return (
    <div className="max-w-3xl space-y-6">
      <div className="flex items-center gap-3">
        <Link href="/parsers" className="text-gray-400 hover:text-gray-600"><ArrowLeft size={20} /></Link>
        <h1 className="text-2xl font-semibold text-gray-900">{isNew ? "Add Parser" : "Edit Parser"}</h1>
        {!isNew && (
          <span className={`flex items-center gap-1.5 text-sm font-medium ${statusColor[parser.validation_status as keyof typeof statusColor] ?? "text-gray-500"}`}>
            <StatusIcon size={16} /> {parser.validation_status}
          </span>
        )}
      </div>

      <div className="bg-white rounded-xl border border-gray-100 p-6 space-y-4">
        <div>
          <label className="block text-xs font-medium text-gray-500 mb-1">Bank</label>
          <select value={parser.bank_id} onChange={e => set("bank_id", e.target.value)}
            className="w-full px-3 py-2 border border-gray-200 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-brand-500">
            <option value="">Select bank…</option>
            {banks.map(b => <option key={b.id} value={b.id}>{b.name_ar}</option>)}
          </select>
        </div>
        <Field label="Sender Pattern (Dart regex)" value={parser.sender_pattern} onChange={v => set("sender_pattern", v)} mono />
        <Field label="Message Pattern (Dart regex — use (?<amount>...) named groups)" value={parser.message_pattern} onChange={v => set("message_pattern", v)} mono multiline />
        <Field label='Extracted Fields (JSON map)' value={parser.extracted_fields} onChange={v => set("extracted_fields", v)} mono />
        <div className="grid grid-cols-3 gap-4">
          <div>
            <label className="block text-xs font-medium text-gray-500 mb-1">Transaction Type</label>
            <select value={parser.transaction_type} onChange={e => set("transaction_type", e.target.value)}
              className="w-full px-3 py-2 border border-gray-200 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-brand-500">
              <option value="debit">debit</option>
              <option value="credit">credit</option>
              <option value="balance_inquiry">balance_inquiry</option>
            </select>
          </div>
          <div>
            <label className="block text-xs font-medium text-gray-500 mb-1">Language</label>
            <select value={parser.language} onChange={e => set("language", e.target.value)}
              className="w-full px-3 py-2 border border-gray-200 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-brand-500">
              <option value="ar">ar</option>
              <option value="en">en</option>
              <option value="ar_en">ar_en</option>
            </select>
          </div>
          <Field label="Priority" value={String(parser.priority)} onChange={v => set("priority", Number(v))} />
        </div>
        <label className="flex items-center gap-3 cursor-pointer">
          <input type="checkbox" checked={parser.is_active} onChange={e => set("is_active", e.target.checked)} className="w-4 h-4 rounded border-gray-300 text-brand-500" />
          <span className="text-sm font-medium text-gray-700">Active</span>
        </label>
      </div>

      {/* Parser Lab */}
      {!isNew && (
        <div className="bg-white rounded-xl border border-gray-100 p-6 space-y-4">
          <div className="flex items-center justify-between">
            <h2 className="text-sm font-semibold text-gray-700">Parser Lab — Golden Tests</h2>
            <button onClick={runTest} disabled={testing}
              className="flex items-center gap-2 px-3 py-1.5 bg-brand-500 text-white rounded-lg text-xs font-medium hover:bg-brand-600 disabled:opacity-50 transition-colors">
              <Play size={12} /> {testing ? "Running…" : "Run Tests"}
            </button>
          </div>

          {testResult && (
            <div className="space-y-3">
              <div className={`px-3 py-2 rounded-lg text-sm font-medium ${(testResult.validation_status as string) === "passed" ? "bg-green-50 text-green-700" : "bg-red-50 text-red-700"}`}>
                {(testResult.validation_status as string) === "passed"
                  ? `Passed — ${testResult.passed_count as number}/${testResult.golden_test_count as number} tests`
                  : `Failed — ${testResult.failure_reason as string ?? `${testResult.failed_count} tests failed`}`}
              </div>
              {Array.isArray(testResult.results) && testResult.results.length > 0 && (
                <div className="divide-y divide-gray-50">
                  {(testResult.results as Array<{ test_id: string; sender: string; passed: boolean; failure_kind: string | null; matched: boolean; extracted_amount: number | null }>).map(r => (
                    <div key={r.test_id} className="py-2 flex items-center gap-3 text-xs">
                      {r.passed ? <CheckCircle size={14} className="text-green-500 shrink-0" /> : <XCircle size={14} className="text-red-500 shrink-0" />}
                      <span className="font-mono text-gray-500 w-24 truncate">{r.sender}</span>
                      {!r.passed && <span className="text-red-500">{r.failure_kind}</span>}
                      {r.extracted_amount != null && <span className="text-gray-400">amount: {r.extracted_amount}</span>}
                    </div>
                  ))}
                </div>
              )}
              {(testResult.message as string) && <p className="text-xs text-gray-500">{testResult.message as string}</p>}
            </div>
          )}
          {!testResult && <p className="text-xs text-gray-400">Run tests to validate this parser against golden SMS samples.</p>}
        </div>
      )}

      {error && <p className="text-sm text-red-600 bg-red-50 px-3 py-2 rounded-lg">{error}</p>}

      <div className="flex items-center justify-between">
        <div>
          {!isNew && (
            <button onClick={async () => { if (!confirm("Delete?")) return; await supabase.from("sms_parsers").delete().eq("id", id); router.push("/parsers"); }}
              className="flex items-center gap-2 px-4 py-2 text-red-600 hover:bg-red-50 rounded-lg text-sm transition-colors">
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

function Field({ label, value, onChange, mono, multiline }: {
  label: string; value: string; onChange: (v: string) => void; mono?: boolean; multiline?: boolean;
}) {
  const cls = `w-full px-3 py-2 border border-gray-200 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-brand-500 ${mono ? "font-mono" : ""}`;
  return (
    <div>
      <label className="block text-xs font-medium text-gray-500 mb-1">{label}</label>
      {multiline
        ? <textarea value={value} onChange={e => onChange(e.target.value)} rows={3} className={cls} />
        : <input value={value} onChange={e => onChange(e.target.value)} className={cls} />}
    </div>
  );
}
