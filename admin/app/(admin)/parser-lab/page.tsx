"use client";
import Script from "next/script";
import { useState, useRef } from "react";
import { FlaskConical, Play, RotateCcw } from "lucide-react";

interface ParseResult {
  isTransaction: boolean;
  bankKey?: string;
  confidence: number;
  amount?: number;
  currency?: string;
  type?: string;
  source?: string;
  merchant?: string;
  cardLast4?: string;
  balanceAfter?: number;
  occurredAt?: string;
  foreignAmount?: number;
  foreignCurrency?: string;
  fundingSource?: string;
  parseConfidence?: number;
}

declare global {
  interface Window {
    parseSms?: (rawMessage: string, sender: string) => string;
  }
}

const EXAMPLES = [
  {
    label: "Al Rajhi payment",
    sms: "تم خصم مبلغ 350.00 ريال من حسابك لدى STARBUCKS COFFEE بتاريخ 16/06/2026. الرصيد المتاح: 4,250.00 ريال",
    sender: "alrajhi",
  },
  {
    label: "SNB transfer",
    sms: "تم تحويل مبلغ 1,200.00 SAR من حسابك. الرصيد: 8,500.00 SAR. 2026-06-16 09:30",
    sender: "snb",
  },
  {
    label: "D360 international",
    sms: "Purchase: USD 29.99 (SAR 112.45)\nAt: Netflix\nAvailable Balance: SAR 3,400.00\n2026-06-16",
    sender: "d360",
  },
  {
    label: "OTP (should reject)",
    sms: "رمز التحقق الخاص بك هو 492837. لا تشاركه مع أحد.",
    sender: "",
  },
];

function gateDecision(r: ParseResult) {
  if (!r.isTransaction) return { label: "Rejected", color: "bg-red-100 text-red-700" };
  const conf = r.parseConfidence ?? 0;
  if (conf >= 0.92) return { label: "Auto-confirmed", color: "bg-green-100 text-green-700" };
  if (conf >= 0.70) return { label: "Pending review", color: "bg-amber-100 text-amber-700" };
  return { label: "Rejected (low conf)", color: "bg-red-100 text-red-700" };
}

function Row({ label, value }: { label: string; value?: string | number | null }) {
  if (value === undefined || value === null) return null;
  return (
    <div className="flex items-start gap-3 py-2 border-b border-gray-50 last:border-0">
      <span className="w-36 text-xs text-gray-400 shrink-0 pt-0.5">{label}</span>
      <span className="text-sm text-gray-900 font-mono break-all">{String(value)}</span>
    </div>
  );
}

export default function ParserLabPage() {
  const [sms, setSms] = useState("");
  const [sender, setSender] = useState("");
  const [result, setResult] = useState<ParseResult | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [scriptReady, setScriptReady] = useState(false);
  const textareaRef = useRef<HTMLTextAreaElement>(null);

  function handleParse() {
    setError(null);
    if (!sms.trim()) return;
    if (!scriptReady || !window.parseSms) {
      setError("Parser engine not loaded yet — wait a moment and retry.");
      return;
    }
    try {
      const raw = window.parseSms(sms, sender);
      setResult(JSON.parse(raw));
    } catch (e) {
      setError(String(e));
    }
  }

  function loadExample(ex: typeof EXAMPLES[0]) {
    setSms(ex.sms);
    setSender(ex.sender);
    setResult(null);
    setError(null);
    textareaRef.current?.focus();
  }

  const gate = result ? gateDecision(result) : null;

  return (
    <>
      <Script
        src="/parser_lab.js"
        strategy="afterInteractive"
        onLoad={() => setScriptReady(true)}
        onError={() => setError("Failed to load parser_lab.js — run: dart compile js tool/parser_lab_entry.dart -O2 -o ../admin/public/parser_lab.js")}
      />

      <div className="space-y-6 max-w-4xl">
        <div>
          <h1 className="text-2xl font-semibold text-gray-900 flex items-center gap-2">
            <FlaskConical size={22} className="text-brand-500" />
            Parser Lab
          </h1>
          <p className="text-sm text-gray-500 mt-1">
            Live Dart engine in the browser — same code as the app, single source of truth.
          </p>
        </div>

        {/* Examples */}
        <div className="flex flex-wrap gap-2">
          {EXAMPLES.map((ex) => (
            <button
              key={ex.label}
              onClick={() => loadExample(ex)}
              className="px-3 py-1.5 text-xs rounded-lg border border-gray-200 hover:border-brand-400 hover:text-brand-600 text-gray-600 transition-colors"
            >
              {ex.label}
            </button>
          ))}
        </div>

        <div className="grid grid-cols-1 lg:grid-cols-2 gap-6">
          {/* Input */}
          <div className="space-y-3">
            <div>
              <label className="block text-xs font-medium text-gray-500 mb-1">SMS Text</label>
              <textarea
                ref={textareaRef}
                value={sms}
                onChange={(e) => setSms(e.target.value)}
                placeholder="Paste bank SMS here…"
                rows={8}
                dir="auto"
                className="w-full rounded-xl border border-gray-200 px-4 py-3 text-sm font-mono focus:outline-none focus:ring-2 focus:ring-brand-400 resize-none"
              />
            </div>
            <div>
              <label className="block text-xs font-medium text-gray-500 mb-1">Sender ID (optional)</label>
              <input
                type="text"
                value={sender}
                onChange={(e) => setSender(e.target.value)}
                placeholder="e.g. alrajhi, snb, d360"
                className="w-full rounded-xl border border-gray-200 px-4 py-2.5 text-sm font-mono focus:outline-none focus:ring-2 focus:ring-brand-400"
              />
            </div>
            <div className="flex gap-2">
              <button
                onClick={handleParse}
                disabled={!scriptReady || !sms.trim()}
                className="flex items-center gap-2 px-4 py-2 bg-brand-500 text-white rounded-lg text-sm font-medium hover:bg-brand-600 transition-colors disabled:opacity-40 disabled:cursor-not-allowed"
              >
                <Play size={14} /> Parse
              </button>
              <button
                onClick={() => { setSms(""); setSender(""); setResult(null); setError(null); }}
                className="flex items-center gap-2 px-4 py-2 border border-gray-200 text-gray-600 rounded-lg text-sm hover:bg-gray-50 transition-colors"
              >
                <RotateCcw size={14} /> Clear
              </button>
            </div>
            {!scriptReady && (
              <p className="text-xs text-amber-600">Loading Dart engine…</p>
            )}
            {error && (
              <p className="text-xs text-red-600 bg-red-50 rounded-lg p-3 font-mono">{error}</p>
            )}
          </div>

          {/* Results */}
          <div>
            <label className="block text-xs font-medium text-gray-500 mb-1">Result</label>
            {!result ? (
              <div className="h-full min-h-[200px] rounded-xl border border-dashed border-gray-200 flex items-center justify-center text-gray-300 text-sm">
                Parse output will appear here
              </div>
            ) : (
              <div className="rounded-xl border border-gray-200 bg-white overflow-hidden">
                {/* Gate decision header */}
                <div className={`px-4 py-3 flex items-center justify-between border-b border-gray-100 ${result.isTransaction ? "bg-gray-50" : "bg-red-50"}`}>
                  <span className="text-xs font-medium text-gray-500">Gate decision</span>
                  <span className={`px-2.5 py-1 rounded-full text-xs font-semibold ${gate!.color}`}>
                    {gate!.label}
                  </span>
                </div>

                <div className="px-4 py-2">
                  <Row label="Bank profile" value={result.bankKey ?? "(none — generic)"} />
                  <Row label="Is transaction" value={String(result.isTransaction)} />
                  {result.isTransaction && (
                    <>
                      <Row label="Amount" value={result.amount !== undefined ? `${result.amount} ${result.currency}` : undefined} />
                      <Row label="Type" value={result.type} />
                      <Row label="Source" value={result.source} />
                      <Row label="Merchant" value={result.merchant} />
                      <Row label="Card last 4" value={result.cardLast4} />
                      <Row label="Balance after" value={result.balanceAfter !== undefined ? `${result.balanceAfter} ${result.currency}` : undefined} />
                      <Row label="Date" value={result.occurredAt} />
                      <Row label="Foreign amount" value={result.foreignAmount !== undefined ? `${result.foreignAmount} ${result.foreignCurrency}` : undefined} />
                      <Row label="Funding source" value={result.fundingSource} />
                      <Row label="Confidence" value={result.parseConfidence !== undefined ? `${(result.parseConfidence * 100).toFixed(0)}%` : undefined} />
                    </>
                  )}
                </div>
              </div>
            )}
          </div>
        </div>
      </div>
    </>
  );
}
