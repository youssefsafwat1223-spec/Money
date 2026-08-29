"use client";

import { useEffect, useMemo, useState } from "react";
import { Megaphone, Pause, Pencil, Play, Plus, Save, Trash2 } from "lucide-react";
import {
  Banner,
  Card,
  EmptyState,
  ErrorState,
  HelpNote,
  LoadingState,
  PageHeader,
  SectionHeader,
  StatusBadge,
} from "@/components/ui/primitives";
import { Button, CheckboxField, SelectField, TextAreaField, TextField } from "@/components/ui/form";
import { ConfirmDialog, type ConfirmSpec } from "@/components/ui/confirm-dialog";
import { FilterBar, FilterSelect } from "@/components/ui/filter-bar";
import {
  CAMPAIGN_TYPE_OPTIONS,
  SEGMENT_OPTIONS,
  campaignTypeLabel,
  segmentLabel,
} from "@/lib/labels";
import { fmt, fmtDate } from "@/lib/utils";

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

type Form = {
  id: string;
  title_ar: string;
  title_en: string;
  body_ar: string;
  body_en: string;
  type: string;
  target_segment: string;
  action_label_ar: string;
  action_label_en: string;
  action_route: string;
  action_url: string;
  valid_from: string;
  valid_until: string;
  max_impressions: string;
  cooldown_hours: string;
  is_dismissible: boolean;
  once_per_user: boolean;
  priority: string;
  is_active: boolean;
};

const emptyForm: Form = {
  id: "",
  title_ar: "",
  title_en: "",
  body_ar: "",
  body_en: "",
  type: "dashboard_banner",
  target_segment: "all",
  action_label_ar: "",
  action_label_en: "",
  action_route: "",
  action_url: "",
  valid_from: "",
  valid_until: "",
  max_impressions: "3",
  cooldown_hours: "24",
  is_dismissible: true,
  once_per_user: false,
  priority: "50",
  is_active: true,
};

function toForm(c: Campaign): Form {
  return {
    id: c.id,
    title_ar: c.title_ar,
    title_en: c.title_en,
    body_ar: c.body_ar ?? "",
    body_en: c.body_en ?? "",
    type: c.type,
    target_segment: c.target_segment,
    action_label_ar: c.action_label_ar ?? "",
    action_label_en: c.action_label_en ?? "",
    action_route: c.action_route ?? "",
    action_url: c.action_url ?? "",
    valid_from: c.valid_from,
    valid_until: c.valid_until ?? "",
    max_impressions: c.max_impressions == null ? "" : String(c.max_impressions),
    cooldown_hours: String(c.cooldown_hours),
    is_dismissible: c.is_dismissible,
    once_per_user: c.once_per_user,
    priority: String(c.priority),
    is_active: c.is_active,
  };
}

export default function CampaignsPage() {
  const [campaigns, setCampaigns] = useState<Campaign[]>([]);
  const [form, setForm] = useState<Form | null>(null);
  const [loading, setLoading] = useState(true);
  const [loadError, setLoadError] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [search, setSearch] = useState("");
  const [status, setStatus] = useState("all");
  const [confirm, setConfirm] = useState<(ConfirmSpec & { run: () => Promise<void> }) | null>(null);

  const activeCount = useMemo(
    () => campaigns.filter((campaign) => campaign.is_active).length,
    [campaigns],
  );

  useEffect(() => {
    void load(true);
  }, []);

  async function load(first = false) {
    if (first) setLoading(true);
    const res = await fetch("/api/campaigns");
    const json = await res.json();
    if (first) setLoading(false);
    if (!res.ok) {
      if (first) setLoadError(json.error ?? "تعذّر تحميل الحملات");
      else setError(json.error ?? "تعذّر تحميل الحملات");
      return;
    }
    setCampaigns((json.campaigns ?? []) as Campaign[]);
  }

  const visible = useMemo(() => {
    const q = search.trim().toLowerCase();
    return campaigns.filter((c) => {
      if (status === "active" && !c.is_active) return false;
      if (status === "paused" && c.is_active) return false;
      if (!q) return true;
      return (
        c.title_ar.toLowerCase().includes(q) ||
        (c.title_en ?? "").toLowerCase().includes(q) ||
        (c.body_ar ?? "").toLowerCase().includes(q)
      );
    });
  }, [campaigns, search, status]);

  function payloadFrom(f: Form) {
    return {
      ...(f.id ? { id: f.id } : {}),
      title_ar: f.title_ar,
      title_en: f.title_en,
      body_ar: f.body_ar,
      body_en: f.body_en,
      type: f.type,
      target_segment: f.target_segment,
      action_label_ar: f.action_label_ar,
      action_label_en: f.action_label_en,
      action_route: f.action_route,
      action_url: f.action_url,
      valid_from: f.valid_from || new Date().toISOString(),
      valid_until: f.valid_until || null,
      max_impressions: f.max_impressions ? Number(f.max_impressions) : null,
      cooldown_hours: Number(f.cooldown_hours),
      priority: Number(f.priority),
      is_dismissible: f.is_dismissible,
      once_per_user: f.once_per_user,
      is_active: f.is_active,
    };
  }

  async function saveCampaign() {
    if (!form) return;
    if (!form.title_ar.trim()) return setError("عنوان الحملة بالعربية مطلوب.");
    setBusy(true);
    setError(null);
    setNotice(null);
    const editing = Boolean(form.id);
    const res = await fetch("/api/campaigns", {
      method: editing ? "PATCH" : "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payloadFrom(form)),
    });
    const json = await res.json();
    setBusy(false);
    if (!res.ok) {
      setError(json.error ?? (editing ? "تعذّر حفظ الحملة" : "تعذّر إنشاء الحملة"));
      return;
    }
    setForm(null);
    setNotice(editing ? "تم حفظ تعديلات الحملة." : "تم إنشاء الحملة.");
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
      setError(json.error ?? "تعذّر تحديث الحملة");
      return;
    }
    await load();
  }

  async function deleteCampaign(id: string) {
    const res = await fetch(`/api/campaigns?id=${encodeURIComponent(id)}`, { method: "DELETE" });
    if (!res.ok) {
      const json = await res.json();
      setError(json.error ?? "تعذّر حذف الحملة");
      return;
    }
    setNotice("تم حذف الحملة.");
    await load();
  }

  async function runConfirmed() {
    if (!confirm) return;
    setBusy(true);
    setError(null);
    setNotice(null);
    await confirm.run();
    setBusy(false);
    setConfirm(null);
  }

  return (
    <div className="space-y-6">
      <PageHeader
        eyebrow="النمو والمكافآت"
        title="الحملات"
        description={`${fmt(activeCount)} حملة نشِطة من ${fmt(campaigns.length)}. الحملة رسالة موجّهة تظهر لشريحة محددة من المستخدمين فقط، بعكس الإعلان الذي يظهر للجميع.`}
        action={
          !form && (
            <Button icon={Plus} onClick={() => setForm(emptyForm)}>
              حملة جديدة
            </Button>
          )
        }
      />

      {error && <Banner tone="danger" onDismiss={() => setError(null)}>{error}</Banner>}
      {notice && <Banner tone="success" onDismiss={() => setNotice(null)}>{notice}</Banner>}

      {form && (
        <Card>
          <SectionHeader
            title={form.id ? "تعديل الحملة" : "حملة جديدة"}
            description="حدّد الرسالة، ومكان ظهورها، ومن الذي يراها، وكم مرة."
          />

          <div className="space-y-6">
            <div>
              <h3 className="mb-3 text-tiny font-semibold tracking-wide text-ink-faint">المحتوى</h3>
              <div className="grid gap-4 md:grid-cols-2">
                <TextField
                  label="العنوان بالعربية"
                  required
                  value={form.title_ar}
                  onChange={(e) => setForm({ ...form, title_ar: e.target.value })}
                />
                <TextField
                  label="العنوان بالإنجليزية"
                  dir="ltr"
                  value={form.title_en}
                  onChange={(e) => setForm({ ...form, title_en: e.target.value })}
                />
                <TextAreaField
                  label="النص بالعربية"
                  rows={3}
                  value={form.body_ar}
                  onChange={(e) => setForm({ ...form, body_ar: e.target.value })}
                />
                <TextAreaField
                  label="النص بالإنجليزية"
                  dir="ltr"
                  rows={3}
                  value={form.body_en}
                  onChange={(e) => setForm({ ...form, body_en: e.target.value })}
                />
              </div>
            </div>

            <div>
              <h3 className="mb-3 text-tiny font-semibold tracking-wide text-ink-faint">
                مكان الظهور والجمهور
              </h3>
              <div className="grid gap-4 md:grid-cols-2">
                <SelectField
                  label="مكان الظهور"
                  value={form.type}
                  onChange={(e) => setForm({ ...form, type: e.target.value })}
                  options={CAMPAIGN_TYPE_OPTIONS}
                  hint="أين تظهر هذه الرسالة داخل التطبيق."
                />
                <SelectField
                  label="الشريحة المستهدَفة"
                  value={form.target_segment}
                  onChange={(e) => setForm({ ...form, target_segment: e.target.value })}
                  options={SEGMENT_OPTIONS}
                  hint="لن تظهر الحملة إلا للمستخدمين الذين تنطبق عليهم هذه الصفة."
                />
              </div>
            </div>

            <div>
              <h3 className="mb-3 text-tiny font-semibold tracking-wide text-ink-faint">
                زر الإجراء
              </h3>
              <div className="grid gap-4 md:grid-cols-3">
                <TextField
                  label="نص الزر بالعربية"
                  value={form.action_label_ar}
                  onChange={(e) => setForm({ ...form, action_label_ar: e.target.value })}
                  hint="اتركه فارغًا إذا كانت الرسالة للقراءة فقط."
                />
                <TextField
                  label="الوجهة داخل التطبيق"
                  mono
                  value={form.action_route}
                  onChange={(e) => setForm({ ...form, action_route: e.target.value })}
                  hint="شاشة داخل التطبيق — مثل /settings."
                />
                <TextField
                  label="رابط خارجي"
                  mono
                  value={form.action_url}
                  onChange={(e) => setForm({ ...form, action_url: e.target.value })}
                  hint="يُستخدم بدل الوجهة الداخلية عند فتح موقع خارجي."
                />
              </div>
            </div>

            <div>
              <h3 className="mb-3 text-tiny font-semibold tracking-wide text-ink-faint">
                التكرار والأولوية
              </h3>
              <div className="grid gap-4 md:grid-cols-3">
                <TextField
                  label="أقصى عدد مرات للظهور"
                  type="number"
                  value={form.max_impressions}
                  onChange={(e) => setForm({ ...form, max_impressions: e.target.value })}
                  hint="اتركه فارغًا ليظهر بلا حد أقصى."
                />
                <TextField
                  label="فترة الانتظار بين مرة وأخرى (بالساعات)"
                  type="number"
                  value={form.cooldown_hours}
                  onChange={(e) => setForm({ ...form, cooldown_hours: e.target.value })}
                  hint="أقل مدة تفصل بين ظهورين لنفس المستخدم."
                />
                <TextField
                  label="الأولوية"
                  type="number"
                  value={form.priority}
                  onChange={(e) => setForm({ ...form, priority: e.target.value })}
                  hint="عند تزاحم أكثر من حملة، تظهر ذات الرقم الأعلى أولًا."
                />
              </div>
              <div className="mt-4 flex flex-wrap items-start gap-8">
                <CheckboxField
                  label="يمكن للمستخدم إخفاء الرسالة"
                  checked={form.is_dismissible}
                  onChange={(v) => setForm({ ...form, is_dismissible: v })}
                />
                <CheckboxField
                  label="مرة واحدة فقط لكل مستخدم"
                  hint="لا تُعرض مرة أخرى حتى لو لم يتفاعل معها."
                  checked={form.once_per_user}
                  onChange={(v) => setForm({ ...form, once_per_user: v })}
                />
                <CheckboxField
                  label="الحملة نشِطة"
                  checked={form.is_active}
                  onChange={(v) => setForm({ ...form, is_active: v })}
                />
              </div>
            </div>

            <div className="flex justify-end gap-2.5 border-t border-divider pt-4">
              <Button variant="secondary" onClick={() => setForm(null)}>
                إلغاء
              </Button>
              <Button icon={Save} onClick={saveCampaign} loading={busy}>
                {form.id ? "حفظ التعديلات" : "إنشاء الحملة"}
              </Button>
            </div>
          </div>
        </Card>
      )}

      <HelpNote>
        الحملة تُعرض فقط للمستخدمين الذين تنطبق عليهم الشريحة المختارة، وضمن حدود عدد مرات الظهور
        وفترة الانتظار. إيقاف الحملة يوقف ظهورها فورًا للمستخدمين الجدد دون حذف بيانات عرضها.
      </HelpNote>

      {loading ? (
        <LoadingState label="جارٍ تحميل الحملات…" />
      ) : loadError ? (
        <ErrorState title="تعذّر تحميل الحملات" detail={loadError} />
      ) : campaigns.length === 0 ? (
        <Card padded={false}>
          <EmptyState
            icon={Megaphone}
            title="لا توجد حملات بعد"
            description="أنشئ حملة لتوجيه رسالة إلى شريحة محددة من المستخدمين."
            action={
              !form && (
                <Button icon={Plus} onClick={() => setForm(emptyForm)}>
                  حملة جديدة
                </Button>
              )
            }
          />
        </Card>
      ) : (
        <>
          <FilterBar
            search={search}
            onSearch={setSearch}
            placeholder="ابحث في عناوين الحملات ونصوصها…"
            resultLabel={`${fmt(visible.length)} من ${fmt(campaigns.length)}`}
          >
            <FilterSelect
              label="الحالة"
              value={status}
              onChange={setStatus}
              options={[
                { value: "all", label: "كل الحالات" },
                { value: "active", label: "نشِطة" },
                { value: "paused", label: "متوقفة" },
              ]}
            />
          </FilterBar>

          {visible.length === 0 ? (
            <Card padded={false}>
              <EmptyState
                title="لا توجد حملات مطابقة"
                description="جرّب كلمة بحث أخرى أو أعِد ضبط عوامل التصفية."
              />
            </Card>
          ) : (
            <div className="space-y-3">
              {visible.map((campaign) => (
                <Card key={campaign.id} className={campaign.is_active ? undefined : "opacity-75"}>
                  <div className="flex flex-wrap items-start justify-between gap-4">
                    <div className="min-w-0 flex-1">
                      <div className="mb-2 flex flex-wrap items-center gap-2">
                        <StatusBadge
                          label={campaign.is_active ? "نشِطة" : "متوقفة"}
                          tone={campaign.is_active ? "success" : "neutral"}
                        />
                        <StatusBadge
                          label={campaignTypeLabel(campaign.type)}
                          tone="brand"
                          dot={false}
                        />
                        <StatusBadge
                          label={segmentLabel(campaign.target_segment)}
                          tone="info"
                          dot={false}
                        />
                      </div>
                      <h3 className="text-lg font-semibold text-ink">{campaign.title_ar}</h3>
                      {campaign.body_ar && (
                        <p className="mt-1 text-sm text-ink-soft">{campaign.body_ar}</p>
                      )}
                      <p className="tnum mt-2 text-micro text-ink-faint">
                        الأولوية {fmt(campaign.priority)} ·{" "}
                        {campaign.max_impressions == null
                          ? "بلا حد لعدد مرات الظهور"
                          : `حتى ${fmt(campaign.max_impressions)} مرات`}{" "}
                        · انتظار {fmt(campaign.cooldown_hours)} ساعة ·{" "}
                        {campaign.once_per_user ? "مرة واحدة لكل مستخدم" : "قابلة للتكرار"} · تبدأ{" "}
                        {fmtDate(campaign.valid_from)}
                        {campaign.valid_until ? ` وتنتهي ${fmtDate(campaign.valid_until)}` : ""}
                      </p>
                    </div>

                    <div className="flex shrink-0 flex-wrap gap-2">
                      <Button
                        size="sm"
                        variant="secondary"
                        icon={Pencil}
                        onClick={() => {
                          setForm(toForm(campaign));
                          window.scrollTo({ top: 0, behavior: "smooth" });
                        }}
                      >
                        تعديل
                      </Button>
                      <Button
                        size="sm"
                        variant="secondary"
                        icon={campaign.is_active ? Pause : Play}
                        onClick={() =>
                          setConfirm({
                            title: campaign.is_active ? "إيقاف هذه الحملة؟" : "تشغيل هذه الحملة؟",
                            confirmLabel: campaign.is_active ? "إيقاف الحملة" : "تشغيل الحملة",
                            tone: campaign.is_active ? "warning" : "brand",
                            consequence: campaign.is_active ? (
                              <>
                                ستتوقف «{campaign.title_ar}» عن الظهور للمستخدمين الجدد فورًا.{" "}
                                <strong className="text-ink">لن تُحذف أي بيانات</strong>، ويمكنك
                                تشغيلها مرة أخرى في أي وقت.
                              </>
                            ) : (
                              <>
                                ستبدأ «{campaign.title_ar}» بالظهور لشريحة «
                                {segmentLabel(campaign.target_segment)}» ضمن الحدود المحدّدة لها.
                              </>
                            ),
                            run: () => updateCampaign(campaign, { is_active: !campaign.is_active }),
                          })
                        }
                      >
                        {campaign.is_active ? "إيقاف" : "تشغيل"}
                      </Button>
                      <Button
                        size="sm"
                        variant="danger"
                        icon={Trash2}
                        onClick={() =>
                          setConfirm({
                            title: "حذف هذه الحملة نهائيًا؟",
                            confirmLabel: "حذف نهائيًا",
                            tone: "danger",
                            consequence: (
                              <>
                                سيُحذف محتوى «{campaign.title_ar}» ولن يمكن استرجاعه.
                                <br />
                                <strong className="text-ink">
                                  إذا أردت إيقافها فقط، استخدم «إيقاف» — يبقى المحتوى محفوظًا.
                                </strong>
                              </>
                            ),
                            run: () => deleteCampaign(campaign.id),
                          })
                        }
                      >
                        حذف
                      </Button>
                    </div>
                  </div>
                </Card>
              ))}
            </div>
          )}
        </>
      )}

      <ConfirmDialog
        spec={confirm}
        busy={busy}
        onCancel={() => setConfirm(null)}
        onConfirm={runConfirmed}
      />
    </div>
  );
}
