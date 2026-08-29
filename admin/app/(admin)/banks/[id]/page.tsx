"use client";

import Link from "next/link";
import { useEffect, useState } from "react";
import { useParams, useRouter } from "next/navigation";
import { ArrowLeft, Save, Trash2 } from "lucide-react";
import { Banner, Card, ErrorState, LoadingState, PageHeader, SectionHeader } from "@/components/ui/primitives";
import { Button, CheckboxField, Field, TextField } from "@/components/ui/form";
import { ConfirmDialog, type ConfirmSpec } from "@/components/ui/confirm-dialog";

type BankForm = {
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

const empty: BankForm = {
  name_ar: "",
  name_en: "",
  short_code: "",
  country_code: "EG",
  sms_senders: "",
  supported_currencies: "EGP",
  color_hex: "#021B79",
  is_active: true,
  sort_order: 0,
};

/**
 * The stored shape is a string array. The operator types a plain, comma or
 * newline separated list instead of hand-writing JSON — presentation only, the
 * payload sent to /api/admin-data is the same array it always was.
 */
function toList(value: string): string[] {
  return value
    .split(/[\n,،]/)
    .map((v) => v.trim())
    .filter(Boolean);
}
function fromList(value: unknown): string {
  if (Array.isArray(value)) return value.join("، ");
  if (typeof value === "string") {
    try {
      const parsed = JSON.parse(value);
      return Array.isArray(parsed) ? parsed.join("، ") : value;
    } catch {
      return value;
    }
  }
  return "";
}

export default function BankFormPage() {
  const { id } = useParams<{ id: string }>();
  const isNew = id === "new";
  const router = useRouter();
  const [bank, setBank] = useState<BankForm>(empty);
  const [loading, setLoading] = useState(!isNew);
  const [loadError, setLoadError] = useState("");
  const [saving, setSaving] = useState(false);
  const [deleting, setDeleting] = useState(false);
  const [error, setError] = useState("");
  const [confirm, setConfirm] = useState<ConfirmSpec | null>(null);

  useEffect(() => {
    if (isNew) return;
    fetch(`/api/admin-data?resource=banks&id=${encodeURIComponent(id)}`, { cache: "no-store" })
      .then(async (res) => {
        const body = await res.json();
        if (!res.ok) throw new Error(body.error ?? "تعذّر تحميل بيانات البنك");
        if (body.data) {
          setBank({
            ...body.data,
            sms_senders: fromList(body.data.sms_senders),
            supported_currencies: fromList(body.data.supported_currencies),
            color_hex: body.data.color_hex ?? "#021B79",
          });
        }
      })
      .catch((e) => setLoadError(e instanceof Error ? e.message : "تعذّر تحميل بيانات البنك"))
      .finally(() => setLoading(false));
  }, [id, isNew]);

  function set<K extends keyof BankForm>(field: K, value: BankForm[K]) {
    setBank((prev) => ({ ...prev, [field]: value }));
  }

  async function save() {
    if (!bank.name_ar.trim()) return setError("الاسم بالعربية مطلوب.");
    if (!bank.short_code.trim()) return setError("الرمز المختصر مطلوب.");
    setSaving(true);
    setError("");
    try {
      const payload = {
        ...bank,
        sms_senders: toList(bank.sms_senders),
        supported_currencies: toList(bank.supported_currencies),
      };
      const response = await fetch("/api/admin-data", {
        method: isNew ? "POST" : "PATCH",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ resource: "banks", id: isNew ? undefined : id, ...payload }),
      });
      const result = await response.json();
      if (!response.ok) throw new Error(result.error ?? "تعذّر حفظ البنك");
      router.push("/banks");
      router.refresh();
    } catch (e: unknown) {
      setError(e instanceof Error ? e.message : "تعذّر حفظ البنك");
    } finally {
      setSaving(false);
    }
  }

  function askDelete() {
    setConfirm({
      title: `حذف «${bank.name_ar || "هذا البنك"}» نهائيًا؟`,
      consequence: (
        <>
          سيُحذف البنك من الكتالوج، ولن يتعرّف التطبيق بعدها على رسائله. قواعد قراءة الرسائل
          المرتبطة به قد تتوقف عن العمل. العمليات المسجّلة لدى المستخدمين لا تُحذف.
          <br />
          <strong className="text-ink">
            إذا كان الهدف إيقافه مؤقتًا فقط، ألغِ تفعيله بدلًا من حذفه — البيانات تبقى كما هي.
          </strong>
        </>
      ),
      confirmLabel: "حذف نهائيًا",
      tone: "danger",
    });
  }

  async function remove() {
    setDeleting(true);
    const response = await fetch(
      `/api/admin-data?resource=banks&id=${encodeURIComponent(id)}`,
      { method: "DELETE" },
    );
    setDeleting(false);
    setConfirm(null);
    if (!response.ok) {
      const body = await response.json().catch(() => ({}));
      setError(body.error ?? "تعذّر حذف البنك");
      return;
    }
    router.push("/banks");
    router.refresh();
  }

  if (loading) return <LoadingState label="جارٍ تحميل بيانات البنك…" />;
  if (loadError) {
    return (
      <ErrorState
        title="تعذّر فتح هذا البنك"
        detail={loadError}
        action={
          <Link href="/banks" className="text-sm font-medium text-brand-700 hover:text-brand-800">
            العودة إلى قائمة البنوك
          </Link>
        }
      />
    );
  }

  return (
    <div className="max-w-3xl space-y-6">
      <div className="flex items-center gap-3">
        <Link
          href="/banks"
          aria-label="العودة إلى قائمة البنوك"
          className="rounded-field p-1.5 text-ink-faint transition-colors hover:bg-muted hover:text-ink"
        >
          <ArrowLeft size={19} className="flip-x" />
        </Link>
        <PageHeader
          eyebrow="كتالوج البنوك والرسائل"
          title={isNew ? "إضافة بنك جديد" : "تعديل بيانات البنك"}
          description="بيانات البنك تُستخدم لعرض اسمه داخل التطبيق ولمعرفة أي رسائل تخصّه."
        />
      </div>

      <Card>
        <SectionHeader title="التعريف" description="الاسم الذي يراه المستخدم، ورمز داخلي ثابت." />
        <div className="grid gap-4 md:grid-cols-2">
          <TextField
            label="اسم البنك بالعربية"
            required
            value={bank.name_ar}
            onChange={(e) => set("name_ar", e.target.value)}
            hint="هذا هو الاسم الذي يظهر للمستخدم داخل التطبيق."
          />
          <TextField
            label="اسم البنك بالإنجليزية"
            value={bank.name_en}
            onChange={(e) => set("name_en", e.target.value)}
          />
          <TextField
            label="الرمز المختصر"
            required
            mono
            value={bank.short_code}
            onChange={(e) => set("short_code", e.target.value)}
            hint="رمز ثابت لا يظهر للمستخدم. تغييره قد يؤثر على القواعد المرتبطة به."
          />
          <TextField
            label="رمز الدولة"
            mono
            value={bank.country_code}
            onChange={(e) => set("country_code", e.target.value)}
            hint="حرفان بمعيار ISO — مثل EG أو SA."
          />
        </div>
      </Card>

      <Card>
        <SectionHeader
          title="الرسائل والعملات"
          description="ما الذي يجعل التطبيق يتعرّف على رسالة قادمة من هذا البنك."
        />
        <div className="space-y-4">
          <TextField
            label="أرقام أو أسماء المُرسِل"
            mono
            value={bank.sms_senders}
            onChange={(e) => set("sms_senders", e.target.value)}
            hint="افصل بين القيم بفاصلة. مثال: NBE، 02NBE. إذا لم يكن المُرسِل مذكورًا هنا، لن يقرأ التطبيق رسالته."
          />
          <TextField
            label="العملات المدعومة"
            mono
            value={bank.supported_currencies}
            onChange={(e) => set("supported_currencies", e.target.value)}
            hint="افصل بين العملات بفاصلة. مثال: EGP، USD."
          />
        </div>
      </Card>

      <Card>
        <SectionHeader title="العرض والترتيب" description="كيف يظهر البنك في قوائم التطبيق." />
        <div className="grid gap-4 md:grid-cols-3">
          <Field label="لون البنك" hint="يُستخدم كخلفية لبطاقة البنك داخل التطبيق.">
            <div className="flex items-center gap-2">
              <input
                type="color"
                aria-label="اختيار لون البنك"
                value={/^#[0-9a-f]{6}$/i.test(bank.color_hex) ? bank.color_hex : "#021B79"}
                onChange={(e) => set("color_hex", e.target.value)}
                className="h-[42px] w-12 shrink-0 cursor-pointer rounded-field border border-line bg-surface p-1"
              />
              <input
                value={bank.color_hex}
                onChange={(e) => set("color_hex", e.target.value)}
                className="ltr w-full rounded-field border border-line bg-surface px-3 py-2.5 font-mono text-tiny text-ink focus:border-brand-500 focus:outline-none focus:ring-2 focus:ring-brand-500/25"
              />
            </div>
          </Field>
          <TextField
            label="ترتيب الظهور"
            type="number"
            value={String(bank.sort_order)}
            onChange={(e) => set("sort_order", Number(e.target.value))}
            hint="الرقم الأصغر يظهر أولًا."
          />
          <div className="flex items-end pb-2">
            <CheckboxField
              label="البنك مفعّل"
              hint="عند إلغاء التفعيل يختفي البنك من التطبيق دون حذف بياناته."
              checked={bank.is_active}
              onChange={(v) => set("is_active", v)}
            />
          </div>
        </div>
      </Card>

      {error && <Banner tone="danger">{error}</Banner>}

      <div className="flex items-center justify-between gap-3">
        <div>
          {!isNew && (
            <Button variant="danger" icon={Trash2} onClick={askDelete}>
              حذف البنك
            </Button>
          )}
        </div>
        <div className="flex gap-2.5">
          <Link
            href="/banks"
            className="inline-flex items-center rounded-field border border-line bg-surface px-4 py-2.5 text-sm font-medium text-ink transition-colors hover:bg-raised"
          >
            إلغاء
          </Link>
          <Button icon={Save} onClick={save} loading={saving}>
            {isNew ? "إضافة البنك" : "حفظ التعديلات"}
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
