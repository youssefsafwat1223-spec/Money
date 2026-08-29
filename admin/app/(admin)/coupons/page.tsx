"use client";
// Coupons Phase C3 — Coupon management. Reuses the existing Admin visual system
// (AdminShell page header, Card, DataTable, shared form fields, Qirsh brand
// tokens) and the established data flow: client component -> /api/* trusted
// routes. The browser never holds a service-role key and never talks to
// Supabase tables directly.
//
// The 2026 redesign is presentation-only: Arabic-first copy, RTL layout, and
// consequence-focused confirmation. Payload shapes, validation, sorting,
// date handling and the analytics vocabulary are unchanged.
import { useCallback, useEffect, useMemo, useState } from "react";
import {
  ChevronDown,
  ChevronUp,
  Eye,
  Image as ImageIcon,
  Pencil,
  Plus,
  Power,
  Save,
  TicketPercent,
  Trash2,
  X,
} from "lucide-react";
import { fmt, fmtDate } from "@/lib/utils";
import {
  couponStatus,
  normalizeSlug,
  normalizeTagKey,
} from "@/lib/coupon-validation.mjs";
import {
  Banner,
  Card,
  EmptyState,
  HelpNote,
  PageHeader,
  SectionHeader,
  StatusBadge,
} from "@/components/ui/primitives";
import { Button, CheckboxField, SelectField, TextField } from "@/components/ui/form";
import { ConfirmDialog, type ConfirmSpec } from "@/components/ui/confirm-dialog";
import { DataTable, NameCell, TBody, TD, TEmpty, THead, TR } from "@/components/ui/table";
import { FilterBar, FilterSelect } from "@/components/ui/filter-bar";
import { Pagination, usePagination } from "@/components/ui/pagination";
import { couponStatusLabel, couponStatusTone, redemptionLabel } from "@/lib/labels";

type TagRow = { id: string; key: string; label_ar: string; label_en: string | null; sort_order: number };
type CategoryRow = { key: string; label_ar: string; label_en: string | null; sort_order: number; is_active: boolean };
type Coupon = {
  id: string;
  slug: string;
  partner_name: string;
  title_ar: string;
  title_en: string | null;
  description_ar: string;
  description_en: string | null;
  terms_ar: string | null;
  redemption_type: "code" | "link";
  code: string | null;
  partner_url: string | null;
  display_category_key: string;
  spend_hint_category_keys: string[];
  country_codes: string[];
  accent_hex: string | null;
  image_path: string | null;
  featured: boolean;
  priority: number;
  valid_from: string;
  valid_until: string | null;
  is_active: boolean;
  created_at: string;
  updated_at: string;
  coupon_tag_links: { tag_id: string }[];
};
type Totals = Record<string, Record<string, number>>;

const STATUSES = ["all", "live", "scheduled", "expired", "disabled"] as const;
const SORTS = ["priority", "newest", "updated", "validity", "title"] as const;

const STATUS_FILTER_LABEL: Record<string, string> = {
  all: "كل الحالات",
  live: "معروض الآن",
  scheduled: "مجدول",
  expired: "منتهي",
  disabled: "متوقف",
};
const SORT_LABEL: Record<string, string> = {
  priority: "الأولوية",
  newest: "الأحدث إضافة",
  updated: "آخر تعديل",
  validity: "فترة العرض",
  title: "العنوان",
};

/** Financial category keys offered as contextual ranking hints (static list). */
const SPEND_HINTS = [
  "restaurants", "groceries", "subscriptions", "shopping", "transport",
  "health", "travel", "bills", "entertainment", "education",
];
/** Arabic display for the hint keys above — the stored key is unchanged. */
const SPEND_HINT_LABEL: Record<string, string> = {
  restaurants: "مطاعم",
  groceries: "بقالة",
  subscriptions: "اشتراكات",
  shopping: "تسوّق",
  transport: "مواصلات",
  health: "صحة",
  travel: "سفر",
  bills: "فواتير",
  entertainment: "ترفيه",
  education: "تعليم",
};

const emptyForm = {
  id: "",
  slug: "",
  partner_name: "",
  title_ar: "",
  title_en: "",
  description_ar: "",
  description_en: "",
  terms_ar: "",
  redemption_type: "code" as "code" | "link",
  code: "",
  partner_url: "",
  display_category_key: "",
  spend_hint_category_keys: [] as string[],
  is_global: true,
  country_codes: "" as string,
  accent_hex: "#2563EB",
  featured: false,
  priority: "0",
  valid_from: "",
  valid_until: "",
  is_active: true,
  tag_ids: [] as string[],
};

/** Convert a `datetime-local` value (browser local) to an absolute UTC ISO. */
function localToIso(value: string): string {
  if (!value) return "";
  return new Date(value).toISOString();
}
/** Convert a stored UTC ISO back into a `datetime-local` value. */
function isoToLocal(value: string | null): string {
  if (!value) return "";
  const d = new Date(value);
  const pad = (n: number) => String(n).padStart(2, "0");
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}T${pad(d.getHours())}:${pad(d.getMinutes())}`;
}

export default function CouponsPage() {
  const [coupons, setCoupons] = useState<Coupon[]>([]);
  const [tags, setTags] = useState<TagRow[]>([]);
  const [categories, setCategories] = useState<CategoryRow[]>([]);
  const [totals, setTotals] = useState<Totals>({});
  const [form, setForm] = useState(emptyForm);
  const [formOpen, setFormOpen] = useState(false);
  const [search, setSearch] = useState("");
  const [status, setStatus] = useState<(typeof STATUSES)[number]>("all");
  const [typeFilter, setTypeFilter] = useState("all");
  const [categoryFilter, setCategoryFilter] = useState("all");
  const [tagFilter, setTagFilter] = useState("all");
  const [featuredOnly, setFeaturedOnly] = useState(false);
  const [sort, setSort] = useState<(typeof SORTS)[number]>("priority");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [previewId, setPreviewId] = useState<string | null>(null);
  const [confirm, setConfirm] = useState<(ConfirmSpec & { run: () => Promise<void> }) | null>(null);

  const load = useCallback(async () => {
    setError(null);
    const [cRes, tRes, catRes, aRes] = await Promise.all([
      fetch(`/api/coupons?sort=${sort}`),
      fetch("/api/coupon-tags"),
      fetch("/api/coupon-categories"),
      fetch("/api/coupon-analytics?days=30"),
    ]);
    const [cJson, tJson, catJson, aJson] = await Promise.all([
      cRes.json(), tRes.json(), catRes.json(), aRes.json(),
    ]);
    if (!cRes.ok) return setError(cJson.message ?? "تعذّر تحميل العروض");
    setCoupons((cJson.coupons ?? []) as Coupon[]);
    setTags((tJson.tags ?? []) as TagRow[]);
    setCategories((catJson.categories ?? []) as CategoryRow[]);
    setTotals((aJson.totals ?? {}) as Totals);
  }, [sort]);

  useEffect(() => { void load(); }, [load]);

  const categoryLabel = useCallback(
    (key: string) => categories.find((c) => c.key === key)?.label_ar ?? key,
    [categories],
  );

  const visible = useMemo(() => {
    const q = search.trim().toLowerCase();
    return coupons.filter((c) => {
      if (status !== "all" && couponStatus(c) !== status) return false;
      if (typeFilter !== "all" && c.redemption_type !== typeFilter) return false;
      if (categoryFilter !== "all" && c.display_category_key !== categoryFilter) return false;
      if (featuredOnly && !c.featured) return false;
      if (tagFilter !== "all" && !c.coupon_tag_links?.some((l) => l.tag_id === tagFilter)) return false;
      if (!q) return true;
      return (
        c.title_ar.toLowerCase().includes(q) ||
        (c.title_en ?? "").toLowerCase().includes(q) ||
        c.partner_name.toLowerCase().includes(q) ||
        c.slug.toLowerCase().includes(q)
      );
    });
  }, [coupons, search, status, typeFilter, categoryFilter, tagFilter, featuredOnly]);

  const paged = usePagination(visible, 20);

  function readError(json: { message?: string; fields?: { field: string; message: string }[] }) {
    if (json.fields?.length) {
      return json.fields.map((f) => `${f.field}: ${f.message}`).join(" · ");
    }
    return json.message ?? "تعذّر تنفيذ الطلب";
  }

  function payloadFrom(f: typeof form) {
    return {
      ...(f.id ? { id: f.id } : {}),
      slug: f.slug,
      partner_name: f.partner_name,
      title_ar: f.title_ar,
      title_en: f.title_en || null,
      description_ar: f.description_ar,
      description_en: f.description_en || null,
      terms_ar: f.terms_ar || null,
      redemption_type: f.redemption_type,
      code: f.redemption_type === "code" ? f.code : "",
      partner_url: f.partner_url,
      display_category_key: f.display_category_key,
      spend_hint_category_keys: f.spend_hint_category_keys,
      is_global: f.is_global,
      country_codes: f.is_global
        ? []
        : f.country_codes.split(",").map((c) => c.trim().toUpperCase()).filter(Boolean),
      accent_hex: f.accent_hex || null,
      featured: f.featured,
      priority: Number(f.priority || 0),
      valid_from: localToIso(f.valid_from) || new Date().toISOString(),
      valid_until: f.valid_until ? localToIso(f.valid_until) : null,
      is_active: f.is_active,
      tag_ids: f.tag_ids,
    };
  }

  async function save() {
    setBusy(true);
    setError(null);
    setNotice(null);
    const editing = Boolean(form.id);
    const res = await fetch("/api/coupons", {
      method: editing ? "PATCH" : "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payloadFrom(form)),
    });
    const json = await res.json();
    setBusy(false);
    if (!res.ok) return setError(readError(json));
    setNotice(editing ? "تم حفظ تعديلات العرض." : "تم إنشاء العرض.");
    setForm(emptyForm);
    setFormOpen(false);
    await load();
  }

  function edit(c: Coupon) {
    setForm({
      id: c.id,
      slug: c.slug,
      partner_name: c.partner_name,
      title_ar: c.title_ar,
      title_en: c.title_en ?? "",
      description_ar: c.description_ar,
      description_en: c.description_en ?? "",
      terms_ar: c.terms_ar ?? "",
      redemption_type: c.redemption_type,
      code: c.code ?? "",
      partner_url: c.partner_url ?? "",
      display_category_key: c.display_category_key,
      spend_hint_category_keys: c.spend_hint_category_keys ?? [],
      is_global: (c.country_codes ?? []).length === 0,
      country_codes: (c.country_codes ?? []).join(", "),
      accent_hex: c.accent_hex ?? "#2563EB",
      featured: c.featured,
      priority: String(c.priority),
      valid_from: isoToLocal(c.valid_from),
      valid_until: isoToLocal(c.valid_until),
      is_active: c.is_active,
      tag_ids: (c.coupon_tag_links ?? []).map((l) => l.tag_id),
    });
    setFormOpen(true);
    window.scrollTo({ top: 0, behavior: "smooth" });
  }

  async function setActive(c: Coupon, active: boolean) {
    setError(null);
    const res = await fetch("/api/coupons", {
      method: "PATCH",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        ...payloadFrom({
          ...emptyForm,
          id: c.id,
          slug: c.slug,
          partner_name: c.partner_name,
          title_ar: c.title_ar,
          title_en: c.title_en ?? "",
          description_ar: c.description_ar,
          description_en: c.description_en ?? "",
          terms_ar: c.terms_ar ?? "",
          redemption_type: c.redemption_type,
          code: c.code ?? "",
          partner_url: c.partner_url ?? "",
          display_category_key: c.display_category_key,
          spend_hint_category_keys: c.spend_hint_category_keys ?? [],
          is_global: (c.country_codes ?? []).length === 0,
          country_codes: (c.country_codes ?? []).join(", "),
          accent_hex: c.accent_hex ?? "#2563EB",
          featured: c.featured,
          priority: String(c.priority),
          valid_from: isoToLocal(c.valid_from),
          valid_until: isoToLocal(c.valid_until),
          tag_ids: (c.coupon_tag_links ?? []).map((l) => l.tag_id),
        }),
        is_active: active,
      }),
    });
    const json = await res.json();
    if (!res.ok) return setError(readError(json));
    setNotice(active ? "تم تفعيل العرض." : "تم إيقاف العرض — المحتوى محفوظ كما هو.");
    await load();
  }

  // PERMANENT delete removes the offer, its tag links, its analytics and its
  // image. Prefer "Disable" for routine retirement — hence the typed-slug gate.
  async function permanentlyDelete(c: Coupon) {
    const res = await fetch(
      `/api/coupons?id=${encodeURIComponent(c.id)}&confirm=permanent`,
      { method: "DELETE" },
    );
    const json = await res.json();
    if (!res.ok) return setError(readError(json));
    setNotice("تم حذف العرض نهائيًا.");
    await load();
  }

  async function uploadImage(c: Coupon, file: File) {
    setError(null);
    const body = new FormData();
    body.append("coupon_id", c.id);
    body.append("file", file);
    const res = await fetch("/api/coupons/image", { method: "POST", body });
    const json = await res.json();
    if (!res.ok) return setError(readError(json));
    setNotice("تم تحديث صورة العرض.");
    await load();
  }

  async function removeImage(c: Coupon) {
    const res = await fetch(`/api/coupons/image?coupon_id=${encodeURIComponent(c.id)}`, {
      method: "DELETE",
    });
    const json = await res.json();
    if (!res.ok) return setError(readError(json));
    setNotice("تمت إزالة الصورة — يعود العرض إلى لونه الأساسي.");
    await load();
  }

  async function runConfirmed() {
    if (!confirm) return;
    setBusy(true);
    await confirm.run();
    setBusy(false);
    setConfirm(null);
  }

  const preview = coupons.find((c) => c.id === previewId) ?? null;
  const liveCount = coupons.filter((c) => couponStatus(c) === "live").length;
  const filtering =
    search.trim() !== "" ||
    status !== "all" ||
    typeFilter !== "all" ||
    categoryFilter !== "all" ||
    tagFilter !== "all" ||
    featuredOnly;

  return (
    <div className="space-y-6">
      <PageHeader
        eyebrow="النمو والمكافآت"
        title="العروض والكوبونات"
        description={`${fmt(coupons.length)} عرض، منها ${fmt(liveCount)} معروض الآن. يمكن تجهيز المحتوى كاملًا قبل تشغيل الميزة على التطبيق — العروض لا تظهر للمستخدمين إلا بعد تفعيلها.`}
        action={
          !formOpen && (
            <Button
              icon={Plus}
              onClick={() => {
                setForm(emptyForm);
                setFormOpen(true);
              }}
            >
              عرض جديد
            </Button>
          )
        }
      />

      {error && <Banner tone="danger" onDismiss={() => setError(null)}>{error}</Banner>}
      {notice && <Banner tone="success" onDismiss={() => setNotice(null)}>{notice}</Banner>}

      {/* ---------------------------------------------------------------- form */}
      {formOpen && (
        <Card>
          <SectionHeader
            title={form.id ? "تعديل العرض" : "عرض جديد"}
            description="اكتب العرض كما سيراه المستخدم داخل التطبيق، وحدّد طريقة الاستفادة منه وفترة عرضه."
            action={
              <Button
                variant="ghost"
                size="sm"
                icon={X}
                onClick={() => {
                  setForm(emptyForm);
                  setFormOpen(false);
                }}
              >
                إغلاق
              </Button>
            }
          />

          <div className="space-y-6">
            <FormSection title="الشريك والمعرّف">
              <TextField
                label="اسم الشريك أو المتجر"
                required
                value={form.partner_name}
                onChange={(e) =>
                  setForm({
                    ...form,
                    partner_name: e.target.value,
                    slug: form.id || form.slug ? form.slug : normalizeSlug(e.target.value),
                  })
                }
                hint="يظهر فوق عنوان العرض داخل التطبيق."
              />
              <TextField
                label="المعرّف الثابت"
                required
                mono
                value={form.slug}
                onChange={(e) => setForm({ ...form, slug: e.target.value })}
                hint="حروف إنجليزية صغيرة وأرقام و - أو _ فقط. يُستخدم داخليًا ولا يظهر للمستخدم."
              />
            </FormSection>

            <FormSection title="المحتوى">
              <TextField
                label="عنوان العرض بالعربية"
                required
                value={form.title_ar}
                onChange={(e) => setForm({ ...form, title_ar: e.target.value })}
              />
              <TextField
                label="عنوان العرض بالإنجليزية"
                dir="ltr"
                value={form.title_en}
                onChange={(e) => setForm({ ...form, title_en: e.target.value })}
              />
              <TextField
                label="وصف العرض بالعربية"
                required
                value={form.description_ar}
                onChange={(e) => setForm({ ...form, description_ar: e.target.value })}
              />
              <TextField
                label="وصف العرض بالإنجليزية"
                dir="ltr"
                value={form.description_en}
                onChange={(e) => setForm({ ...form, description_en: e.target.value })}
              />
              <TextField
                label="شروط الاستفادة بالعربية"
                value={form.terms_ar}
                onChange={(e) => setForm({ ...form, terms_ar: e.target.value })}
                hint="اختياري — أي قيود على العرض مثل حد أدنى للشراء."
                className="md:col-span-2"
              />
            </FormSection>

            <FormSection title="طريقة الاستفادة">
              <SelectField
                label="نوع العرض"
                value={form.redemption_type}
                onChange={(e) =>
                  setForm({
                    ...form,
                    redemption_type: e.target.value as "code" | "link",
                    code: e.target.value === "link" ? "" : form.code,
                  })
                }
                options={[
                  { value: "code", label: "كود خصم ينسخه المستخدم" },
                  { value: "link", label: "رابط مباشر يفتحه المستخدم" },
                ]}
              />
              {form.redemption_type === "code" ? (
                <TextField
                  label="كود الخصم"
                  required
                  mono
                  value={form.code}
                  onChange={(e) => setForm({ ...form, code: e.target.value })}
                  hint="هذا هو الكود الذي ينسخه المستخدم ويستخدمه لدى الشريك."
                />
              ) : (
                <p className="self-end pb-3 text-sm text-ink-soft">
                  العرض من نوع «رابط مباشر» لا يحمل كودًا — الوجهة نفسها هي العرض.
                </p>
              )}
              <TextField
                label={
                  form.redemption_type === "link"
                    ? "رابط الوجهة (https)"
                    : "رابط الشريك (اختياري، https)"
                }
                required={form.redemption_type === "link"}
                mono
                value={form.partner_url}
                onChange={(e) => setForm({ ...form, partner_url: e.target.value })}
              />
            </FormSection>

            <FormSection title="التصنيف">
              <SelectField
                label="فئة العرض"
                required
                value={form.display_category_key}
                placeholder="اختر الفئة…"
                onChange={(e) => setForm({ ...form, display_category_key: e.target.value })}
                options={categories
                  .filter((c) => c.is_active)
                  .map((c) => ({ value: c.key, label: c.label_ar }))}
                hint="الفئة التي يُعرض تحتها العرض داخل التطبيق."
              />
              <div>
                <label className="mb-1.5 block text-tiny font-medium text-ink">وسوم العرض</label>
                <div className="flex flex-wrap gap-2 rounded-field border border-line p-2.5">
                  {tags.map((t) => {
                    const on = form.tag_ids.includes(t.id);
                    return (
                      <button
                        key={t.id}
                        type="button"
                        onClick={() =>
                          setForm({
                            ...form,
                            tag_ids: on
                              ? form.tag_ids.filter((x) => x !== t.id)
                              : [...form.tag_ids, t.id],
                          })
                        }
                        className={
                          on
                            ? "rounded-full bg-brand-700 px-3 py-1 text-micro font-medium text-white"
                            : "rounded-full bg-muted px-3 py-1 text-micro text-ink-soft hover:bg-brand-100"
                        }
                      >
                        #{t.label_ar}
                      </button>
                    );
                  })}
                  {tags.length === 0 && (
                    <span className="text-micro text-ink-faint">
                      لا توجد وسوم بعد — أضف وسمًا من القسم في أسفل الصفحة.
                    </span>
                  )}
                </div>
              </div>

              <div className="md:col-span-2">
                <label className="mb-1.5 block text-tiny font-medium text-ink">
                  تلميحات ترتيب حسب الإنفاق
                  {/* Contextual ranking hints — ranking metadata only; this does
                      NOT categorize anyone's transactions. */}
                  <span className="ms-2 font-normal text-micro text-ink-faint">
                    اختياري. تُستخدم فقط لترتيب العروض داخل جهاز المستخدم، ولا تُصنَّف بها عمليات أي
                    مستخدم إطلاقًا.
                  </span>
                </label>
                <div className="flex flex-wrap gap-2">
                  {SPEND_HINTS.map((h) => {
                    const on = form.spend_hint_category_keys.includes(h);
                    return (
                      <button
                        key={h}
                        type="button"
                        onClick={() =>
                          setForm({
                            ...form,
                            spend_hint_category_keys: on
                              ? form.spend_hint_category_keys.filter((x) => x !== h)
                              : [...form.spend_hint_category_keys, h],
                          })
                        }
                        className={
                          on
                            ? "rounded-full bg-ink px-3 py-1 text-micro text-white"
                            : "rounded-full bg-muted px-3 py-1 text-micro text-ink-soft hover:bg-brand-100"
                        }
                      >
                        {SPEND_HINT_LABEL[h] ?? h}
                      </button>
                    );
                  })}
                </div>
                {form.spend_hint_category_keys.filter((h) => !SPEND_HINTS.includes(h)).length > 0 && (
                  <p className="mt-2 text-micro text-ink-faint">
                    محفوظ أيضًا من تعديلات سابقة:{" "}
                    <span className="ltr font-mono">
                      {form.spend_hint_category_keys.filter((h) => !SPEND_HINTS.includes(h)).join(", ")}
                    </span>
                  </p>
                )}
              </div>
            </FormSection>

            <FormSection title="فترة العرض ونطاقه">
              <CheckboxField
                label="متاح في كل الدول"
                hint="عند الإلغاء حدّد الدول المسموح لها بالأسفل."
                checked={form.is_global}
                onChange={(v) => setForm({ ...form, is_global: v })}
              />
              <TextField
                label="الدول المسموح لها"
                mono
                disabled={form.is_global}
                value={form.is_global ? "" : form.country_codes}
                onChange={(e) => setForm({ ...form, country_codes: e.target.value })}
                hint={
                  form.is_global
                    ? "غير مطلوب ما دام العرض متاحًا في كل الدول."
                    : "رموز الدول بمعيار ISO مفصولة بفاصلة — مثل SA, AE, EG."
                }
              />
              <TextField
                label="يبدأ العرض في"
                type="datetime-local"
                value={form.valid_from}
                onChange={(e) => setForm({ ...form, valid_from: e.target.value })}
              />
              <TextField
                label="ينتهي العرض في"
                type="datetime-local"
                value={form.valid_until}
                onChange={(e) => setForm({ ...form, valid_until: e.target.value })}
                hint="اتركه فارغًا ليبقى العرض بلا تاريخ انتهاء."
              />
              <p className="md:col-span-2 text-micro text-ink-faint">
                {/* Effective window — entered in local time, stored as UTC. */}
                تُدخل المواعيد بتوقيت جهازك وتُحفظ بتوقيت UTC. فترة العرض الفعلية:{" "}
                <span className="ltr font-mono">
                  {form.valid_from ? new Date(localToIso(form.valid_from)).toUTCString() : "الآن"} →{" "}
                  {form.valid_until ? new Date(localToIso(form.valid_until)).toUTCString() : "بلا نهاية"}
                </span>
              </p>
            </FormSection>

            <FormSection title="الشكل والأولوية">
              <div>
                <label className="mb-1.5 block text-tiny font-medium text-ink">اللون الأساسي</label>
                <div className="flex items-center gap-2">
                  <input
                    type="color"
                    aria-label="اختيار لون العرض"
                    value={/^#[0-9a-f]{6}$/i.test(form.accent_hex) ? form.accent_hex : "#2563EB"}
                    onChange={(e) => setForm({ ...form, accent_hex: e.target.value })}
                    className="h-[42px] w-12 shrink-0 cursor-pointer rounded-field border border-line bg-surface p-1"
                  />
                  <input
                    value={form.accent_hex}
                    onChange={(e) => setForm({ ...form, accent_hex: e.target.value })}
                    className="ltr w-full rounded-field border border-line bg-surface px-3 py-2.5 font-mono text-tiny text-ink focus:border-brand-500 focus:outline-none focus:ring-2 focus:ring-brand-500/25"
                  />
                </div>
                <p className="mt-1.5 text-micro text-ink-faint">يُستخدم إذا لم تُرفَع صورة للعرض.</p>
              </div>
              <TextField
                label="الأولوية"
                type="number"
                value={form.priority}
                onChange={(e) => setForm({ ...form, priority: e.target.value })}
                hint="من -1000 إلى 1000. الرقم الأعلى يظهر أولًا."
              />
              <div className="flex flex-wrap items-end gap-8 pb-2 md:col-span-2">
                <CheckboxField
                  label="عرض مميّز"
                  hint="يظهر في المقدمة داخل قائمة العروض."
                  checked={form.featured}
                  onChange={(v) => setForm({ ...form, featured: v })}
                />
                <CheckboxField
                  label="العرض مفعّل"
                  hint="أوقفه لإخفائه فورًا مع الاحتفاظ بمحتواه."
                  checked={form.is_active}
                  onChange={(v) => setForm({ ...form, is_active: v })}
                />
              </div>
            </FormSection>

            <HelpNote>
              تُرفع صورة العرض من صف العرض في الجدول بعد الحفظ. المقاس المفضّل 16:9 بنحو 1200×675
              بكسل، وبحد أقصى 512 كيلوبايت، بصيغة WebP أو PNG أو JPEG.
            </HelpNote>

            <div className="flex justify-end gap-2.5 border-t border-divider pt-4">
              <Button
                variant="secondary"
                onClick={() => {
                  setForm(emptyForm);
                  setFormOpen(false);
                }}
              >
                إلغاء
              </Button>
              <Button icon={Save} onClick={save} loading={busy}>
                {form.id ? "حفظ التعديلات" : "إنشاء العرض"}
              </Button>
            </div>
          </div>
        </Card>
      )}

      {/* ------------------------------------------------------------- filters */}
      <div className="space-y-3">
        <FilterBar
          search={search}
          onSearch={setSearch}
          placeholder="ابحث بعنوان العرض أو اسم الشريك أو المعرّف…"
          resultLabel={`${fmt(visible.length)} من ${fmt(coupons.length)}`}
        >
          <FilterSelect
            label="الحالة"
            value={status}
            onChange={(v) => setStatus(v as typeof status)}
            options={STATUSES.map((s) => ({ value: s, label: STATUS_FILTER_LABEL[s] }))}
          />
          <FilterSelect
            label="النوع"
            value={typeFilter}
            onChange={setTypeFilter}
            options={[
              { value: "all", label: "كل الأنواع" },
              { value: "code", label: "كود خصم" },
              { value: "link", label: "رابط مباشر" },
            ]}
          />
          <FilterSelect
            label="الفئة"
            value={categoryFilter}
            onChange={setCategoryFilter}
            options={[
              { value: "all", label: "كل الفئات" },
              ...categories.map((c) => ({ value: c.key, label: c.label_ar })),
            ]}
          />
          <FilterSelect
            label="الوسم"
            value={tagFilter}
            onChange={setTagFilter}
            options={[
              { value: "all", label: "كل الوسوم" },
              ...tags.map((t) => ({ value: t.id, label: `#${t.label_ar}` })),
            ]}
          />
          <FilterSelect
            label="الترتيب"
            value={sort}
            onChange={(v) => setSort(v as typeof sort)}
            options={SORTS.map((s) => ({ value: s, label: `ترتيب حسب ${SORT_LABEL[s]}` }))}
          />
        </FilterBar>
        <CheckboxField
          label="العروض المميّزة فقط"
          checked={featuredOnly}
          onChange={setFeaturedOnly}
        />
      </div>

      {/* ---------------------------------------------------------------- list */}
      <DataTable
        footer={
          <Pagination
            page={paged.page}
            pageCount={paged.pageCount}
            total={paged.total}
            pageSize={paged.pageSize}
            onPage={paged.setPage}
          />
        }
      >
        <THead
          columns={[
            "العرض",
            "الشريك",
            "الفئة",
            "النوع",
            "الحالة",
            "فترة العرض",
            "الأولوية",
            "التفاعل",
            { label: "إجراءات", align: "end" },
          ]}
        />
        <TBody>
          {paged.slice.map((c) => {
            const t = totals[c.id] ?? {};
            const derived = couponStatus(c);
            return (
              <TR key={c.id}>
                <TD>
                  <div className="flex items-center gap-3">
                    <div
                      className="h-10 w-16 shrink-0 rounded-md border border-hairline bg-muted"
                      style={c.accent_hex ? { backgroundColor: c.accent_hex } : undefined}
                      title={c.image_path ? "للعرض صورة مرفوعة" : "بلا صورة — يُستخدم اللون الأساسي"}
                    />
                    <div className="min-w-0">
                      <div className="truncate font-medium text-ink">{c.title_ar}</div>
                      <div className="flex items-center gap-1.5">
                        <span className="ltr truncate font-mono text-micro text-ink-faint">{c.slug}</span>
                        {c.featured && <StatusBadge label="مميّز" tone="brand" dot={false} />}
                      </div>
                    </div>
                  </div>
                </TD>
                <TD className="text-ink-soft">{c.partner_name}</TD>
                <TD className="text-ink-soft">{categoryLabel(c.display_category_key)}</TD>
                <TD className="text-ink-soft">{redemptionLabel(c.redemption_type)}</TD>
                <TD>
                  <StatusBadge label={couponStatusLabel(derived)} tone={couponStatusTone(derived)} />
                </TD>
                <TD className="whitespace-nowrap text-micro text-ink-faint">
                  {fmtDate(c.valid_from)}
                  <br />
                  {c.valid_until ? `حتى ${fmtDate(c.valid_until)}` : "بلا نهاية"}
                </TD>
                <TD className="tnum text-ink-soft">{fmt(c.priority)}</TD>
                <TD>
                  <div className="tnum grid grid-cols-2 gap-x-3 gap-y-0.5 text-micro text-ink-soft">
                    <span>ظهور: {fmt(t.impression ?? 0)}</span>
                    <span>فتح: {fmt(t.detail_view ?? 0)}</span>
                    <span>نسخ الكود: {fmt(t.code_copy ?? 0)}</span>
                    <span>ضغط الزر: {fmt(t.cta_click ?? 0)}</span>
                  </div>
                </TD>
                <TD align="end">
                  <div className="flex flex-wrap justify-end gap-1.5">
                    <IconAction label="تعديل" icon={Pencil} onClick={() => edit(c)} />
                    <IconAction label="معاينة" icon={Eye} onClick={() => setPreviewId(c.id)} />
                    <IconAction
                      label={c.is_active ? "إيقاف" : "تفعيل"}
                      icon={Power}
                      onClick={() =>
                        setConfirm({
                          title: c.is_active ? "إيقاف هذا العرض؟" : "تفعيل هذا العرض؟",
                          confirmLabel: c.is_active ? "إيقاف العرض" : "تفعيل العرض",
                          tone: c.is_active ? "warning" : "brand",
                          consequence: c.is_active ? (
                            <>
                              سيختفي «{c.title_ar}» من التطبيق فورًا.{" "}
                              <strong className="text-ink">لن يُحذف أي شيء</strong> — المحتوى والصورة
                              وأرقام التفاعل تبقى كما هي، ويمكنك تفعيله مرة أخرى في أي وقت.
                            </>
                          ) : (
                            <>
                              سيظهر «{c.title_ar}» للمستخدمين ضمن فترة العرض المحدّدة له.
                            </>
                          ),
                          run: () => setActive(c, !c.is_active),
                        })
                      }
                    />
                    <label
                      className="cursor-pointer rounded-field border border-line px-2 py-1.5 text-micro text-ink-soft transition-colors hover:border-brand-300 hover:bg-brand-50 hover:text-brand-900"
                      title="رفع صورة للعرض"
                    >
                      <ImageIcon size={13} />
                      <input
                        type="file"
                        accept="image/webp,image/png,image/jpeg"
                        className="hidden"
                        onChange={(e) => e.target.files?.[0] && uploadImage(c, e.target.files[0])}
                      />
                    </label>
                    {c.image_path && (
                      <IconAction label="إزالة الصورة" icon={X} onClick={() => removeImage(c)} />
                    )}
                    <IconAction
                      label="حذف نهائي"
                      icon={Trash2}
                      danger
                      onClick={() =>
                        setConfirm({
                          title: "حذف هذا العرض نهائيًا؟",
                          confirmLabel: "حذف نهائيًا",
                          tone: "danger",
                          typeToConfirm: c.slug,
                          typeToConfirmLabel: "اكتب معرّف العرض للتأكيد:",
                          consequence: (
                            <>
                              الحذف النهائي يزيل العرض ووسومه وأرقام تفاعله وصورته، ولا يمكن التراجع
                              عنه.
                              <br />
                              <strong className="text-ink">
                                للإخفاء المعتاد استخدم «إيقاف» بدلًا من الحذف — يبقى كل شيء محفوظًا.
                              </strong>
                            </>
                          ),
                          run: () => permanentlyDelete(c),
                        })
                      }
                    />
                  </div>
                </TD>
              </TR>
            );
          })}

          {visible.length === 0 && (
            <TEmpty colSpan={9}>
              {filtering ? (
                <EmptyState
                  title="لا توجد عروض مطابقة"
                  description="جرّب كلمة بحث أخرى أو أعِد ضبط عوامل التصفية."
                />
              ) : (
                <EmptyState
                  icon={TicketPercent}
                  title="لا توجد عروض بعد"
                  description="أنشئ أول عرض من الشركاء ليظهر داخل التطبيق."
                />
              )}
            </TEmpty>
          )}
        </TBody>
      </DataTable>

      <HelpNote>
        {/* directional product analytics — not billing-grade accounting. */}
        أرقام الظهور والفتح ونسخ الكود وضغط الزر هي <strong>مؤشرات استرشادية على التفاعل</strong>{" "}
        داخل التطبيق فقط، وليست أرقامًا محاسبية ولا تصلح للمحاسبة مع الشريك.
      </HelpNote>

      {preview && (
        <PreviewCard coupon={preview} categories={categories} tags={tags} onClose={() => setPreviewId(null)} />
      )}

      <CategoryManager categories={categories} onChanged={load} onError={setError} onNotice={setNotice} />
      <TagManager tags={tags} onChanged={load} onError={setError} onNotice={setNotice} />

      <ConfirmDialog
        spec={confirm}
        busy={busy}
        onCancel={() => setConfirm(null)}
        onConfirm={runConfirmed}
      />
    </div>
  );
}

/* ------------------------------------------------------------------- layout */

function FormSection({ title, children }: { title: string; children: React.ReactNode }) {
  return (
    <div>
      <h3 className="mb-3 text-tiny font-semibold tracking-wide text-ink-faint">{title}</h3>
      <div className="grid gap-4 md:grid-cols-2">{children}</div>
    </div>
  );
}

function IconAction({
  label,
  icon: Icon,
  onClick,
  danger,
}: {
  label: string;
  icon: typeof Pencil;
  onClick: () => void;
  danger?: boolean;
}) {
  return (
    <button
      type="button"
      onClick={onClick}
      title={label}
      aria-label={label}
      className={`rounded-field border px-2 py-1.5 text-micro transition-colors ${
        danger
          ? "border-danger/25 text-danger hover:bg-danger-bg"
          : "border-line text-ink-soft hover:border-brand-300 hover:bg-brand-50 hover:text-brand-900"
      }`}
    >
      <Icon size={13} />
    </button>
  );
}

/* ------------------------------------------------------------------ managers */

function CategoryManager({
  categories, onChanged, onError, onNotice,
}: {
  categories: CategoryRow[];
  onChanged: () => Promise<void>;
  onError: (m: string) => void;
  onNotice: (m: string) => void;
}) {
  const [open, setOpen] = useState(false);
  const [key, setKey] = useState("");
  const [labelAr, setLabelAr] = useState("");
  const [labelEn, setLabelEn] = useState("");

  async function send(method: "POST" | "PATCH", body: Record<string, unknown>) {
    const res = await fetch("/api/coupon-categories", {
      method,
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
    });
    const json = await res.json();
    if (!res.ok) return onError(json.message ?? "تعذّر تنفيذ الطلب على الفئات");
    onNotice("تم تحديث فئات العروض.");
    await onChanged();
  }

  return (
    <Card>
      <SectionHeader
        title="فئات العروض"
        description="تصنيف خاص بالعروض فقط، منفصل تمامًا عن فئات مصروفات المستخدمين."
        action={
          <Button
            variant="ghost"
            size="sm"
            icon={open ? ChevronUp : ChevronDown}
            onClick={() => setOpen(!open)}
          >
            {open ? "إخفاء" : `عرض (${fmt(categories.length)})`}
          </Button>
        }
      />

      {open && (
        <>
          <div className="grid items-end gap-3 md:grid-cols-4">
            <TextField
              label="المفتاح الثابت"
              mono
              value={key}
              onChange={(e) => setKey(e.target.value)}
              hint="حروف إنجليزية صغيرة وأرقام و _ فقط."
            />
            <TextField label="الاسم بالعربية" value={labelAr} onChange={(e) => setLabelAr(e.target.value)} />
            <TextField
              label="الاسم بالإنجليزية"
              dir="ltr"
              value={labelEn}
              onChange={(e) => setLabelEn(e.target.value)}
            />
            <Button
              icon={Plus}
              onClick={() => send("POST", { key, label_ar: labelAr, label_en: labelEn })}
            >
              إضافة فئة
            </Button>
          </div>

          <ul className="mt-4 divide-y divide-divider text-sm">
            {categories.map((c) => (
              <li key={c.key} className="flex flex-wrap items-center gap-3 py-2.5">
                <span className="w-40 font-medium text-ink">{c.label_ar}</span>
                <span className="ltr font-mono text-micro text-ink-faint">{c.key}</span>
                <span className="text-ink-faint">{c.label_en ?? "—"}</span>
                <span className="tnum text-micro text-ink-faint">الترتيب {fmt(c.sort_order)}</span>
                <StatusBadge
                  label={c.is_active ? "مفعّلة" : "متوقفة"}
                  tone={c.is_active ? "success" : "neutral"}
                />
                <div className="ms-auto flex gap-1.5">
                  <IconAction
                    label="تقديم في الترتيب"
                    icon={ChevronUp}
                    onClick={() => send("PATCH", { ...c, sort_order: c.sort_order - 1 })}
                  />
                  <IconAction
                    label="تأخير في الترتيب"
                    icon={ChevronDown}
                    onClick={() => send("PATCH", { ...c, sort_order: c.sort_order + 1 })}
                  />
                  <button
                    type="button"
                    onClick={() => send("PATCH", { ...c, is_active: !c.is_active })}
                    className="rounded-field border border-line px-2.5 py-1.5 text-micro text-ink-soft transition-colors hover:border-brand-300 hover:bg-brand-50 hover:text-brand-900"
                  >
                    {c.is_active ? "إيقاف" : "تفعيل"}
                  </button>
                </div>
              </li>
            ))}
            {categories.length === 0 && (
              <li className="py-3 text-tiny text-ink-faint">لا توجد فئات عروض بعد.</li>
            )}
          </ul>
        </>
      )}
    </Card>
  );
}

function TagManager({
  tags, onChanged, onError, onNotice,
}: {
  tags: TagRow[];
  onChanged: () => Promise<void>;
  onError: (m: string) => void;
  onNotice: (m: string) => void;
}) {
  const [open, setOpen] = useState(false);
  const [labelAr, setLabelAr] = useState("");
  const [labelEn, setLabelEn] = useState("");
  const [query, setQuery] = useState("");

  const shown = useMemo(() => {
    const q = query.trim().toLowerCase();
    return q ? tags.filter((t) => t.key.includes(q) || t.label_ar.includes(q)) : tags;
  }, [tags, query]);

  async function create() {
    const res = await fetch("/api/coupon-tags", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ key: labelAr, label_ar: labelAr, label_en: labelEn }),
    });
    const json = await res.json();
    if (!res.ok) return onError(json.message ?? "تعذّر إنشاء الوسم");
    setLabelAr("");
    setLabelEn("");
    onNotice("تم إنشاء الوسم.");
    await onChanged();
  }

  return (
    <Card>
      <SectionHeader
        title="وسوم العروض"
        description="كلمات وصفية تُربط بالعرض من نموذج العرض بالأعلى، مثل «توصيل مجاني»."
        action={
          <Button
            variant="ghost"
            size="sm"
            icon={open ? ChevronUp : ChevronDown}
            onClick={() => setOpen(!open)}
          >
            {open ? "إخفاء" : `عرض (${fmt(tags.length)})`}
          </Button>
        }
      />

      {open && (
        <>
          <div className="grid items-end gap-3 md:grid-cols-4">
            <TextField
              label="الاسم بالعربية"
              value={labelAr}
              onChange={(e) => setLabelAr(e.target.value)}
              hint={labelAr ? `المفتاح الذي سيُحفظ: ${normalizeTagKey(labelAr)}` : "يُشتق المفتاح تلقائيًا من الاسم."}
            />
            <TextField
              label="الاسم بالإنجليزية"
              dir="ltr"
              value={labelEn}
              onChange={(e) => setLabelEn(e.target.value)}
            />
            <Button icon={Plus} onClick={create}>
              إنشاء وسم
            </Button>
            <TextField label="ابحث في الوسوم" value={query} onChange={(e) => setQuery(e.target.value)} />
          </div>

          <div className="mt-4 flex flex-wrap gap-2">
            {shown.map((t) => (
              <span key={t.id} className="rounded-full bg-muted px-3 py-1 text-micro text-ink-soft">
                #{t.label_ar} <span className="ltr font-mono text-ink-faint">({t.key})</span>
              </span>
            ))}
            {shown.length === 0 && <span className="text-micro text-ink-faint">لا توجد وسوم.</span>}
          </div>
        </>
      )}
    </Card>
  );
}

/* ------------------------------------------------------------------- preview */

function PreviewCard({
  coupon, categories, tags, onClose,
}: {
  coupon: Coupon;
  categories: CategoryRow[];
  tags: TagRow[];
  onClose: () => void;
}) {
  const category = categories.find((c) => c.key === coupon.display_category_key);
  const linked = (coupon.coupon_tag_links ?? [])
    .map((l) => tags.find((t) => t.id === l.tag_id))
    .filter(Boolean) as TagRow[];
  return (
    <Card>
      <SectionHeader
        title="معاينة العرض كما يراه المستخدم"
        description="تقريب لشكل بطاقة العرض داخل التطبيق."
        action={
          <Button variant="ghost" size="sm" icon={X} onClick={onClose}>
            إغلاق
          </Button>
        }
      />
      <div className="max-w-sm rounded-card border border-hairline p-4 shadow-card" dir="rtl">
        <div className="h-28 rounded-xl" style={{ backgroundColor: coupon.accent_hex ?? "#ECEFF6" }} />
        <p className="mt-3 text-micro text-ink-faint">{coupon.partner_name}</p>
        <h3 className="text-lg font-semibold text-ink">{coupon.title_ar}</h3>
        <p className="mt-1 text-sm text-ink-soft">{coupon.description_ar}</p>
        <div className="mt-2 flex flex-wrap gap-1">
          {category && (
            <span className="rounded-full bg-muted px-2 py-0.5 text-micro text-ink-soft">
              {category.label_ar}
            </span>
          )}
          {linked.map((t) => (
            <span key={t.id} className="rounded-full bg-muted px-2 py-0.5 text-micro text-ink-soft">
              #{t.label_ar}
            </span>
          ))}
        </div>
        <div className="mt-3 rounded-field bg-brand-900 px-3 py-2.5 text-center text-sm font-semibold text-white">
          {coupon.redemption_type === "code" ? `انسخ الكود: ${coupon.code}` : "احصل على العرض"}
        </div>
        <p className="mt-2 text-micro text-ink-faint">
          {fmtDate(coupon.valid_from)} → {coupon.valid_until ? fmtDate(coupon.valid_until) : "مفتوح"}
          {coupon.country_codes.length === 0 ? " · كل الدول" : ` · ${coupon.country_codes.join("، ")}`}
        </p>
      </div>
    </Card>
  );
}
