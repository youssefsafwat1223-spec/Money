"use client";

// Referral & Ads admin (Phase R2). Reuses the existing admin architecture: every
// read is a service-role select behind requireAdmin(); every mutation posts to a
// route that calls an approved 0083 RPC wrapper. This page never talks to the
// database directly. operation_id is minted once per operator intent (at confirm)
// and resent unchanged on retry so a double-click or proxy retry cannot double-apply.
//
// The 2026 redesign is presentation-only: Arabic-first copy, the shared Admin
// component system, and consequence-focused confirmation before every mutation.
// The intent state machine, the payloads, the URLs and the outcome classification
// below are unchanged.

import { useCallback, useEffect, useRef, useState } from "react";
import {
  AlertTriangle,
  Gift,
  History,
  KeyRound,
  Search,
  ShieldCheck,
  Sparkles,
  UserSearch,
} from "lucide-react";
import { createOperationIntent, operationIntentKey, outcomeKnown } from "@/lib/operation-intent.mjs";
import {
  Banner,
  Card,
  EmptyState,
  HelpNote,
  LoadingState,
  PageHeader,
  SectionHeader,
  StatCard,
  StatusBadge,
} from "@/components/ui/primitives";
import { Button, CheckboxField, SelectField, TextAreaField, TextField } from "@/components/ui/form";
import { ConfirmDialog, type ConfirmSpec } from "@/components/ui/confirm-dialog";
import { CopyId } from "@/components/ui/copy-id";
import {
  attributionLabel,
  auditActionLabel,
  cycleStateLabel,
  entitlementStatusLabel,
  entitlementTypeLabel,
  referralStatusLabel,
  referralStatusTone,
} from "@/lib/labels";
import { fmt, fmtDate as fmtDateLong, fmtPercent } from "@/lib/utils";

// ── types (inline, per admin convention) ────────────────────────────────────
type Rule = {
  id: string;
  version: number;
  reward_type: string;
  required_referrals: number;
  reward_days: number;
  repeatable: boolean;
  is_active: boolean;
  effective_from: string;
  effective_until: string | null;
};
type Progress = {
  reward_type: string;
  pinned_rule_version: number | null;
  cycle_index: number;
  qualified_in_cycle: number;
  cycle_state: string;
};
type LookupCard = {
  user_id: string;
  code: string | null;
  code_status: string | null;
  progress: Progress[];
  active_entitlement: boolean;
};
type Detail = {
  user_id: string;
  code: { code: string; status: string; created_at: string; rotated_at: string | null } | null;
  progress: Array<Progress & { pinned_rule_id: string | null; updated_at: string }>;
  referrals: Array<{
    id: string;
    referred_user: string | null;
    attribution_method: string;
    status: string;
    rejection_reason: string | null;
    created_at: string;
    qualified_at: string | null;
  }>;
  grants: Array<{
    id: string;
    rule_version: number;
    cycle_index: number;
    reward_type: string;
    reward_days_granted: number;
    resulting_ends_at: string | null;
    created_at: string;
  }>;
  entitlement: Array<{
    entitlement_type: string;
    status: string;
    starts_at: string;
    ends_at: string | null;
    updated_at: string;
  }>;
};
type Metrics = {
  referrals: { attributed: number; qualified: number; rejected: number; reversed: number };
  rewards_granted: number;
  active_entitlements: number;
  active_rules: number;
  qualified_ratio: number;
};
type AuditRow = {
  id: string;
  actor_admin_id: string | null;
  action: string;
  target_user_id: string | null;
  target_ref: string | null;
  operation_id: string;
  reason: string;
  before_state: Record<string, unknown> | null;
  after_state: Record<string, unknown> | null;
  created_at: string;
};
type FlagRow = { key: string; is_active: boolean; rollout_percent: number | null };

const REWARD_TYPE = "report_export_ad_free";

// ── shared fetch helper: returns {ok, json} and surfaces safeErrorBody.message ─
// Audit H-13: the outcome classification is what makes safe retry possible.
//   * transportError (fetch threw) or status >= 500 → the mutation MAY have
//     committed; the outcome is UNKNOWN, so the SAME operation_id must be
//     resent on retry.
//   * status 2xx or 4xx → the server processed the request (applied, or
//     definitively rejected); the intent is RESOLVED.
async function api(
  url: string,
  init?: RequestInit,
): Promise<{ ok: boolean; status: number; json: any; transportError: boolean }> {
  try {
    const res = await fetch(url, init);
    const json = await res.json().catch(() => ({}));
    return { ok: res.ok, status: res.status, json, transportError: false };
  } catch {
    // Network drop / connection reset — the response was lost. The server may
    // already have committed, so we must NOT treat this as "did not happen".
    return { ok: false, status: 0, json: {}, transportError: true };
  }
}

const OPERATION_INTENT_STORAGE_KEY = "money.admin.referrals.operation-intents.v1";

/** Audit H-13 — thin React wrapper over the pure operation-intent state
 *  machine (see lib/operation-intent.mjs). The ref preserves rerender
 *  stability; the bounded sessionStorage registry additionally preserves an
 *  unresolved intent across a page remount/reload in this browser tab. */
function useOperationIntent() {
  const ref = useRef<ReturnType<typeof createOperationIntent> | null>(null);
  if (ref.current === null) {
    ref.current = createOperationIntent({
      storageKey: OPERATION_INTENT_STORAGE_KEY,
      getStorage: () => {
        if (typeof window === "undefined") return null;
        try {
          return window.sessionStorage;
        } catch {
          return null;
        }
      },
    });
  }
  const machine = ref.current;
  return {
    begin: (key: string) => machine.begin(key, () => crypto.randomUUID()),
    resolved: (key: string, id: string) => machine.resolved(key, id),
  };
}

function errText(json: any, fallback: string): string {
  if (json?.message) return json.message;
  if (Array.isArray(json?.fields) && json.fields.length) {
    return json.fields.map((f: any) => `${f.field}: ${f.message ?? f.error}`).join("؛ ");
  }
  return json?.error ?? fallback;
}

export default function ReferralsPage() {
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const flash = useCallback((ok: string | null, err: string | null) => {
    setNotice(ok);
    setError(err);
  }, []);

  return (
    <div className="space-y-6">
      <PageHeader
        eyebrow="النمو والمكافآت"
        title="الدعوات والمكافآت"
        description="قاعدة احتساب الدعوات، منح المكافآت وسحبها، مراجعة الدعوات المشبوهة، وسجل كل عملية إدارية."
      />

      {error && (
        <Banner tone="danger" onDismiss={() => setError(null)}>
          {error}
        </Banner>
      )}
      {notice && (
        <Banner tone="success" onDismiss={() => setNotice(null)}>
          {notice}
        </Banner>
      )}

      <MetricsSection flash={flash} />
      <RulesSection flash={flash} />
      <LookupSection flash={flash} />
      <ReportAdsSection flash={flash} />
      <AuditSection flash={flash} />
    </div>
  );
}

type Flash = (ok: string | null, err: string | null) => void;

// ── 1. Metrics (spec §10) ────────────────────────────────────────────────────
function MetricsSection({ flash }: { flash: Flash }) {
  const [m, setM] = useState<Metrics | null>(null);
  useEffect(() => {
    void (async () => {
      const { ok, json } = await api("/api/referral-metrics");
      if (!ok) return flash(null, errText(json, "تعذّر تحميل الأرقام"));
      setM(json as Metrics);
    })();
  }, [flash]);

  return (
    <section className="space-y-3">
      <div>
        <h2 className="text-lg font-semibold text-ink">أرقام الدعوات</h2>
        <p className="mt-1 text-sm text-ink-soft">
          مؤشرات على أداء برنامج الدعوة. هذه ليست أرقامًا محاسبية ولا تخص إيرادات الإعلانات.
        </p>
      </div>

      {!m ? (
        <LoadingState label="جارٍ تحميل الأرقام…" />
      ) : (
        <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
          <StatCard
            label="دعوات مُسجَّلة"
            value={fmt(m.referrals.attributed)}
            hint="نُسبت إلى صاحب الكود ولم تُحتسب بعد"
            icon={Gift}
            tone="info"
          />
          <StatCard
            label="دعوات مُحتسَبة"
            value={fmt(m.referrals.qualified)}
            hint="استوفت الشروط وتُحسب ضمن الدورة"
            icon={ShieldCheck}
            tone="success"
          />
          <StatCard
            label="دعوات مرفوضة"
            value={fmt(m.referrals.rejected)}
            hint="رُفضت قبل احتسابها"
            icon={AlertTriangle}
            tone="danger"
          />
          <StatCard
            label="دعوات أُلغي احتسابها"
            value={fmt(m.referrals.reversed)}
            hint="كانت مُحتسَبة ثم أُلغيت بعد المراجعة"
            icon={History}
            tone="warning"
          />
          <StatCard
            label="مكافآت مُنِحت"
            value={fmt(m.rewards_granted)}
            hint="إجمالي مرات منح المكافأة"
            icon={Sparkles}
            tone="brand"
          />
          <StatCard
            label="مستخدمون بلا إعلانات الآن"
            value={fmt(m.active_entitlements)}
            hint="ميزة سارية في هذه اللحظة"
            icon={ShieldCheck}
            tone="success"
          />
          <StatCard
            label="قواعد سارية"
            value={fmt(m.active_rules)}
            hint="القاعدة التي تُحتسب عليها الدعوات الجديدة"
            icon={KeyRound}
            tone="neutral"
          />
          <StatCard
            label="نسبة الاحتساب"
            value={fmtPercent(m.qualified_ratio)}
            hint="المُحتسَبة من إجمالي المُسجَّلة"
            icon={Sparkles}
            tone="neutral"
          />
        </div>
      )}
    </section>
  );
}

// ── 2. Referral rules (spec §4) ──────────────────────────────────────────────
function RulesSection({ flash }: { flash: Flash }) {
  const [rules, setRules] = useState<Rule[]>([]);
  const [required, setRequired] = useState("5");
  const [days, setDays] = useState("7");
  const [repeatable, setRepeatable] = useState(true);
  const [reason, setReason] = useState("");
  const [busy, setBusy] = useState(false);
  const [confirm, setConfirm] = useState<(ConfirmSpec & { run: () => Promise<void> }) | null>(null);
  const publishIntent = useOperationIntent();
  const deactivateIntent = useOperationIntent();

  const load = useCallback(async () => {
    const { ok, json } = await api("/api/referral-rules");
    if (!ok) return flash(null, errText(json, "تعذّر تحميل القواعد"));
    setRules((json.rules ?? []) as Rule[]);
  }, [flash]);
  useEffect(() => {
    void load();
  }, [load]);

  const active = rules.find((r) => r.is_active) ?? null;

  async function publish() {
    setBusy(true);
    // Audit H-13: one id per publish INTENT, reused across retries; a changed
    // payload is a new intent (new id). Regenerating per click created V+1, V+2.
    const payload = {
      reward_type: REWARD_TYPE,
      required_referrals: Number(required),
      reward_days: Number(days),
      repeatable,
      reason,
    };
    const intentKey = operationIntentKey("publish", payload);
    const operation_id = publishIntent.begin(intentKey);
    const r = await api("/api/referral-rules", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        operation_id,
        ...payload,
      }),
    });
    setBusy(false);
    setConfirm(null);
    if (!outcomeKnown(r)) {
      return flash(
        null,
        "حدثت مشكلة في الاتصال — قد تكون القاعدة نُشرت وقد لا تكون. اضغط «نشر» مرة أخرى؛ إعادة المحاولة آمنة ولن تُنشئ نسخة مكرّرة.",
      );
    }
    publishIntent.resolved(intentKey, operation_id);
    if (!r.ok) return flash(null, errText(r.json, "تعذّر نشر القاعدة"));
    setReason("");
    flash("تم نشر نسخة جديدة من القاعدة.", null);
    await load();
  }

  async function deactivate() {
    setBusy(true);
    const payload = { reward_type: REWARD_TYPE, reason };
    const intentKey = operationIntentKey("deactivate", payload);
    const operation_id = deactivateIntent.begin(intentKey);
    const r = await api("/api/referral-rules", {
      method: "PATCH",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ operation_id, ...payload }),
    });
    setBusy(false);
    setConfirm(null);
    if (!outcomeKnown(r)) {
      return flash(
        null,
        "حدثت مشكلة في الاتصال — قد تكون القاعدة أُوقفت وقد لا تكون. اضغط «إيقاف القاعدة» مرة أخرى؛ إعادة المحاولة آمنة.",
      );
    }
    deactivateIntent.resolved(intentKey, operation_id);
    if (!r.ok) return flash(null, errText(r.json, "تعذّر إيقاف القاعدة"));
    setReason("");
    flash("تم إيقاف القاعدة السارية.", null);
    await load();
  }

  function askPublish() {
    if (!reason.trim()) return flash(null, "اكتب سبب النشر أولًا (4 أحرف على الأقل).");
    setConfirm({
      title: "نشر نسخة جديدة من قاعدة الدعوة؟",
      confirmLabel: "نشر النسخة الجديدة",
      tone: "brand",
      consequence: (
        <>
          ستصبح القاعدة الجديدة: <strong className="text-ink">{fmt(Number(required))} دعوة مقابل {fmt(Number(days))} يومًا</strong>
          {repeatable ? " قابلة للتكرار" : " مرة واحدة فقط"}.
          <br />
          المستخدم الذي بدأ دورة بالفعل يكمل دورته على القاعدة القديمة، وتنطبق الجديدة من دورته
          التالية. <strong className="text-ink">المكافآت التي مُنحت سابقًا لا يُعاد حسابها إطلاقًا.</strong>
        </>
      ),
      run: publish,
    });
  }

  function askDeactivate() {
    if (!reason.trim()) return flash(null, "اكتب سبب الإيقاف أولًا (4 أحرف على الأقل).");
    setConfirm({
      title: "إيقاف القاعدة السارية؟",
      confirmLabel: "إيقاف القاعدة",
      tone: "danger",
      consequence: (
        <>
          لن تُحتسب أي دعوات جديدة بعد الإيقاف. الدورات الجارية تُكمل على قاعدتها المثبَّتة، ولا
          تبدأ أي دورة جديدة حتى تُنشر قاعدة سارية مرة أخرى.
          <br />
          <strong className="text-ink">المكافآت القائمة تبقى كما هي ولا تُسحب.</strong>
        </>
      ),
      run: deactivate,
    });
  }

  return (
    <Card>
      <SectionHeader
        title="قاعدة الدعوة"
        description="عدد الدعوات المطلوبة ومدة المكافأة إعداد قابل للتغيير — وليس رقمًا ثابتًا داخل التطبيق."
        icon={KeyRound}
      />

      {active && (
        <div className="mb-5 rounded-field border border-hairline bg-raised/50 p-4">
          <p className="mb-1 text-tiny font-medium text-ink-faint">القاعدة السارية الآن</p>
          <p className="tnum text-sm text-ink">
            <strong>{fmt(active.required_referrals)}</strong> دعوة مُحتسَبة تمنح{" "}
            <strong>{fmt(active.reward_days)}</strong> يومًا بدون إعلانات ·{" "}
            {active.repeatable ? "قابلة للتكرار كل دورة" : "مرة واحدة لكل مستخدم"} · النسخة رقم{" "}
            {fmt(active.version)}
          </p>
        </div>
      )}

      <div className="grid gap-4 md:grid-cols-3">
        <TextField
          label="عدد الدعوات المطلوبة"
          type="number"
          value={required}
          onChange={(e) => setRequired(e.target.value)}
          hint="كم دعوة مُحتسَبة يحتاجها المستخدم ليحصل على المكافأة."
        />
        <TextField
          label="مدة المكافأة بالأيام"
          type="number"
          value={days}
          onChange={(e) => setDays(e.target.value)}
          hint="عدد الأيام التي يصدّر فيها المستخدم تقاريره بدون إعلان."
        />
        <div className="flex items-end pb-2">
          <CheckboxField
            label="قابلة للتكرار"
            hint="عند التفعيل يبدأ المستخدم دورة جديدة بعد كل مكافأة."
            checked={repeatable}
            onChange={setRepeatable}
          />
        </div>
      </div>

      <TextAreaField
        label="سبب التغيير"
        required
        rows={2}
        maxLength={500}
        value={reason}
        onChange={(e) => setReason(e.target.value)}
        className="mt-4"
        hint="من 4 إلى 500 حرف. يُحفظ في سجل العمليات ولا يمكن تعديله لاحقًا."
      />

      <HelpNote tone="warning" className="mt-4">
        تغيير القاعدة يُنشئ نسخة جديدة منها ولا يعدّل النسخة القديمة. المستخدم الذي بدأ دورته يكمل
        على قاعدته المثبَّتة، وتنطبق الجديدة من دورته التالية. المكافآت المُنحَت سابقًا لا يُعاد حسابها.
      </HelpNote>

      <div className="mt-4 flex flex-wrap gap-2.5">
        <Button onClick={askPublish} disabled={busy}>
          نشر نسخة جديدة
        </Button>
        <Button variant="danger" onClick={askDeactivate} disabled={busy || !active}>
          إيقاف القاعدة السارية
        </Button>
      </div>

      <div className="mt-6">
        <h3 className="mb-2.5 text-tiny font-semibold tracking-wide text-ink-faint">
          نسخ القاعدة ({fmt(rules.length)})
        </h3>
        {rules.length === 0 ? (
          <p className="text-sm text-ink-faint">لا توجد قواعد منشورة بعد.</p>
        ) : (
          <div className="space-y-2">
            {rules.map((r) => (
              <div
                key={r.id}
                className="flex flex-wrap items-center gap-3 rounded-field border border-hairline bg-surface px-4 py-3 text-sm"
              >
                <StatusBadge
                  label={r.is_active ? "سارية" : "قديمة"}
                  tone={r.is_active ? "success" : "neutral"}
                />
                <span className="tnum text-ink-faint">النسخة {fmt(r.version)}</span>
                <span className="tnum text-ink">
                  {fmt(r.required_referrals)} دعوة ← {fmt(r.reward_days)} يومًا
                </span>
                <span className="text-ink-soft">
                  {r.repeatable ? "قابلة للتكرار" : "مرة واحدة"}
                </span>
                <span className="text-micro text-ink-faint">
                  {entitlementTypeLabel(r.reward_type)}
                </span>
              </div>
            ))}
          </div>
        )}
      </div>

      <ConfirmDialog
        spec={confirm}
        busy={busy}
        onCancel={() => setConfirm(null)}
        onConfirm={() => void confirm?.run()}
      />
    </Card>
  );
}

// ── 3+4+5+6. User lookup → detail → manual actions + fraud review ─────────────
function LookupSection({ flash }: { flash: Flash }) {
  const [query, setQuery] = useState("");
  const [results, setResults] = useState<LookupCard[]>([]);
  const [searched, setSearched] = useState(false);
  const [detail, setDetail] = useState<Detail | null>(null);
  const [busy, setBusy] = useState(false);

  async function search() {
    setBusy(true);
    setDetail(null);
    const { ok, json } = await api(`/api/referral-users?query=${encodeURIComponent(query)}`);
    setBusy(false);
    setSearched(true);
    if (!ok) return flash(null, errText(json, "تعذّر تنفيذ البحث"));
    setResults((json.results ?? []) as LookupCard[]);
    if (json.truncated)
      flash(null, "لم يُعثر على بريد مطابق ضمن النطاق الذي جرى فحصه. جرّب معرّف المستخدم أو كود الدعوة.");
  }

  const openDetail = useCallback(
    async (userId: string) => {
      const { ok, json } = await api(`/api/referral-users/${encodeURIComponent(userId)}`);
      if (!ok) return flash(null, errText(json, "تعذّر تحميل تفاصيل المستخدم"));
      setDetail(json as Detail);
    },
    [flash],
  );

  return (
    <Card>
      <SectionHeader
        title="البحث عن مستخدم"
        description="ابحث بمعرّف المستخدم أو كود الدعوة أو البريد الإلكتروني. لا تُعرض هنا أي بيانات مالية."
        icon={UserSearch}
      />

      <div className="flex flex-wrap gap-2.5">
        <div className="relative min-w-[260px] flex-1">
          <Search
            size={15}
            className="pointer-events-none absolute inset-y-0 start-3 my-auto text-ink-faint"
          />
          <input
            className="ltr w-full rounded-field border border-line bg-surface py-2.5 pe-3 ps-9 text-sm text-ink placeholder:text-ink-faint focus:border-brand-500 focus:outline-none focus:ring-2 focus:ring-brand-500/25"
            placeholder="user_id · CODE · email@example.com"
            aria-label="نص البحث"
            value={query}
            onChange={(e) => setQuery(e.target.value)}
            onKeyDown={(e) => e.key === "Enter" && void search()}
          />
        </div>
        <Button onClick={search} loading={busy} disabled={!query.trim()}>
          بحث
        </Button>
      </div>

      <div className="mt-4">
        {!searched ? (
          <p className="text-sm text-ink-faint">اكتب ما تبحث عنه ثم اضغط «بحث».</p>
        ) : results.length === 0 ? (
          <EmptyState
            icon={UserSearch}
            title="لا توجد نتائج"
            description="تأكد من صحة المعرّف أو الكود أو البريد الإلكتروني ثم أعد المحاولة."
          />
        ) : (
          <div className="space-y-2">
            {results.map((r) => (
              <button
                key={r.user_id}
                onClick={() => void openDetail(r.user_id)}
                className="flex w-full flex-wrap items-center gap-3 rounded-field border border-hairline bg-surface px-4 py-3 text-start text-sm transition-colors hover:border-brand-300 hover:bg-brand-50"
              >
                <span className="ltr rounded bg-muted px-1.5 py-0.5 font-mono text-micro text-ink-soft">
                  {shortId(r.user_id)}
                </span>
                <span className="ltr font-medium text-ink">{r.code ?? "بلا كود"}</span>
                {r.active_entitlement && <StatusBadge label="بدون إعلانات" tone="success" />}
                {r.progress.map((p) => (
                  <span key={p.reward_type} className="tnum text-micro text-ink-faint">
                    {fmt(p.qualified_in_cycle)} دعوة في الدورة {fmt(p.cycle_index)} (النسخة{" "}
                    {p.pinned_rule_version ?? "—"})
                  </span>
                ))}
              </button>
            ))}
          </div>
        )}
      </div>

      {detail && (
        <DetailPanel detail={detail} flash={flash} onChanged={() => void openDetail(detail.user_id)} />
      )}
    </Card>
  );
}

function DetailPanel({ detail, flash, onChanged }: { detail: Detail; flash: Flash; onChanged: () => void }) {
  return (
    <div className="mt-6 space-y-6 rounded-card border border-hairline bg-raised/40 p-5">
      <div className="flex flex-wrap items-center gap-3">
        <h3 className="text-sm font-semibold text-ink">تفاصيل المستخدم</h3>
        <CopyId value={detail.user_id} label="معرّف المستخدم" length={12} />
        <span className="ltr text-sm text-ink-soft">{detail.code?.code ?? "بلا كود"}</span>
        {detail.code?.status && (
          <StatusBadge
            label={detail.code.status === "active" ? "الكود فعّال" : "الكود موقوف"}
            tone={detail.code.status === "active" ? "success" : "neutral"}
          />
        )}
      </div>

      {/* current cycle + pinned rule (§6) */}
      <div>
        <h4 className="mb-2 text-tiny font-semibold tracking-wide text-ink-faint">الدورة الحالية</h4>
        {detail.progress.length === 0 ? (
          <p className="text-sm text-ink-faint">لم يبدأ هذا المستخدم أي دورة دعوات بعد.</p>
        ) : (
          detail.progress.map((p) => (
            <p key={p.reward_type} className="tnum text-sm text-ink-soft">
              {fmt(p.qualified_in_cycle)} دعوة مُحتسَبة · الدورة رقم {fmt(p.cycle_index)} · مثبَّتة على
              النسخة {p.pinned_rule_version ?? "—"} · {cycleStateLabel(p.cycle_state)}
            </p>
          ))
        )}
      </div>

      {/* current entitlement (§6) */}
      <div>
        <h4 className="mb-2 text-tiny font-semibold tracking-wide text-ink-faint">الميزة الحالية</h4>
        {detail.entitlement.length === 0 ? (
          <p className="text-sm text-ink-faint">لا توجد ميزة مفعّلة لهذا المستخدم.</p>
        ) : (
          detail.entitlement.map((e) => (
            <p key={e.entitlement_type} className="text-sm text-ink-soft">
              {entitlementTypeLabel(e.entitlement_type)} · {entitlementStatusLabel(e.status)} · تنتهي{" "}
              {fmtDateLong(e.ends_at)}
            </p>
          ))
        )}
      </div>

      {/* grant history from the immutable ledger (§6) */}
      <div>
        <h4 className="mb-2 text-tiny font-semibold tracking-wide text-ink-faint">
          سجل المكافآت (لا يُعدَّل)
        </h4>
        {detail.grants.length === 0 ? (
          <p className="text-sm text-ink-faint">لم يحصل هذا المستخدم على أي مكافأة بعد.</p>
        ) : (
          <div className="tnum space-y-1 text-sm text-ink-soft">
            {detail.grants.map((g) => (
              <p key={g.id}>
                النسخة {fmt(g.rule_version)} · الدورة {fmt(g.cycle_index)} ·{" "}
                {fmt(g.reward_days_granted)} يومًا ← تنتهي {fmtDateLong(g.resulting_ends_at)} · مُنحت
                في {fmtDateLong(g.created_at)}
              </p>
            ))}
          </div>
        )}
      </div>

      {/* referrals list — short ids only, "deleted user" for de-identified rows (§6) */}
      <div>
        <h4 className="mb-2 text-tiny font-semibold tracking-wide text-ink-faint">الدعوات التي أرسلها</h4>
        {detail.referrals.length === 0 ? (
          <p className="text-sm text-ink-faint">لا توجد دعوات.</p>
        ) : (
          <div className="space-y-2">
            {detail.referrals.map((r) => (
              <div
                key={r.id}
                className="flex flex-wrap items-center gap-3 rounded-field border border-hairline bg-surface px-3.5 py-2.5 text-sm"
              >
                <span className="ltr rounded bg-muted px-1.5 py-0.5 font-mono text-micro text-ink-soft">
                  {r.referred_user === "deleted user"
                    ? "حساب محذوف"
                    : r.referred_user
                      ? shortId(r.referred_user)
                      : "—"}
                </span>
                <span className="text-ink-soft">{attributionLabel(r.attribution_method)}</span>
                <StatusBadge
                  label={referralStatusLabel(r.status)}
                  tone={referralStatusTone(r.status)}
                />
                {r.qualified_at && (
                  <span className="text-micro text-ink-faint">
                    احتُسبت {fmtDateLong(r.qualified_at)}
                  </span>
                )}
                {r.rejection_reason && (
                  <span className="text-micro text-danger">{r.rejection_reason}</span>
                )}
                {r.status === "attributed" && (
                  <ReferralAction kind="reject" referralId={r.id} flash={flash} onDone={onChanged} />
                )}
                {r.status === "qualified" && (
                  <ReferralAction kind="reverse" referralId={r.id} flash={flash} onDone={onChanged} />
                )}
              </div>
            ))}
          </div>
        )}
      </div>

      {/* manual actions (§7) */}
      <ManualActions userId={detail.user_id} flash={flash} onDone={onChanged} />
    </div>
  );
}

// ── manual entitlement / progress / code actions (§7) ────────────────────────

/** What each manual action actually does, in the operator's words. */
const ACTION_OPTIONS = [
  { value: "grant", label: "منح ميزة «بدون إعلانات»" },
  { value: "extend", label: "تمديد مدة الميزة" },
  { value: "shorten", label: "تقصير مدة الميزة" },
  { value: "revoke", label: "سحب الميزة" },
  { value: "adjust_progress", label: "تعديل عدد الدعوات المُحتسَبة" },
  { value: "rotate_code", label: "تدوير كود الدعوة" },
];

const ACTION_HINT: Record<string, string> = {
  grant: "يمنح المستخدم تصدير التقارير بدون ظهور إعلان، لعدد الأيام الذي تحدّده.",
  extend: "يضيف الأيام المحدّدة إلى نهاية المدة الحالية للميزة.",
  shorten: "يقصّر نهاية المدة الحالية. الأيام التي استُهلكت فعلًا لا تُسترجع.",
  revoke: "يوقف الميزة فورًا. المستخدم ستظهر له الإعلانات من جديد.",
  adjust_progress: "يضبط عدد الدعوات المُحتسَبة في الدورة الحالية على الرقم الذي تكتبه.",
  rotate_code: "ينشئ كود دعوة جديدًا ويوقف استخدام الكود الحالي. الروابط القديمة تتوقف عن العمل.",
};

function ManualActions({ userId, flash, onDone }: { userId: string; flash: Flash; onDone: () => void }) {
  const [action, setAction] = useState("grant");
  const [days, setDays] = useState("7");
  const [progress, setProgress] = useState("0");
  const [reason, setReason] = useState("");
  const [busy, setBusy] = useState(false);
  const [confirm, setConfirm] = useState<ConfirmSpec | null>(null);
  const intent = useOperationIntent();

  const needsDays = action === "grant" || action === "extend" || action === "shorten";
  const isProgress = action === "adjust_progress";
  const isRotate = action === "rotate_code";

  async function run() {
    setBusy(true);
    // Audit H-13: one operation_id per intent, reused on retry. The intent key
    // includes EVERY field that defines the action, so changing the action,
    // target, days, progress, or reason begins a new intent (new id) — while a
    // pure network retry of the unchanged action reuses the id and the server
    // (referral_admin_claim / apply_entitlement_mutation) no-ops the duplicate.
    let url = "";
    let payload: Record<string, unknown> = { reason };

    if (action === "grant" || action === "extend") {
      url = `/api/entitlements/${action}`;
      payload = { ...payload, user_id: userId, action, duration_days: Number(days) };
    } else if (action === "revoke" || action === "shorten") {
      url = "/api/entitlements/revoke";
      payload = {
        ...payload,
        user_id: userId,
        action,
        ...(action === "shorten" ? { duration_days: Number(days) } : {}),
      };
    } else if (isProgress) {
      url = "/api/referral-progress/adjust";
      payload = {
        ...payload,
        referrer_user_id: userId,
        reward_type: REWARD_TYPE,
        qualified_in_cycle: Number(progress),
      };
    } else if (isRotate) {
      url = "/api/referral-codes/rotate";
      payload = { ...payload, user_id: userId };
    }

    const intentKey = operationIntentKey(action, payload);
    const operation_id = intent.begin(intentKey);
    const r = await api(url, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ operation_id, ...payload }),
    });
    setBusy(false);
    setConfirm(null);
    if (!outcomeKnown(r)) {
      return flash(
        null,
        "حدثت مشكلة في الاتصال — قد يكون الإجراء طُبِّق وقد لا يكون. أكّد الإجراء نفسه مرة أخرى؛ إعادة المحاولة آمنة ولن تُطبِّقه مرتين.",
      );
    }
    intent.resolved(intentKey, operation_id);
    if (!r.ok) return flash(null, errText(r.json, "تعذّر تنفيذ الإجراء"));
    const dup = r.json?.result?.duplicate ? " (كان مطبَّقًا بالفعل)" : "";
    setReason("");
    flash(`تم تنفيذ الإجراء${dup}.`, null);
    onDone();
  }

  function ask() {
    if (!reason.trim()) return flash(null, "اكتب سبب الإجراء أولًا (4 أحرف على الأقل).");
    const label = ACTION_OPTIONS.find((a) => a.value === action)?.label ?? action;
    const destructive = action === "revoke" || action === "shorten" || action === "rotate_code";
    setConfirm({
      title: `تأكيد: ${label}`,
      confirmLabel: "تأكيد الإجراء",
      tone: destructive ? "danger" : "brand",
      consequence: (
        <>
          {ACTION_HINT[action]}
          {needsDays && (
            <>
              <br />
              المدة المحدّدة: <strong className="text-ink">{fmt(Number(days))} يومًا</strong>.
            </>
          )}
          {isProgress && (
            <>
              <br />
              العدد الجديد: <strong className="text-ink">{fmt(Number(progress))}</strong>.
            </>
          )}
          <br />
          <span className="text-tiny">
            يُسجَّل هذا الإجراء باسمك في سجل العمليات مع السبب الذي كتبته، ولا يمكن حذفه.
          </span>
        </>
      ),
    });
  }

  return (
    <div className="rounded-card border border-line bg-surface p-4">
      <SectionHeader
        title="إجراء يدوي"
        description="تدخّل مباشر على ميزة المستخدم أو على عدّاد دعواته. كل إجراء يحتاج سببًا ويُسجَّل."
      />

      <div className="grid gap-4 md:grid-cols-3">
        <SelectField
          label="الإجراء"
          value={action}
          onChange={(e) => setAction(e.target.value)}
          options={ACTION_OPTIONS}
          hint={ACTION_HINT[action]}
        />
        {needsDays && (
          <TextField
            label="عدد الأيام"
            type="number"
            value={days}
            onChange={(e) => setDays(e.target.value)}
          />
        )}
        {isProgress && (
          <TextField
            label="عدد الدعوات المُحتسَبة الجديد"
            type="number"
            value={progress}
            onChange={(e) => setProgress(e.target.value)}
          />
        )}
      </div>

      <TextAreaField
        label="سبب الإجراء"
        required
        rows={2}
        maxLength={500}
        value={reason}
        onChange={(e) => setReason(e.target.value)}
        className="mt-4"
        hint="من 4 إلى 500 حرف. يظهر في سجل العمليات ولا يمكن تعديله لاحقًا."
      />

      <div className="mt-3">
        <Button onClick={ask} disabled={busy}>
          {busy ? "جارٍ التنفيذ…" : "تنفيذ الإجراء"}
        </Button>
      </div>

      {(action === "revoke" || action === "shorten") && (
        <HelpNote tone="warning" className="mt-3">
          سحب الميزة أو تقصير مدتها إجراء إداري منفصل تمامًا عن إلغاء احتساب دعوة بسبب تلاعب. الوقت
          الذي استُهلك فعلًا بدون إعلانات لا يُعاد حسابه في الحالتين.
        </HelpNote>
      )}

      <ConfirmDialog spec={confirm} busy={busy} onCancel={() => setConfirm(null)} onConfirm={run} />
    </div>
  );
}

// reject a pending / reverse a qualified referral (§8)
function ReferralAction({
  kind,
  referralId,
  flash,
  onDone,
}: {
  kind: "reject" | "reverse";
  referralId: string;
  flash: Flash;
  onDone: () => void;
}) {
  const [open, setOpen] = useState(false);
  const [reason, setReason] = useState("");
  const [busy, setBusy] = useState(false);
  const [confirm, setConfirm] = useState<ConfirmSpec | null>(null);
  const intent = useOperationIntent();

  const word = kind === "reject" ? "رفض الدعوة" : "إلغاء احتساب الدعوة";

  async function run() {
    setBusy(true);
    // Audit H-13: one id per reject/reverse intent, reused on retry so a lost
    // response cannot double-apply and corrupt the audit history.
    const payload = { referral_id: referralId, reason };
    const intentKey = operationIntentKey(kind, payload);
    const operation_id = intent.begin(intentKey);
    const url = kind === "reject" ? "/api/referrals/reject" : "/api/referrals/reverse";
    const r = await api(url, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ operation_id, ...payload }),
    });
    setBusy(false);
    setConfirm(null);
    if (!outcomeKnown(r)) {
      return flash(
        null,
        `حدثت مشكلة في الاتصال — قد يكون «${word}» طُبِّق وقد لا يكون. أكّد الإجراء نفسه مرة أخرى؛ إعادة المحاولة آمنة.`,
      );
    }
    intent.resolved(intentKey, operation_id);
    if (!r.ok) return flash(null, errText(r.json, `تعذّر تنفيذ «${word}»`));
    setOpen(false);
    setReason("");
    flash(`تم تنفيذ «${word}».`, null);
    onDone();
  }

  if (!open) {
    return (
      <button
        onClick={() => setOpen(true)}
        className={`rounded-field border px-2.5 py-1 text-micro font-medium transition-colors ${
          kind === "reverse"
            ? "border-danger/25 text-danger hover:bg-danger-bg"
            : "border-warning/30 text-warning hover:bg-warning-bg"
        }`}
      >
        {word}
      </button>
    );
  }

  return (
    <div className="flex w-full flex-wrap items-center gap-2">
      <input
        className="min-w-[200px] flex-1 rounded-field border border-line bg-surface px-2.5 py-1.5 text-micro text-ink"
        placeholder={`سبب ${word} (4 أحرف على الأقل)`}
        aria-label={`سبب ${word}`}
        value={reason}
        onChange={(e) => setReason(e.target.value)}
        maxLength={500}
      />
      <Button
        size="sm"
        variant="danger"
        disabled={busy}
        onClick={() => {
          if (!reason.trim()) return flash(null, "اكتب السبب أولًا (4 أحرف على الأقل).");
          setConfirm({
            title: `تأكيد: ${word}`,
            confirmLabel: "تأكيد",
            tone: "danger",
            consequence:
              kind === "reject" ? (
                <>
                  لن تُحتسب هذه الدعوة ضمن دورة صاحب الكود، ولن تقرّبه من المكافأة.
                  <br />
                  <span className="text-tiny">يُسجَّل الإجراء باسمك مع السبب في سجل العمليات.</span>
                </>
              ) : (
                <>
                  الدعوة كانت مُحتسَبة، وسيُلغى احتسابها وينقص عدّاد دورة صاحب الكود.{" "}
                  <strong className="text-ink">
                    المكافأة التي مُنحت سابقًا لا تُسحب تلقائيًا
                  </strong>{" "}
                  — استخدم «سحب الميزة» إن لزم ذلك.
                </>
              ),
          });
        }}
      >
        تأكيد
      </Button>
      <Button size="sm" variant="secondary" onClick={() => setOpen(false)}>
        إلغاء
      </Button>
      <ConfirmDialog spec={confirm} busy={busy} onCancel={() => setConfirm(null)} onConfirm={run} />
    </div>
  );
}

// ── 7. Report Ads diagnostics (spec §3) — read-only, no config table/route ────
function ReportAdsSection({ flash }: { flash: Flash }) {
  const [flag, setFlag] = useState<FlagRow | null>(null);
  useEffect(() => {
    void (async () => {
      const { ok, json } = await api("/api/admin-data?resource=feature_flags");
      if (!ok) return; // non-fatal; the flags screen owns this
      const rows = (json.data ?? []) as FlagRow[];
      setFlag(rows.find((r) => r.key === "enable_report_ads") ?? null);
    })();
  }, [flash]);

  return (
    <Card>
      <SectionHeader
        title="إعلانات التقارير — عرض فقط"
        description="لا يوجد أي إعداد قابل للتحرير هنا. هذه الشاشة تعرض الحالة الحالية فقط."
      />
      <div className="space-y-2.5 text-sm text-ink-soft">
        <p>
          <span className="font-medium text-ink">حالة الميزة:</span>{" "}
          {flag ? (
            <>
              {flag.is_active ? "مفعّلة" : "متوقفة"}
              {flag.rollout_percent != null ? ` · نسبة الإطلاق ${fmt(flag.rollout_percent)}%` : ""} —
              تُعدَّل من صفحة «إعدادات المزايا».
            </>
          ) : (
            "غير معروفة"
          )}
        </p>
        <p>
          <span className="font-medium text-ink">متى يظهر الإعلان فعليًا؟</span> عندما تتحقق كل هذه
          الشروط معًا: الميزة مفعّلة، وإعدادات النسخة صحيحة، وموافقة المستخدم على الإعلانات قائمة،
          وميزة «بدون إعلانات» غير سارية له، ويوجد إعلان متاح.
        </p>
        <p className="text-ink-faint">
          معرّفات وحدات الإعلان وبيئتها تأتي من إعدادات بناء التطبيق، ولا تُعرض ولا تُعدَّل من هنا.
          السياسة الحالية: فرصة إعلان واحدة لكل عملية تصدير، وفي حال الفشل يكتمل التصدير بدون إعلان.
        </p>
        <HelpNote tone="warning">
          تغيير حالة الميزة لا يسري فورًا: يحتاج الجهاز إلى مزامنة الكتالوج وإعادة تشغيل التطبيق.
          تفعيل استجابة الجهاز داخل الجلسة نفسها شرط لازم قبل تشغيل هذه الميزة على المستخدمين
          الحقيقيين.
        </HelpNote>
      </div>
    </Card>
  );
}

// ── 8. Audit history (spec §9) — append-only, de-identified ──────────────────
function AuditSection({ flash }: { flash: Flash }) {
  const [rows, setRows] = useState<AuditRow[]>([]);
  const [loading, setLoading] = useState(true);
  const [expanded, setExpanded] = useState<string | null>(null);

  useEffect(() => {
    void (async () => {
      const { ok, json } = await api("/api/referral-audit");
      setLoading(false);
      if (!ok) return flash(null, errText(json, "تعذّر تحميل سجل العمليات"));
      setRows((json.audit ?? []) as AuditRow[]);
    })();
  }, [flash]);

  return (
    <Card>
      <SectionHeader
        title="سجل العمليات"
        description="كل إجراء إداري يُضاف إلى هذا السجل ولا يُعدَّل ولا يُحذف. لا يحتوي على بيانات شخصية."
        icon={History}
      />

      {loading ? (
        <LoadingState label="جارٍ تحميل السجل…" />
      ) : rows.length === 0 ? (
        <EmptyState
          icon={History}
          title="لا توجد عمليات مسجّلة"
          description="سيظهر هنا كل إجراء إداري بمجرد تنفيذه."
        />
      ) : (
        <div className="space-y-2">
          {rows.map((a) => (
            <div key={a.id} className="rounded-field border border-hairline bg-surface px-4 py-3 text-sm">
              <div className="flex flex-wrap items-center gap-3">
                <span className="font-semibold text-ink">{auditActionLabel(a.action)}</span>
                <span className="text-micro text-ink-faint">{fmtDateLong(a.created_at)}</span>
                <span className="text-micro text-ink-faint">المنفِّذ</span>
                <CopyId value={a.actor_admin_id} label="معرّف المسؤول" />
                <span className="text-micro text-ink-faint">المستخدم</span>
                <CopyId value={a.target_user_id} label="معرّف المستخدم" />
              </div>
              <p className="mt-1.5 text-ink-soft">{a.reason}</p>
              {(a.before_state || a.after_state) && (
                <>
                  <button
                    onClick={() => setExpanded(expanded === a.id ? null : a.id)}
                    className="mt-1.5 text-micro font-medium text-brand-700 hover:text-brand-800"
                  >
                    {expanded === a.id ? "إخفاء التفاصيل التقنية" : "عرض التفاصيل التقنية"}
                  </button>
                  {expanded === a.id && (
                    <pre className="ltr mt-2 overflow-x-auto rounded-field bg-muted p-2.5 font-mono text-micro text-ink-soft">
                      {JSON.stringify(a.before_state)} → {JSON.stringify(a.after_state)}
                    </pre>
                  )}
                </>
              )}
            </div>
          ))}
        </div>
      )}
    </Card>
  );
}

// ── small presentational helpers (local, per admin convention) ───────────────
function shortId(id: string | null): string {
  return id ? id.slice(0, 8) : "—";
}
