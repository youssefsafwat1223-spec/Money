"use client";

import { useCallback, useEffect, useMemo, useState } from "react";
import { History, Plus, SlidersHorizontal } from "lucide-react";
import {
  Banner,
  Card,
  EmptyState,
  ErrorState,
  HelpNote,
  LoadingState,
  PageHeader,
  StatusBadge,
  type Tone,
} from "@/components/ui/primitives";
import { Button, Toggle } from "@/components/ui/form";
import { FilterBar, FilterSelect } from "@/components/ui/filter-bar";
import { CopyId } from "@/components/ui/copy-id";
import { flagDescription, isRetiredFlag, valueTypeLabel } from "@/lib/labels";
import { fmt } from "@/lib/utils";
import {
  GROUP_ORDER,
  editableFields,
  isBulkEligible,
  isEditable,
  requiresTypedConfirmation,
  type ChangeRequest,
  type EditableField,
  type FlagGroup,
  type FlagMeta,
} from "@/lib/flag-registry";

type Flag = {
  id: string;
  key: string;
  value_type: string;
  value: string;
  description: string | null;
  rollout_percent: number;
  target_countries: string[];
  is_active: boolean;
  updated_at: string;
};
type AuditRow = {
  operation_id: string;
  actor_admin_id: string | null;
  flag_key: string;
  field: string;
  old_value: unknown;
  new_value: unknown;
  reason: string;
  created_at: string;
};
type Draft = Partial<Record<EditableField, unknown>>;
type PlanError = { key: string; code: string; detail?: string };
type Preview = {
  ok: boolean;
  errors: PlanError[];
  warnings: { key: string; code: string; detail: string }[];
  diffs: { key: string; field: string; old: unknown; new: unknown }[];
  high_risk_keys: string[];
};

const GROUP_LABEL: Record<FlagGroup, string> = {
  smart_capture_ai: "الالتقاط الذكي والذكاء الاصطناعي",
  monetization: "الإيرادات والعروض",
  experimental_high_risk: "تجريبية / عالية الخطورة",
  sync: "المزامنة",
  planning: "التخطيط",
  not_wired: "غير مربوطة (لا تأثير)",
};
const STATUS_LABEL: Record<FlagMeta["status"], [string, Tone]> = {
  app_read: ["مقروءة في التطبيق", "success"],
  server_read: ["مقروءة في الخادم", "info"],
  both: ["التطبيق والخادم", "info"],
  not_wired: ["غير مربوطة — لا تأثير", "neutral"],
  retired_but_read: ["متقاعدة لكنها مقروءة", "warning"],
};
const RISK_LABEL: Record<FlagMeta["risk"], [string, Tone]> = {
  low: ["خطورة منخفضة", "neutral"],
  medium: ["خطورة متوسطة", "warning"],
  high: ["خطورة عالية", "danger"],
};
const ROLLOUT_TEXT: Record<FlagMeta["rolloutSemantics"], string> = {
  app_percent_country: "إطلاق تدريجي بالنسبة (يحسبه التطبيق لكل جهاز)؛ استهداف الدول لا يعمل إلا عندما يرسل التطبيق رمز الدولة إلى catalog-flags",
  server_all_or_nothing: "الخادم: كل شيء أو لا شيء — النسبة الجزئية والدول غير مدعومة (0 أو 100 فقط)",
  none: "لا ينطبق — لا قارئ لهذا المفتاح",
};
const FIELD_LABEL: Record<string, string> = {
  is_active: "الحالة",
  value: "القيمة",
  rollout_percent: "نسبة الإطلاق",
  target_countries: "الدول",
  description: "الوصف",
  _created: "إنشاء الصف",
};
const ERROR_TEXT: Record<string, string> = {
  stale_or_conflict: "تغيّر هذا الإعداد منذ تحميل الصفحة. حدّث الصفحة ثم أعد المحاولة.",
  validation_failed: "التغييرات غير صالحة.",
  server_read_partial_rollout_unsupported: "الخادم لا يدعم الإطلاق الجزئي أو تحديد الدول لهذا المفتاح.",
  server_read_requires_full_rollout: "فعّل هذا المفتاح مع نسبة إطلاق 100 وبدون دول.",
  typed_confirmation_required: "اكتب اسم المفتاح للتأكيد.",
  value_type_mismatch: "القيمة لا تطابق نوع المفتاح.",
  value_out_of_range: "القيمة خارج النطاق المقبول في التطبيق.",
  rollout_percent_invalid: "نسبة الإطلاق يجب أن تكون عددًا صحيحًا من 0 إلى 100.",
  target_country_invalid: "رموز الدول يجب أن تكون حرفين كبيرين (ISO) مثل EG.",
  dependency_missing: "يتطلب نشر المهاجرة 0100 قبل تفعيل هذا المفتاح.",
  bulk_ineligible: "غير مؤهل للتعديل الجماعي.",
  not_wired_description_only: "مفتاح غير مربوط: يمكن تعديل الوصف فقط.",
  no_effective_changes: "لا توجد تغييرات.",
};
const errText = (e: PlanError) => `${e.key !== "*" ? `${e.key}: ` : ""}${ERROR_TEXT[e.code] ?? e.code}${e.detail ? ` (${e.detail})` : ""}`;

const show = (v: unknown) => (typeof v === "string" ? v : JSON.stringify(v));
const short = (id: string | null | undefined) => (id ? id.slice(0, 8) : "—");

type Modal = {
  changes: ChangeRequest[];
  title: string;
  preview: Preview | null;
  operationId: string;
  reason: string;
  typed: string;
  busy: boolean;
  error: string;
  stale: boolean;
};

export default function FlagsPage() {
  const [flags, setFlags] = useState<Flag[]>([]);
  const [registry, setRegistry] = useState<Record<string, FlagMeta>>({});
  const [missing, setMissing] = useState<string[]>([]);
  const [audit, setAudit] = useState<Record<string, AuditRow[]>>({});
  const [auditAvailable, setAuditAvailable] = useState(true);
  const [loading, setLoading] = useState(true);
  const [loadError, setLoadError] = useState("");
  const [notice, setNotice] = useState("");
  const [search, setSearch] = useState("");
  const [group, setGroup] = useState("all");
  const [drafts, setDrafts] = useState<Record<string, Draft>>({});
  const [countryText, setCountryText] = useState<Record<string, string>>({});
  const [selected, setSelected] = useState<Set<string>>(new Set());
  const [historyOpen, setHistoryOpen] = useState<string | null>(null);
  const [bulkRollout, setBulkRollout] = useState("100");
  const [modal, setModal] = useState<Modal | null>(null);

  const load = useCallback(async () => {
    setLoading(true);
    setLoadError("");
    try {
      const response = await fetch("/api/feature-flags", { cache: "no-store" });
      const body = await response.json();
      if (!response.ok) throw new Error(body.error ?? "تعذّر تحميل إعدادات المزايا");
      setFlags(body.flags ?? []);
      setRegistry(body.registry ?? {});
      setMissing(body.missing_keys ?? []);
      setAudit(body.audit ?? {});
      setAuditAvailable(body.audit_available !== false);
      setDrafts({});
      setCountryText({});
      setSelected(new Set());
    } catch (e) {
      setLoadError(e instanceof Error ? e.message : "تعذّر تحميل إعدادات المزايا");
    } finally {
      setLoading(false);
    }
  }, []);
  useEffect(() => {
    void load();
  }, [load]);

  const meta = (key: string): FlagMeta | undefined => registry[key];

  const visible = useMemo(() => {
    const q = search.trim().toLowerCase();
    return flags.filter((f) => {
      if (group !== "all" && meta(f.key)?.group !== group) return false;
      if (!q) return true;
      return f.key.toLowerCase().includes(q) || (f.description ?? "").toLowerCase().includes(q);
    });
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [flags, search, group, registry]);

  const grouped = GROUP_ORDER.map((g) => ({ g, items: visible.filter((f) => (meta(f.key)?.group ?? "not_wired") === g) })).filter(
    (x) => x.items.length > 0,
  );

  function setDraft(key: string, patch: Draft) {
    setDrafts((d) => ({ ...d, [key]: { ...d[key], ...patch } }));
  }
  function dirtyChange(flag: Flag): ChangeRequest | null {
    const d = drafts[flag.key];
    if (!d) return null;
    const set: Draft = {};
    for (const [field, v] of Object.entries(d)) {
      const current = (flag as unknown as Record<string, unknown>)[field];
      if (JSON.stringify(current ?? null) !== JSON.stringify(v ?? null)) set[field as EditableField] = v;
    }
    return Object.keys(set).length ? { key: flag.key, expected_updated_at: flag.updated_at, set } : null;
  }
  function countriesFor(flag: Flag): string[] | null {
    const text = countryText[flag.key];
    if (text === undefined) return null;
    return text.split(/[\s,]+/).filter(Boolean).map((c) => c.toUpperCase());
  }

  async function openPreview(changes: ChangeRequest[], title: string) {
    const operationId = crypto.randomUUID();
    setModal({ changes, title, preview: null, operationId, reason: "", typed: "", busy: true, error: "", stale: false });
    const response = await fetch("/api/feature-flags/preview", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ changes }),
    });
    const body = await response.json().catch(() => ({}));
    setModal((m) =>
      m && m.operationId === operationId
        ? {
            ...m,
            busy: false,
            preview: response.ok ? body : null,
            error: response.ok ? "" : (ERROR_TEXT[body.error] ?? body.error ?? "تعذّرت المعاينة"),
          }
        : m,
    );
  }

  function reviewFlag(flag: Flag) {
    const change = dirtyChange(flag);
    const countries = countriesFor(flag);
    const c: ChangeRequest | null = change ?? null;
    let merged = c;
    if (countries && JSON.stringify(countries) !== JSON.stringify(flag.target_countries ?? [])) {
      merged = { key: flag.key, expected_updated_at: flag.updated_at, set: { ...(c?.set ?? {}), target_countries: countries } };
    }
    if (!merged) return;
    void openPreview([merged], `مراجعة تغييرات «${flag.key}»`);
  }

  function createRow(key: string) {
    void openPreview([{ key, create: true, set: {} }], `إنشاء صف «${key}» (غير مفعّل)`);
  }

  function bulk(kind: "on" | "off" | "rollout") {
    const changes: ChangeRequest[] = flags
      .filter((f) => selected.has(f.key) && isBulkEligible(f.key))
      .map((f) => ({
        key: f.key,
        expected_updated_at: f.updated_at,
        set: kind === "rollout" ? { rollout_percent: Number(bulkRollout) } : { is_active: kind === "on" },
      }));
    if (changes.length === 0) return;
    const label = kind === "on" ? "تفعيل" : kind === "off" ? "إيقاف" : `نسبة إطلاق ${bulkRollout}%`;
    void openPreview(changes, `تعديل جماعي (${label}) لـ ${fmt(changes.length)} ميزة`);
  }

  async function apply() {
    if (!modal?.preview) return;
    setModal({ ...modal, busy: true, error: "" });
    const response = await fetch("/api/feature-flags/apply", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        changes: modal.changes,
        reason: modal.reason,
        operation_id: modal.operationId, // stable per dialog: a retry is a replay, not a second write
        typed_confirmation: modal.typed,
      }),
    });
    const body = await response.json().catch(() => ({}));
    if (!response.ok) {
      const errs: PlanError[] = body.errors ?? [];
      setModal({
        ...modal,
        busy: false,
        stale: response.status === 409,
        error:
          response.status === 409
            ? ERROR_TEXT.stale_or_conflict
            : errs.length
              ? errs.map(errText).join(" • ")
              : (body.detail ?? ERROR_TEXT[body.error] ?? "تعذّر تطبيق التغييرات"),
      });
      return;
    }
    setModal(null);
    setNotice(body.result?.replayed ? "هذه العملية طُبِّقت سابقًا — لم يتغير شيء." : "تم تطبيق التغييرات وتسجيلها في سجل المراجعة.");
    await load();
  }

  const modalHigh = modal?.preview?.high_risk_keys?.[0];
  const canConfirm =
    !!modal?.preview?.ok &&
    !modal.busy &&
    !modal.stale &&
    modal.reason.trim().length >= 4 &&
    modal.reason.trim().length <= 500 &&
    (!modalHigh || modal.typed.trim() === modalHigh);

  const activeCount = flags.filter((f) => f.is_active).length;

  return (
    <div className="space-y-6">
      <PageHeader
        eyebrow="إعدادات النظام"
        title="إعدادات المزايا"
        description={`${fmt(activeCount)} ميزة مفعّلة من ${fmt(flags.length)}. كل تغيير يُعاين أولًا ثم يُؤكَّد ويُسجَّل باسمك وسببه.`}
      />

      <HelpNote tone="warning">
        التغيير ليس فوريًا على الأجهزة: التطبيق يقرأ الإعداد عند مزامنة الكتالوج وإعادة التشغيل. المفاتيح التي يقرأها
        الخادم تدعم «كل شيء أو لا شيء» فقط. المفاتيح غير المربوطة لا تؤثر على أي سلوك.
      </HelpNote>
      {!auditAvailable && (
        <HelpNote tone="warning">
          سجل المراجعة غير منشور بعد (المهاجرة 0101). يمكنك الاطلاع على الإعدادات لكن التعديل سيُرفض حتى نشرها.
        </HelpNote>
      )}
      {notice && <Banner tone="success" onDismiss={() => setNotice("")}>{notice}</Banner>}

      {loading ? (
        <LoadingState label="جارٍ تحميل إعدادات المزايا…" />
      ) : loadError ? (
        <ErrorState title="تعذّر تحميل إعدادات المزايا" detail={loadError} />
      ) : (
        <>
          {missing.length > 0 && (
            <Card>
              <h2 className="text-sm font-semibold text-ink">مفاتيح مقروءة بلا صف في قاعدة البيانات</h2>
              <p className="mt-1 text-tiny text-ink-faint">
                التطبيق يستخدم قيمته الافتراضية (مغلقة) لهذه المفاتيح. إنشاء الصف يضيفه غير مفعّل بنسبة 0 — لا يُنشأ شيء تلقائيًا.
              </p>
              <div className="mt-3 flex flex-wrap gap-2">
                {missing.map((k) => (
                  <Button key={k} size="sm" variant="secondary" icon={Plus} onClick={() => createRow(k)}>
                    <span className="ltr font-mono">{k}</span>
                  </Button>
                ))}
              </div>
            </Card>
          )}

          <FilterBar
            search={search}
            onSearch={setSearch}
            placeholder="ابحث باسم الميزة أو وصفها…"
            visibleCount={visible.length}
            totalCount={flags.length}
          >
            <FilterSelect
              label="المجموعة"
              value={group}
              onChange={setGroup}
              options={[
                { value: "all", label: "كل المجموعات" },
                ...GROUP_ORDER.map((g) => ({ value: g, label: GROUP_LABEL[g] })),
              ]}
            />
          </FilterBar>

          {selected.size > 0 && (
            <Card>
              <div className="flex flex-wrap items-center gap-3">
                <span className="text-sm font-medium text-ink">{fmt(selected.size)} محددة</span>
                <Button size="sm" variant="secondary" onClick={() => bulk("on")}>تفعيل المحدد</Button>
                <Button size="sm" variant="secondary" onClick={() => bulk("off")}>إيقاف المحدد</Button>
                <input
                  type="number"
                  min={0}
                  max={100}
                  value={bulkRollout}
                  onChange={(e) => setBulkRollout(e.target.value)}
                  aria-label="نسبة الإطلاق الجماعية"
                  className="ltr w-20 rounded-field border border-line bg-surface px-2 py-1 text-tiny"
                />
                <Button size="sm" variant="secondary" onClick={() => bulk("rollout")}>تعيين نسبة الإطلاق</Button>
                <Button size="sm" variant="ghost" onClick={() => setSelected(new Set())}>مسح التحديد</Button>
                <span className="text-micro text-ink-faint">
                  التعديل الجماعي للمفاتيح المربوطة منخفضة/متوسطة الخطورة فقط.
                </span>
              </div>
            </Card>
          )}

          {visible.length === 0 ? (
            <Card padded={false}>
              <EmptyState icon={SlidersHorizontal} title="لا توجد نتائج" description="جرّب كلمة بحث أخرى أو أعِد ضبط عوامل التصفية." />
            </Card>
          ) : (
            grouped.map(({ g, items }) => (
              <section key={g} className="space-y-3">
                <h2 className="text-sm font-semibold text-ink-soft">{GROUP_LABEL[g]}</h2>
                {items.map((flag) => {
                  const m = meta(flag.key);
                  const fields = editableFields(flag.key);
                  const editable = isEditable(flag.key);
                  const change = dirtyChange(flag);
                  const countries = countriesFor(flag);
                  const countriesDirty = countries !== null && JSON.stringify(countries) !== JSON.stringify(flag.target_countries ?? []);
                  const dirty = !!change || countriesDirty;
                  const d = drafts[flag.key] ?? {};
                  const isActive = (d.is_active as boolean | undefined) ?? flag.is_active;
                  const history = audit[flag.key] ?? [];
                  const lastActor = history[0]?.actor_admin_id;
                  const [statusLabel, statusTone] = m ? STATUS_LABEL[m.status] : STATUS_LABEL.not_wired;
                  const [riskLabel, riskTone] = m ? RISK_LABEL[m.risk] : RISK_LABEL.low;
                  return (
                    <Card key={flag.id}>
                      <div className="flex items-start justify-between gap-4">
                        <div className="min-w-0 flex-1">
                          <div className="flex flex-wrap items-center gap-2">
                            {isBulkEligible(flag.key) && (
                              <input
                                type="checkbox"
                                aria-label={`تحديد ${flag.key}`}
                                checked={selected.has(flag.key)}
                                onChange={(e) =>
                                  setSelected((s) => {
                                    const n = new Set(s);
                                    if (e.target.checked) n.add(flag.key);
                                    else n.delete(flag.key);
                                    return n;
                                  })
                                }
                              />
                            )}
                            <h3 className="ltr font-mono text-sm font-semibold text-ink">{flag.key}</h3>
                            <StatusBadge label={flag.is_active ? "مفعّلة" : "متوقفة"} tone={flag.is_active ? "success" : "neutral"} />
                            <StatusBadge label={statusLabel} tone={statusTone} />
                            <StatusBadge label={riskLabel} tone={riskTone} />
                            {m?.readers.map((r) => (
                              <span key={r} className="rounded bg-muted px-1.5 py-0.5 text-micro text-ink-soft">
                                {r === "app" ? "يقرأها التطبيق" : "يقرأها الخادم"}
                              </span>
                            ))}
                            <span className="text-micro text-ink-faint">النوع: {valueTypeLabel(flag.value_type)}</span>
                            {isRetiredFlag(flag.key) && <StatusBadge label="غير مستخدمة في التطبيق" tone="neutral" />}
                            {dirty && <StatusBadge label="تغييرات غير محفوظة" tone="warning" />}
                          </div>
                          <p className="mt-1.5 text-sm text-ink-soft">
                            {flagDescription(flag.key, flag.description) ?? "لا يوجد وصف لهذه الميزة."}
                          </p>
                          {m && <p className="mt-1 text-tiny text-ink-faint">{m.notes}</p>}
                          {m?.status === "not_wired" && (
                            <p className="mt-1 text-tiny font-medium text-ink-faint">
                              لا تأثير — لا قارئ لهذا المفتاح، تغييره لن يؤثر على أي سلوك. التعديل معطّل إلا للوصف.
                            </p>
                          )}
                          {m?.dependencies?.map((x) => (
                            <p key={x} className="mt-1 text-tiny text-warning">{x}</p>
                          ))}
                          <p className="mt-1 text-micro text-ink-faint">
                            الإطلاق: {ROLLOUT_TEXT[m?.rolloutSemantics ?? "none"]}
                          </p>
                        </div>
                        <Toggle
                          checked={isActive}
                          disabled={!fields.includes("is_active")}
                          onChange={() => setDraft(flag.key, { is_active: !isActive })}
                          label={isActive ? `إيقاف ${flag.key}` : `تفعيل ${flag.key}`}
                        />
                      </div>

                      {editable && (
                        <div className="mt-4 grid gap-4 border-t border-divider pt-4 md:grid-cols-3">
                          <label className="block text-tiny font-medium text-ink">
                            القيمة
                            <input
                              value={(d.value as string | undefined) ?? flag.value}
                              disabled={!fields.includes("value")}
                              onChange={(e) => setDraft(flag.key, { value: e.target.value })}
                              className="ltr mt-1.5 w-full rounded-field border border-line bg-surface px-3 py-2 font-mono text-tiny"
                            />
                          </label>
                          <label className="block text-tiny font-medium text-ink">
                            نسبة الإطلاق: <span className="tnum">{fmt((d.rollout_percent as number | undefined) ?? flag.rollout_percent)}%</span>
                            <input
                              type="range"
                              min={0}
                              max={100}
                              step={m?.rolloutSemantics === "server_all_or_nothing" ? 100 : 1}
                              value={(d.rollout_percent as number | undefined) ?? flag.rollout_percent}
                              disabled={!fields.includes("rollout_percent")}
                              onChange={(e) => setDraft(flag.key, { rollout_percent: Number(e.target.value) })}
                              className="mt-1.5 w-full accent-brand-700"
                            />
                          </label>
                          <label className="block text-tiny font-medium text-ink">
                            الدول المستهدفة
                            <input
                              value={countryText[flag.key] ?? (flag.target_countries ?? []).join(", ")}
                              disabled={!fields.includes("target_countries")}
                              placeholder={fields.includes("target_countries") ? "EG, SA" : "غير مدعوم لهذا المفتاح"}
                              onChange={(e) => setCountryText((t) => ({ ...t, [flag.key]: e.target.value }))}
                              className="ltr mt-1.5 w-full rounded-field border border-line bg-surface px-3 py-2 font-mono text-tiny"
                            />
                          </label>
                        </div>
                      )}

                      <div className="mt-3 flex flex-wrap items-center justify-between gap-2 text-micro text-ink-faint">
                        <span>
                          آخر تحديث: <span className="ltr">{flag.updated_at}</span> — بواسطة <span className="ltr font-mono">{short(lastActor)}</span>
                        </span>
                        <div className="flex items-center gap-2">
                          <Button size="sm" variant="ghost" icon={History} onClick={() => setHistoryOpen(historyOpen === flag.key ? null : flag.key)}>
                            السجل
                          </Button>
                          {dirty && (
                            <>
                              <Button size="sm" variant="ghost" onClick={() => { setDrafts((x) => { const n = { ...x }; delete n[flag.key]; return n; }); setCountryText((x) => { const n = { ...x }; delete n[flag.key]; return n; }); }}>
                                تراجع
                              </Button>
                              <Button size="sm" onClick={() => reviewFlag(flag)}>معاينة التغييرات</Button>
                            </>
                          )}
                          <CopyId value={flag.key} label="مفتاح الميزة" length={40} />
                        </div>
                      </div>

                      {historyOpen === flag.key && (
                        <div className="mt-3 rounded-field bg-muted p-3 text-tiny">
                          {history.length === 0 ? (
                            <span className="text-ink-faint">{auditAvailable ? "لا تغييرات مسجَّلة." : "السجل غير متاح."}</span>
                          ) : (
                            <ul className="space-y-1.5">
                              {history.map((h, i) => (
                                <li key={`${h.operation_id}-${h.field}-${i}`}>
                                  <span className="ltr text-ink-faint">{h.created_at}</span> — {FIELD_LABEL[h.field] ?? h.field}:{" "}
                                  <code className="ltr">{show(h.old_value)}</code> ← <code className="ltr">{show(h.new_value)}</code> — «{h.reason}» (<span className="ltr font-mono">{short(h.actor_admin_id)}</span>)
                                </li>
                              ))}
                            </ul>
                          )}
                        </div>
                      )}
                    </Card>
                  );
                })}
              </section>
            ))
          )}
        </>
      )}

      {modal && (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-brand-deep/45 p-4 backdrop-blur-sm" role="dialog" aria-modal="true">
          <div className="max-h-[90vh] w-full max-w-xl overflow-auto rounded-card border border-hairline bg-surface p-6 shadow-pop">
            <h2 className="text-lg font-semibold text-ink">{modal.title}</h2>
            {modal.busy && !modal.preview && <p className="mt-3 text-sm text-ink-soft">جارٍ المعاينة…</p>}
            {modal.preview && (
              <div className="mt-3 space-y-3 text-sm">
                {modal.preview.errors.map((e, i) => (
                  <Banner key={i} tone="danger">{errText(e)}</Banner>
                ))}
                {modal.preview.warnings.map((w, i) => (
                  <HelpNote key={i} tone="warning">{w.key}: {w.detail}</HelpNote>
                ))}
                {modal.preview.diffs.length > 0 && (
                  <table className="w-full text-tiny">
                    <thead>
                      <tr className="text-ink-faint"><th className="text-start">المفتاح</th><th className="text-start">الحقل</th><th className="text-start">قبل</th><th className="text-start">بعد</th></tr>
                    </thead>
                    <tbody>
                      {modal.preview.diffs.map((x, i) => (
                        <tr key={i} className="border-t border-divider">
                          <td className="ltr py-1 font-mono">{x.key}</td>
                          <td>{FIELD_LABEL[x.field] ?? x.field}</td>
                          <td className="ltr font-mono">{show(x.old)}</td>
                          <td className="ltr font-mono">{show(x.new)}</td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                )}
                {modal.preview.ok && (
                  <>
                    <label className="block text-tiny font-medium text-ink">
                      سبب التغيير (إلزامي، 4 إلى 500 حرفًا)
                      <textarea
                        value={modal.reason}
                        onChange={(e) => setModal({ ...modal, reason: e.target.value })}
                        rows={2}
                        className="mt-1.5 w-full rounded-field border border-line bg-surface px-3 py-2 text-sm"
                      />
                    </label>
                    {modalHigh && requiresTypedConfirmation(modalHigh) && (
                      <label className="block text-tiny font-medium text-ink">
                        خطورة عالية — اكتب اسم المفتاح للتأكيد:{" "}
                        <code className="ltr rounded bg-muted px-1.5 py-0.5 font-mono">{modalHigh}</code>
                        <input
                          value={modal.typed}
                          onChange={(e) => setModal({ ...modal, typed: e.target.value })}
                          className="ltr mt-1.5 w-full rounded-field border border-line bg-surface px-3 py-2 font-mono text-tiny"
                        />
                      </label>
                    )}
                  </>
                )}
              </div>
            )}
            {modal.error && <div className="mt-3"><Banner tone="danger">{modal.error}</Banner></div>}
            <div className="mt-5 flex justify-end gap-2.5">
              {modal.stale && <Button variant="secondary" onClick={() => { setModal(null); void load(); }}>تحديث الصفحة</Button>}
              <Button variant="secondary" onClick={() => setModal(null)} disabled={modal.busy}>إلغاء</Button>
              <Button onClick={apply} loading={modal.busy && !!modal.preview} disabled={!canConfirm}>تأكيد وتطبيق</Button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}
