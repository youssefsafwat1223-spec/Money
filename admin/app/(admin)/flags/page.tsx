"use client";

import { useEffect, useMemo, useState } from "react";
import { RotateCcw, Save, SlidersHorizontal } from "lucide-react";
import {
  Banner,
  Card,
  EmptyState,
  ErrorState,
  HelpNote,
  LoadingState,
  PageHeader,
  StatusBadge,
} from "@/components/ui/primitives";
import { Button, Toggle } from "@/components/ui/form";
import { ConfirmDialog, type ConfirmSpec } from "@/components/ui/confirm-dialog";
import { FilterBar, FilterSelect } from "@/components/ui/filter-bar";
import { CopyId } from "@/components/ui/copy-id";
import { flagDescription, isRetiredFlag, valueTypeLabel } from "@/lib/labels";
import { fmt } from "@/lib/utils";

type Flag = {
  id: string;
  key: string;
  value_type: string;
  value: string;
  description: string | null;
  rollout_percent: number;
  is_active: boolean;
};

export default function FlagsPage() {
  const [flags, setFlags] = useState<Flag[]>([]);
  /** The last state confirmed by the server, so "unsaved" is provable. */
  const [saved, setSaved] = useState<Record<string, Pick<Flag, "value" | "rollout_percent">>>({});
  const [loading, setLoading] = useState(true);
  const [loadError, setLoadError] = useState("");
  const [savingId, setSavingId] = useState<string | null>(null);
  const [error, setError] = useState("");
  const [notice, setNotice] = useState("");
  const [search, setSearch] = useState("");
  const [status, setStatus] = useState("all");
  const [confirm, setConfirm] = useState<(ConfirmSpec & { flag: Flag }) | null>(null);
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    fetch("/api/admin-data?resource=feature_flags", { cache: "no-store" })
      .then(async (response) => {
        const body = await response.json();
        if (!response.ok) throw new Error(body.error ?? "تعذّر تحميل إعدادات المزايا");
        const rows = (body.data ?? []) as Flag[];
        setFlags(rows);
        setSaved(
          Object.fromEntries(
            rows.map((f) => [f.id, { value: f.value, rollout_percent: f.rollout_percent }]),
          ),
        );
      })
      .catch((e) => setLoadError(e instanceof Error ? e.message : "تعذّر تحميل إعدادات المزايا"))
      .finally(() => setLoading(false));
  }, []);

  const visible = useMemo(() => {
    const q = search.trim().toLowerCase();
    return flags.filter((f) => {
      if (status === "active" && !f.is_active) return false;
      if (status === "inactive" && f.is_active) return false;
      if (!q) return true;
      return f.key.toLowerCase().includes(q) || (f.description ?? "").toLowerCase().includes(q);
    });
  }, [flags, search, status]);

  const activeCount = flags.filter((f) => f.is_active).length;

  function askToggle(flag: Flag) {
    setError("");
    setNotice("");
    const turningOn = !flag.is_active;
    setConfirm({
      flag,
      tone: turningOn ? "brand" : "warning",
      title: turningOn ? "تفعيل هذه الميزة؟" : "إيقاف هذه الميزة؟",
      confirmLabel: turningOn ? "تفعيل الآن" : "إيقاف الآن",
      consequence: turningOn ? (
        <>
          ستصبح الميزة متاحة{" "}
          <strong className="text-ink">
            {flag.rollout_percent > 0 && flag.rollout_percent < 100
              ? `لنحو ${fmt(flag.rollout_percent)}% من المستخدمين`
              : "لكل المستخدمين"}
          </strong>{" "}
          بمجرد وصول التحديث إلى أجهزتهم.
          <br />
          <span className="text-tiny">
            التغيير ليس فوريًا: الجهاز يحتاج إلى مزامنة الكتالوج وإعادة تشغيل التطبيق.
          </span>
        </>
      ) : (
        <>
          لن تظهر هذه الميزة للمستخدمين بعد الآن، <strong className="text-ink">دون حذف أي من بياناتهم</strong>.
          يمكنك تفعيلها مرة أخرى في أي وقت وستعود كما كانت.
        </>
      ),
    });
  }

  async function applyToggle() {
    if (!confirm) return;
    const flag = confirm.flag;
    setBusy(true);
    const updated = { ...flag, is_active: !flag.is_active };
    const response = await fetch("/api/admin-data", {
      method: "PATCH",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ resource: "feature_flags", ...updated }),
    });
    setBusy(false);
    setConfirm(null);
    if (!response.ok) {
      const body = await response.json().catch(() => ({}));
      setError(body.error ?? "تعذّر تغيير حالة الميزة");
      return;
    }
    setFlags((prev) => prev.map((f) => (f.id === flag.id ? updated : f)));
    setNotice(updated.is_active ? `تم تفعيل «${flag.key}».` : `تم إيقاف «${flag.key}».`);
  }

  function edit(id: string, patch: Partial<Flag>) {
    setFlags((prev) => prev.map((f) => (f.id === id ? { ...f, ...patch } : f)));
  }

  function isDirty(flag: Flag) {
    const base = saved[flag.id];
    return !base || base.value !== flag.value || base.rollout_percent !== flag.rollout_percent;
  }

  function revert(flag: Flag) {
    const base = saved[flag.id];
    if (base) edit(flag.id, base);
  }

  async function saveFlag(flag: Flag) {
    setSavingId(flag.id);
    setError("");
    setNotice("");
    const response = await fetch("/api/admin-data", {
      method: "PATCH",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ resource: "feature_flags", ...flag }),
    });
    setSavingId(null);
    if (!response.ok) {
      const body = await response.json().catch(() => ({}));
      setError(body.error ?? "تعذّر حفظ الإعداد");
      return;
    }
    setSaved((prev) => ({
      ...prev,
      [flag.id]: { value: flag.value, rollout_percent: flag.rollout_percent },
    }));
    setNotice(`تم حفظ إعدادات «${flag.key}».`);
  }

  return (
    <div className="space-y-6">
      <PageHeader
        eyebrow="إعدادات النظام"
        title="إعدادات المزايا"
        description={`${fmt(activeCount)} ميزة مفعّلة من ${fmt(flags.length)}. تتيح لك تشغيل ميزة أو إيقافها دون إصدار تحديث جديد للتطبيق.`}
      />

      <HelpNote tone="warning">
        تغيير حالة الميزة ليس فوريًا على أجهزة المستخدمين: الجهاز يقرأ الإعداد عند مزامنة الكتالوج
        وإعادة تشغيل التطبيق. خطّط لذلك قبل أي إطلاق مرتبط بموعد.
      </HelpNote>

      {error && <Banner tone="danger" onDismiss={() => setError("")}>{error}</Banner>}
      {notice && <Banner tone="success" onDismiss={() => setNotice("")}>{notice}</Banner>}

      {loading ? (
        <LoadingState label="جارٍ تحميل إعدادات المزايا…" />
      ) : loadError ? (
        <ErrorState title="تعذّر تحميل إعدادات المزايا" detail={loadError} />
      ) : (
        <>
          <FilterBar
            search={search}
            onSearch={setSearch}
            placeholder="ابحث باسم الميزة أو وصفها…"
            visibleCount={visible.length}
        totalCount={flags.length}
          >
            <FilterSelect
              label="الحالة"
              value={status}
              onChange={setStatus}
              options={[
                { value: "all", label: "كل الحالات" },
                { value: "active", label: "مفعّلة" },
                { value: "inactive", label: "متوقفة" },
              ]}
            />
          </FilterBar>

          {visible.length === 0 ? (
            <Card padded={false}>
              <EmptyState
                icon={SlidersHorizontal}
                title={flags.length === 0 ? "لا توجد مزايا معرّفة" : "لا توجد نتائج مطابقة"}
                description={
                  flags.length === 0
                    ? "تُضاف المزايا من قاعدة البيانات ثم تُدار من هنا."
                    : "جرّب كلمة بحث أخرى أو أعِد ضبط عوامل التصفية."
                }
              />
            </Card>
          ) : (
            <div className="space-y-3">
              {visible.map((flag) => {
                const dirty = isDirty(flag);
                return (
                  <Card key={flag.id}>
                    <div className="flex items-start justify-between gap-4">
                      <div className="min-w-0 flex-1">
                        <div className="flex flex-wrap items-center gap-2">
                          <h2 className="ltr font-mono text-sm font-semibold text-ink">{flag.key}</h2>
                          <StatusBadge
                            label={flag.is_active ? "مفعّلة" : "متوقفة"}
                            tone={flag.is_active ? "success" : "neutral"}
                          />
                          {/* Metadata, not a control — prefixed so it cannot be
                              mistaken for the toggle next to it. */}
                          <span className="text-micro text-ink-faint">
                            النوع: {valueTypeLabel(flag.value_type)}
                          </span>
                          {dirty && <StatusBadge label="تغييرات غير محفوظة" tone="warning" />}
                          {/* UX-021 — an operator cannot discover from this
                              panel that a switch is wired to nothing. */}
                          {isRetiredFlag(flag.key) && (
                            <StatusBadge label="غير مستخدمة في التطبيق" tone="neutral" />
                          )}
                        </div>
                        <p className="mt-1.5 text-sm text-ink-soft">
                          {flagDescription(flag.key, flag.description) ??
                            "لا يوجد وصف لهذه الميزة."}
                        </p>
                        {isRetiredFlag(flag.key) && (
                          <p className="mt-1 text-tiny text-ink-faint">
                            التطبيق لم يعد يقرأ هذه الميزة — تغييرها لن يؤثر على أي سلوك.
                          </p>
                        )}
                      </div>

                      <Toggle
                        checked={flag.is_active}
                        onChange={() => askToggle(flag)}
                        label={flag.is_active ? `إيقاف ${flag.key}` : `تفعيل ${flag.key}`}
                      />
                    </div>

                    {flag.is_active && (
                      <div className="mt-4 space-y-4 border-t border-divider pt-4">
                        <div className="grid gap-5 md:grid-cols-2">
                          <div>
                            <label className="mb-1.5 block text-tiny font-medium text-ink">
                              قيمة الإعداد
                            </label>
                            <input
                              value={flag.value}
                              onChange={(e) => edit(flag.id, { value: e.target.value })}
                              className="ltr w-full rounded-field border border-line bg-surface px-3 py-2 font-mono text-tiny text-ink focus:border-brand-500 focus:outline-none focus:ring-2 focus:ring-brand-500/25"
                            />
                            <p className="mt-1.5 text-micro text-ink-faint">
                              القيمة التي يقرأها التطبيق عند تفعيل هذه الميزة.
                            </p>
                          </div>

                          <div>
                            <label className="mb-1.5 flex items-center justify-between text-tiny font-medium text-ink">
                              <span>نسبة الإطلاق التدريجي</span>
                              <span className="tnum text-brand-700">{fmt(flag.rollout_percent)}%</span>
                            </label>
                            <input
                              type="range"
                              min={0}
                              max={100}
                              value={flag.rollout_percent}
                              aria-label="نسبة الإطلاق التدريجي"
                              onChange={(e) => edit(flag.id, { rollout_percent: Number(e.target.value) })}
                              className="w-full accent-brand-700"
                            />
                            <p className="mt-1.5 text-micro text-ink-faint">
                              تظهر الميزة لهذه النسبة تقريبًا من المستخدمين. النسبة ثابتة لكل مستخدم،
                              فلا تظهر وتختفي عشوائيًا.
                            </p>
                          </div>
                        </div>

                        <div className="flex items-center justify-end gap-2.5">
                          {dirty && (
                            <Button size="sm" variant="ghost" icon={RotateCcw} onClick={() => revert(flag)}>
                              تراجع
                            </Button>
                          )}
                          <Button
                            size="sm"
                            icon={Save}
                            disabled={!dirty}
                            loading={savingId === flag.id}
                            onClick={() => saveFlag(flag)}
                          >
                            {dirty ? "حفظ التغييرات" : "لا توجد تغييرات"}
                          </Button>
                        </div>
                      </div>
                    )}

                    <div className="mt-3 flex justify-end">
                      <CopyId value={flag.key} label="مفتاح الميزة" length={40} />
                    </div>
                  </Card>
                );
              })}
            </div>
          )}
        </>
      )}

      <ConfirmDialog
        spec={confirm}
        busy={busy}
        onCancel={() => setConfirm(null)}
        onConfirm={applyToggle}
      />
    </div>
  );
}
