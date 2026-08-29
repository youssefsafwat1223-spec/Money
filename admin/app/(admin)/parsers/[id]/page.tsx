"use client";

import Link from "next/link";
import { useEffect, useState } from "react";
import { useParams, useRouter } from "next/navigation";
import { ArrowLeft, CheckCircle2, Play, Save, Trash2, XCircle } from "lucide-react";
import { createClient } from "@/lib/supabase";
import {
  Banner,
  Card,
  ErrorState,
  HelpNote,
  LoadingState,
  PageHeader,
  SectionHeader,
  StatusBadge,
} from "@/components/ui/primitives";
import { Button, CheckboxField, SelectField, TextAreaField, TextField } from "@/components/ui/form";
import { ConfirmDialog, type ConfirmSpec } from "@/components/ui/confirm-dialog";
import { LANGUAGE_OPTIONS, TXN_TYPE_OPTIONS, validationLabel, validationTone } from "@/lib/labels";
import { fmt } from "@/lib/utils";

type Parser = {
  bank_id: string;
  sender_pattern: string;
  message_pattern: string;
  transaction_type: string;
  language: string;
  priority: number;
  extracted_fields: string;
  is_active: boolean;
  validation_status: string;
};

const empty: Parser = {
  bank_id: "",
  sender_pattern: "",
  message_pattern: "",
  transaction_type: "debit",
  language: "ar",
  priority: 5,
  extracted_fields: '{"amount":"amount","currency":"currency"}',
  is_active: true,
  validation_status: "pending",
};

type TestResult = {
  validation_status?: string;
  passed_count?: number;
  failed_count?: number;
  golden_test_count?: number;
  failure_reason?: string;
  message?: string;
  results?: {
    test_id: string;
    sender: string;
    passed: boolean;
    failure_kind: string | null;
    matched: boolean;
    extracted_amount: number | null;
  }[];
};

export default function ParserFormPage() {
  const { id } = useParams<{ id: string }>();
  const isNew = id === "new";
  const router = useRouter();
  const supabase = createClient();
  const [parser, setParser] = useState<Parser>(empty);
  const [banks, setBanks] = useState<{ id: string; name_ar: string }[]>([]);
  const [loading, setLoading] = useState(true);
  const [loadError, setLoadError] = useState("");
  const [saving, setSaving] = useState(false);
  const [deleting, setDeleting] = useState(false);
  const [testing, setTesting] = useState(false);
  const [testResult, setTestResult] = useState<TestResult | null>(null);
  const [error, setError] = useState("");
  const [confirm, setConfirm] = useState<ConfirmSpec | null>(null);

  useEffect(() => {
    const load = async () => {
      try {
        const response = await fetch(
          `/api/admin-data?resource=sms_parsers${isNew ? "" : `&id=${encodeURIComponent(id)}`}`,
          { cache: "no-store" },
        );
        const body = await response.json();
        if (!response.ok) throw new Error(body.error ?? "تعذّر تحميل بيانات القاعدة");
        setBanks(body.banks ?? []);
        if (!isNew && body.data) {
          setParser({
            ...body.data,
            extracted_fields: JSON.stringify(body.data.extracted_fields),
          });
        }
      } catch (e) {
        setLoadError(e instanceof Error ? e.message : "تعذّر تحميل بيانات القاعدة");
      } finally {
        setLoading(false);
      }
    };
    load();
  }, [id, isNew]);

  function set<K extends keyof Parser>(field: K, value: Parser[K]) {
    setParser((prev) => ({ ...prev, [field]: value }));
  }

  async function save() {
    if (!parser.bank_id) return setError("اختر البنك الذي تخصّه هذه القاعدة.");
    setSaving(true);
    setError("");
    try {
      let extracted: unknown;
      try {
        extracted = JSON.parse(parser.extracted_fields);
      } catch {
        throw new Error("صيغة «الحقول المستخرَجة» غير صحيحة — يجب أن تكون JSON صالحًا.");
      }
      const payload = { ...parser, extracted_fields: extracted };
      const response = await fetch("/api/admin-data", {
        method: isNew ? "POST" : "PATCH",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ resource: "sms_parsers", id: isNew ? undefined : id, ...payload }),
      });
      const result = await response.json();
      if (!response.ok) throw new Error(result.error ?? "تعذّر حفظ القاعدة");
      router.push("/parsers");
      router.refresh();
    } catch (e: unknown) {
      setError(e instanceof Error ? e.message : "تعذّر حفظ القاعدة");
    } finally {
      setSaving(false);
    }
  }

  async function runTest() {
    if (isNew || !id) return;
    setTesting(true);
    setTestResult(null);
    setError("");
    try {
      const {
        data: { session },
      } = await supabase.auth.getSession();
      const res = await fetch(`${process.env.NEXT_PUBLIC_SUPABASE_URL}/functions/v1/parser-test`, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${session?.access_token}`,
        },
        body: JSON.stringify({ parser_id: id }),
      });
      setTestResult(await res.json());
    } catch {
      setError("تعذّر تشغيل الفحص — تأكد من أن الخدمة تعمل ثم أعد المحاولة.");
    } finally {
      setTesting(false);
    }
  }

  async function remove() {
    setDeleting(true);
    const response = await fetch(
      `/api/admin-data?resource=sms_parsers&id=${encodeURIComponent(id)}`,
      { method: "DELETE" },
    );
    setDeleting(false);
    setConfirm(null);
    if (!response.ok) {
      const body = await response.json().catch(() => ({}));
      setError(body.error ?? "تعذّر حذف القاعدة");
      return;
    }
    router.push("/parsers");
    router.refresh();
  }

  if (loading) return <LoadingState label="جارٍ تحميل بيانات القاعدة…" />;
  if (loadError) {
    return (
      <ErrorState
        title="تعذّر فتح هذه القاعدة"
        detail={loadError}
        action={
          <Link href="/parsers" className="text-sm font-medium text-brand-700 hover:text-brand-800">
            العودة إلى قائمة القواعد
          </Link>
        }
      />
    );
  }

  const testPassed = testResult?.validation_status === "passed";

  return (
    <div className="max-w-4xl space-y-6">
      <div className="flex items-center gap-3">
        <Link
          href="/parsers"
          aria-label="العودة إلى قائمة القواعد"
          className="rounded-field p-1.5 text-ink-faint transition-colors hover:bg-muted hover:text-ink"
        >
          <ArrowLeft size={19} className="flip-x" />
        </Link>
        <PageHeader
          eyebrow="كتالوج البنوك والرسائل"
          title={isNew ? "إضافة قاعدة قراءة" : "تعديل قاعدة القراءة"}
          description="القاعدة تحدّد شكل رسالة البنك وما يُستخرج منها."
          action={
            !isNew ? (
              <StatusBadge
                label={validationLabel(parser.validation_status)}
                tone={validationTone(parser.validation_status)}
              />
            ) : undefined
          }
        />
      </div>

      <Card>
        <SectionHeader title="البنك ونوع العملية" />
        <div className="grid gap-4 md:grid-cols-3">
          <SelectField
            label="البنك"
            required
            value={parser.bank_id}
            placeholder="اختر البنك…"
            onChange={(e) => set("bank_id", e.target.value)}
            options={banks.map((b) => ({ value: b.id, label: b.name_ar }))}
            hint="القاعدة تنطبق على رسائل هذا البنك فقط."
          />
          <SelectField
            label="نوع العملية"
            value={parser.transaction_type}
            onChange={(e) => set("transaction_type", e.target.value)}
            options={TXN_TYPE_OPTIONS}
            hint="هل تصف هذه الرسالة خصمًا أم إيداعًا أم استعلام رصيد؟"
          />
          <SelectField
            label="لغة الرسالة"
            value={parser.language}
            onChange={(e) => set("language", e.target.value)}
            options={LANGUAGE_OPTIONS}
          />
        </div>
      </Card>

      <Card>
        <SectionHeader
          title="أنماط المطابقة"
          description="تُكتب بصيغة التعابير النمطية (Regex) الخاصة بلغة Dart."
        />
        <div className="space-y-4">
          <TextField
            label="نمط المُرسِل"
            required
            mono
            value={parser.sender_pattern}
            onChange={(e) => set("sender_pattern", e.target.value)}
            hint="يُطابَق مع اسم أو رقم مُرسِل الرسالة لتحديد أنها من هذا البنك."
          />
          <TextAreaField
            label="نمط نص الرسالة"
            required
            mono
            rows={4}
            value={parser.message_pattern}
            onChange={(e) => set("message_pattern", e.target.value)}
            hint="استخدم مجموعات مسمّاة بصيغة Dart مثل (?<amount>…) لتحديد المبلغ والتاجر."
          />
          <TextAreaField
            label="الحقول المستخرَجة"
            mono
            rows={2}
            value={parser.extracted_fields}
            onChange={(e) => set("extracted_fields", e.target.value)}
            hint='خريطة JSON تربط اسم المجموعة في النمط بالحقل داخل التطبيق. مثال: {"amount":"amount"}'
          />
        </div>
      </Card>

      <Card>
        <SectionHeader title="الأولوية والحالة" />
        <div className="grid gap-4 md:grid-cols-2">
          <TextField
            label="الأولوية"
            type="number"
            value={String(parser.priority)}
            onChange={(e) => set("priority", Number(e.target.value))}
            hint="عند تطابق أكثر من قاعدة مع الرسالة نفسها، تُستخدم القاعدة ذات الرقم الأعلى."
          />
          <div className="flex items-end pb-2">
            <CheckboxField
              label="القاعدة مفعّلة"
              hint="التفعيل وحده لا يكفي — لا بد أن تجتاز الفحص أيضًا حتى تصل إلى المستخدمين."
              checked={parser.is_active}
              onChange={(v) => set("is_active", v)}
            />
          </div>
        </div>
      </Card>

      {/* Golden-test run — unchanged contract, clearer presentation. */}
      {!isNew && (
        <Card>
          <SectionHeader
            title="فحص القاعدة"
            description="تُجرَّب القاعدة على رسائل حقيقية محفوظة مسبقًا للتأكد من أنها تستخرج البيانات الصحيحة."
            action={
              <Button size="sm" icon={Play} onClick={runTest} loading={testing}>
                {testing ? "جارٍ الفحص…" : "تشغيل الفحص"}
              </Button>
            }
          />

          {!testResult ? (
            <HelpNote>
              شغّل الفحص بعد أي تعديل. القاعدة لا تصل إلى التطبيق قبل أن تجتاز الفحص.
            </HelpNote>
          ) : (
            <div className="space-y-3">
              <div
                className={`flex items-center gap-2 rounded-field px-3.5 py-3 text-sm font-medium ${
                  testPassed ? "bg-success-bg text-success" : "bg-danger-bg text-danger"
                }`}
              >
                {testPassed ? <CheckCircle2 size={16} /> : <XCircle size={16} />}
                {testPassed
                  ? `اجتازت الفحص — ${fmt(testResult.passed_count ?? 0)} من ${fmt(
                      testResult.golden_test_count ?? 0,
                    )} رسالة اختبار`
                  : `فشل الفحص — ${
                      testResult.failure_reason ??
                      `${fmt(testResult.failed_count ?? 0)} رسالة اختبار لم تُقرأ بشكل صحيح`
                    }`}
              </div>

              {Array.isArray(testResult.results) && testResult.results.length > 0 && (
                <ul className="divide-y divide-divider rounded-field border border-hairline">
                  {testResult.results.map((r) => (
                    <li key={r.test_id} className="flex flex-wrap items-center gap-3 px-3.5 py-2.5 text-tiny">
                      {r.passed ? (
                        <CheckCircle2 size={14} className="shrink-0 text-success" />
                      ) : (
                        <XCircle size={14} className="shrink-0 text-danger" />
                      )}
                      <span className="ltr w-32 truncate font-mono text-ink-soft">{r.sender}</span>
                      {!r.passed && <span className="ltr text-danger">{r.failure_kind}</span>}
                      {r.extracted_amount != null && (
                        <span className="tnum text-ink-faint">
                          المبلغ المستخرَج: {fmt(r.extracted_amount)}
                        </span>
                      )}
                    </li>
                  ))}
                </ul>
              )}

              {testResult.message && (
                <p className="ltr rounded-field bg-muted px-3 py-2 text-micro text-ink-faint">
                  {testResult.message}
                </p>
              )}
            </div>
          )}
        </Card>
      )}

      {error && <Banner tone="danger">{error}</Banner>}

      <div className="flex items-center justify-between gap-3">
        <div>
          {!isNew && (
            <Button
              variant="danger"
              icon={Trash2}
              onClick={() =>
                setConfirm({
                  title: "حذف قاعدة القراءة نهائيًا؟",
                  consequence: (
                    <>
                      لن يعود التطبيق قادرًا على قراءة الرسائل التي كانت هذه القاعدة تتعامل معها،
                      وستظهر لأصحابها كرسائل غير مفهومة. العمليات المسجّلة سابقًا لا تُحذف.
                      <br />
                      <strong className="text-ink">
                        إذا أردت إيقافها مؤقتًا فقط، ألغِ تفعيلها بدلًا من حذفها.
                      </strong>
                    </>
                  ),
                  confirmLabel: "حذف نهائيًا",
                  tone: "danger",
                })
              }
            >
              حذف القاعدة
            </Button>
          )}
        </div>
        <div className="flex gap-2.5">
          <Link
            href="/parsers"
            className="inline-flex items-center rounded-field border border-line bg-surface px-4 py-2.5 text-sm font-medium text-ink transition-colors hover:bg-raised"
          >
            إلغاء
          </Link>
          <Button icon={Save} onClick={save} loading={saving}>
            {isNew ? "إضافة القاعدة" : "حفظ التعديلات"}
          </Button>
        </div>
      </div>

      <ConfirmDialog
        spec={confirm}
        busy={deleting}
        onCancel={() => setConfirm(null)}
        onConfirm={remove}
      />
    </div>
  );
}
