"use client";

import Script from "next/script";
import { useRef, useState } from "react";
import { Play, RotateCcw } from "lucide-react";
import Link from "next/link";
import { Card, HelpNote, PageHeader, SectionHeader, StatusBadge, type Tone } from "@/components/ui/primitives";
import { Button } from "@/components/ui/form";
import { fmtPercent } from "@/lib/utils";

interface ParseResult {
  isTransaction: boolean;
  bankKey?: string;
  catalogRuleId?: string | null;
  contract?: string;
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
    // F-014/F-016: rules-aware entry — the Lab must exercise the SAME catalog
    // rule authority the device applies, with the real rules from the DB.
    parseSmsWithRules?: (
      rawMessage: string,
      sender: string,
      rulesJson: string,
    ) => string;
    parserLabContract?: string;
  }
}

const EXAMPLES = [
  {
    label: "مدفوعات الراجحي",
    sms: "تم خصم مبلغ 350.00 ريال من حسابك لدى STARBUCKS COFFEE بتاريخ 16/06/2026. الرصيد المتاح: 4,250.00 ريال",
    sender: "alrajhi",
  },
  {
    label: "تحويل الأهلي",
    sms: "تم تحويل مبلغ 1,200.00 SAR من حسابك. الرصيد: 8,500.00 SAR. 2026-06-16 09:30",
    sender: "snb",
  },
  {
    label: "شراء دولي — D360",
    sms: "Purchase: USD 29.99 (SAR 112.45)\nAt: Netflix\nAvailable Balance: SAR 3,400.00\n2026-06-16",
    sender: "d360",
  },
  {
    label: "رمز تحقق (يجب أن يُرفض)",
    sms: "رمز التحقق الخاص بك هو 492837. لا تشاركه مع أحد.",
    sender: "",
  },
];

/** The confidence gate, said in the operator's words. Thresholds unchanged. */
function gateDecision(r: ParseResult): { label: string; tone: Tone; note: string } {
  if (!r.isTransaction) {
    return {
      label: "مرفوضة",
      tone: "danger",
      note: "لم يتعرّف التطبيق على الرسالة كعملية مالية، فلن تُسجَّل إطلاقًا.",
    };
  }
  const conf = r.parseConfidence ?? 0;
  if (conf >= 0.92) {
    return {
      label: "تُسجَّل تلقائيًا",
      tone: "success",
      note: "درجة الثقة عالية، فتُضاف العملية مباشرة دون تدخّل المستخدم.",
    };
  }
  if (conf >= 0.7) {
    return {
      label: "بانتظار مراجعة المستخدم",
      tone: "warning",
      note: "درجة الثقة متوسطة، فتظهر العملية للمستخدم ليؤكّدها بنفسه.",
    };
  }
  return {
    label: "مرفوضة — ثقة منخفضة",
    tone: "danger",
    note: "درجة الثقة أقل من الحد الأدنى، فلا تُسجَّل العملية.",
  };
}

function Row({ label, value }: { label: string; value?: string | number | null }) {
  if (value === undefined || value === null || value === "") return null;
  return (
    <div className="flex items-start gap-3 border-b border-divider py-2.5 last:border-0">
      <span className="w-36 shrink-0 pt-0.5 text-tiny text-ink-faint">{label}</span>
      <span className="ltr min-w-0 break-all font-mono text-tiny text-ink">{String(value)}</span>
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
  // F-014: the actual catalog rules, fetched once — parsing runs them exactly
  // as the device engine does (sender/message eligibility + priority).
  const rulesRef = useRef<string | null>(null);

  async function loadRules(): Promise<string> {
    if (rulesRef.current !== null) return rulesRef.current;
    try {
      const res = await fetch("/api/admin-data?resource=sms_parsers", {
        cache: "no-store",
      });
      if (!res.ok) throw new Error(String(res.status));
      const data = (await res.json()) as { data?: unknown[] };
      rulesRef.current = JSON.stringify(data.data ?? []);
    } catch {
      rulesRef.current = "[]"; // fail closed — engine falls back like the device
    }
    return rulesRef.current;
  }

  async function handleParse() {
    setError(null);
    if (!sms.trim()) return;
    if (!scriptReady || !window.parseSmsWithRules) {
      setError("محرّك القراءة لم يُحمَّل بعد — انتظر لحظة ثم أعد المحاولة.");
      return;
    }
    try {
      const rules = await loadRules();
      const raw = window.parseSmsWithRules(sms, sender, rules);
      setResult(JSON.parse(raw));
    } catch (e) {
      setError(String(e));
    }
  }

  function loadExample(ex: (typeof EXAMPLES)[0]) {
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
        onError={() =>
          setError(
            "تعذّر تحميل محرّك القراءة (parser_lab.js). يحتاج المطوّر إلى إعادة بنائه عبر: npm run build:parser-lab",
          )
        }
      />

      <div className="max-w-5xl space-y-6">
        <PageHeader
          eyebrow="كتالوج البنوك والرسائل"
          title="معمل القراءة"
          description="الصق رسالة بنك حقيقية واعرف بالضبط كيف سيقرأها التطبيق، وهل سيسجّلها تلقائيًا أم لا."
        />

        <HelpNote>
          يعمل هنا نفس محرّك القراءة الموجود داخل التطبيق، لا نسخة مبسّطة منه، لذلك النتيجة مطابقة
          لما سيحدث على جهاز المستخدم. هذه الصفحة للتجربة فقط ولا تحفظ أي بيانات.
        </HelpNote>

        <Card>
          <SectionHeader title="أمثلة جاهزة" description="اضغط أي مثال لتعبئة الحقول مباشرة." />
          <div className="flex flex-wrap gap-2">
            {EXAMPLES.map((ex) => (
              <button
                key={ex.label}
                onClick={() => loadExample(ex)}
                className="rounded-full border border-line px-3.5 py-1.5 text-tiny text-ink-soft transition-colors hover:border-brand-300 hover:bg-brand-50 hover:text-brand-900"
              >
                {ex.label}
              </button>
            ))}
          </div>
        </Card>

        <div className="grid gap-5 lg:grid-cols-2">
          <Card>
            <SectionHeader title="الرسالة" />
            <div className="space-y-4">
              <div>
                <label htmlFor="sms" className="mb-1.5 block text-tiny font-medium text-ink">
                  نص الرسالة
                </label>
                <textarea
                  id="sms"
                  ref={textareaRef}
                  value={sms}
                  onChange={(e) => setSms(e.target.value)}
                  placeholder="الصق رسالة البنك هنا…"
                  rows={9}
                  dir="auto"
                  // Not monospaced: the pasted message is usually Arabic prose,
                  // which a mono face renders with broken letter joining.
                  className="w-full resize-y rounded-field border border-line bg-surface px-3.5 py-3 text-sm leading-relaxed text-ink placeholder:text-ink-faint focus:border-brand-500 focus:outline-none focus:ring-2 focus:ring-brand-500/25"
                />
              </div>

              <div>
                <label htmlFor="sender" className="mb-1.5 block text-tiny font-medium text-ink">
                  اسم أو رقم المُرسِل
                </label>
                <input
                  id="sender"
                  type="text"
                  value={sender}
                  onChange={(e) => setSender(e.target.value)}
                  placeholder="alrajhi، snb، d360…"
                  className="ltr w-full rounded-field border border-line bg-surface px-3.5 py-2.5 font-mono text-tiny text-ink placeholder:text-ink-faint focus:border-brand-500 focus:outline-none focus:ring-2 focus:ring-brand-500/25"
                />
                <p className="mt-1.5 text-micro text-ink-faint">
                  اختياري. تركه فارغًا يجرّب القراءة العامة بدون التعرّف على بنك معيّن.
                </p>
              </div>

              <div className="flex flex-wrap items-center gap-2.5">
                <Button icon={Play} onClick={handleParse} disabled={!scriptReady || !sms.trim()}>
                  اقرأ الرسالة
                </Button>
                <Button
                  variant="secondary"
                  icon={RotateCcw}
                  onClick={() => {
                    setSms("");
                    setSender("");
                    setResult(null);
                    setError(null);
                  }}
                >
                  مسح
                </Button>
                {!scriptReady && (
                  <span className="text-tiny text-warning">جارٍ تحميل محرّك القراءة…</span>
                )}
              </div>

              {error && (
                <p className="ltr rounded-field bg-danger-bg px-3 py-2.5 font-mono text-micro text-danger">
                  {error}
                </p>
              )}
            </div>
          </Card>

          <Card>
            <SectionHeader title="النتيجة" />
            {!result ? (
              <div className="flex min-h-[240px] items-center justify-center rounded-field border border-dashed border-line text-tiny text-ink-faint">
                ستظهر نتيجة القراءة هنا بعد الضغط على «اقرأ الرسالة».
              </div>
            ) : (
              <div className="space-y-4">
                <div className="rounded-field border border-hairline bg-raised/50 p-4">
                  <div className="mb-2 flex items-center justify-between gap-3">
                    <span className="text-tiny font-medium text-ink-soft">قرار التطبيق</span>
                    <StatusBadge label={gate!.label} tone={gate!.tone} />
                  </div>
                  <p className="text-tiny leading-relaxed text-ink-soft">{gate!.note}</p>
                </div>

                <div>
                  <Row label="البنك المتعرَّف عليه" value={result.bankKey ?? "لم يُحدَّد — قراءة عامة"} />
                  <Row label="هل هي عملية مالية؟" value={result.isTransaction ? "نعم" : "لا"} />
                  {result.isTransaction && (
                    <>
                      <Row
                        label="المبلغ"
                        value={
                          result.amount !== undefined
                            ? `${result.amount} ${result.currency ?? ""}`.trim()
                            : undefined
                        }
                      />
                      <Row label="نوع العملية" value={result.type} />
                      <Row label="مصدر العملية" value={result.source} />
                      <Row label="التاجر" value={result.merchant} />
                      <Row label="آخر 4 أرقام من البطاقة" value={result.cardLast4} />
                      <Row
                        label="الرصيد بعد العملية"
                        value={
                          result.balanceAfter !== undefined
                            ? `${result.balanceAfter} ${result.currency ?? ""}`.trim()
                            : undefined
                        }
                      />
                      <Row label="تاريخ العملية" value={result.occurredAt} />
                      <Row
                        label="المبلغ بالعملة الأجنبية"
                        value={
                          result.foreignAmount !== undefined
                            ? `${result.foreignAmount} ${result.foreignCurrency ?? ""}`.trim()
                            : undefined
                        }
                      />
                      <Row label="وسيلة الدفع" value={result.fundingSource} />
                      <Row
                        label="درجة الثقة"
                        value={
                          result.parseConfidence !== undefined
                            ? fmtPercent(result.parseConfidence)
                            : undefined
                        }
                      />
                    </>
                  )}
                </div>
              </div>
            )}
          </Card>
        </div>

        <p className="text-tiny text-ink-faint">
          إذا لم تُقرأ رسالة بنك معيّنة كما يجب، عدّل قاعدتها من{" "}
          <Link href="/parsers" className="font-medium text-brand-700 hover:text-brand-800">
            قواعد قراءة الرسائل
          </Link>{" "}
          ثم شغّل الفحص عليها.
        </p>
      </div>
    </>
  );
}
