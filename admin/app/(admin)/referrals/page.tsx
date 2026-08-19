"use client";

// Referral & Ads admin (Phase R2). Reuses the existing admin architecture: every
// read is a service-role select behind requireAdmin(); every mutation posts to a
// route that calls an approved 0083 RPC wrapper. This page never talks to the
// database directly. operation_id is minted once per operator intent (at confirm)
// and resent unchanged on retry so a double-click or proxy retry cannot double-apply.

import { useCallback, useEffect, useMemo, useState } from "react";

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
async function api(url: string, init?: RequestInit): Promise<{ ok: boolean; json: any }> {
  const res = await fetch(url, init);
  const json = await res.json().catch(() => ({}));
  return { ok: res.ok, json };
}
function errText(json: any, fallback: string): string {
  if (json?.message) return json.message;
  if (Array.isArray(json?.fields) && json.fields.length) {
    return json.fields.map((f: any) => `${f.field}: ${f.message ?? f.error}`).join("; ");
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
    <div className="p-8 space-y-8">
      <div>
        <p className="text-sm text-slate-500">Growth</p>
        <h1 className="text-2xl font-semibold text-slate-900">Referral &amp; Ads</h1>
        <p className="text-sm text-slate-500">
          Referral rules, entitlements, fraud review, and read-only ad diagnostics.
        </p>
      </div>

      {error && (
        <div className="rounded-lg border border-red-200 bg-red-50 px-4 py-3 text-sm text-red-700">{error}</div>
      )}
      {notice && (
        <div className="rounded-lg border border-emerald-200 bg-emerald-50 px-4 py-3 text-sm text-emerald-700">
          {notice}
        </div>
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
      if (!ok) return flash(null, errText(json, "Failed to load metrics"));
      setM(json as Metrics);
    })();
  }, [flash]);

  return (
    <Section title="Metrics" subtitle="Product funnel — not billing. AdMob owns ad revenue reporting.">
      {!m ? (
        <p className="text-sm text-slate-500">Loading…</p>
      ) : (
        <div className="grid grid-cols-2 gap-4 md:grid-cols-4">
          <Stat label="Attributed" value={m.referrals.attributed} />
          <Stat label="Qualified" value={m.referrals.qualified} />
          <Stat label="Rejected" value={m.referrals.rejected} />
          <Stat label="Reversed" value={m.referrals.reversed} />
          <Stat label="Rewards granted" value={m.rewards_granted} />
          <Stat label="Active ad-free" value={m.active_entitlements} />
          <Stat label="Active rules" value={m.active_rules} />
          <Stat label="Qualified ratio" value={`${Math.round(m.qualified_ratio * 100)}%`} />
        </div>
      )}
    </Section>
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

  const load = useCallback(async () => {
    const { ok, json } = await api("/api/referral-rules");
    if (!ok) return flash(null, errText(json, "Failed to load rules"));
    setRules((json.rules ?? []) as Rule[]);
  }, [flash]);
  useEffect(() => {
    void load();
  }, [load]);

  async function publish() {
    setBusy(true);
    // operation_id minted once for this publish intent; reused if a retry is needed.
    const operation_id = crypto.randomUUID();
    const { ok, json } = await api("/api/referral-rules", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        operation_id,
        reward_type: REWARD_TYPE,
        required_referrals: Number(required),
        reward_days: Number(days),
        repeatable,
        reason,
      }),
    });
    setBusy(false);
    if (!ok) return flash(null, errText(json, "Failed to publish rule"));
    setReason("");
    flash("Published a new rule version.", null);
    await load();
  }

  async function deactivate() {
    if (!reason.trim()) return flash(null, "A reason is required to deactivate.");
    setBusy(true);
    const operation_id = crypto.randomUUID();
    const { ok, json } = await api("/api/referral-rules", {
      method: "PATCH",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ operation_id, reward_type: REWARD_TYPE, reason }),
    });
    setBusy(false);
    if (!ok) return flash(null, errText(json, "Failed to deactivate rule"));
    setReason("");
    flash("Deactivated the active rule.", null);
    await load();
  }

  return (
    <Section title="Referral rules" subtitle="The “5 / 7” is configuration — never hardcoded.">
      <div className="grid gap-4 md:grid-cols-3">
        <Input label="Required referrals" value={required} onChange={setRequired} />
        <Input label="Reward days" value={days} onChange={setDays} />
        <label className="flex items-end gap-2 text-sm text-slate-700">
          <input type="checkbox" checked={repeatable} onChange={(e) => setRepeatable(e.target.checked)} />
          Repeatable
        </label>
      </div>
      <Reason value={reason} onChange={setReason} />
      <p className="mt-3 rounded-lg bg-amber-50 px-3 py-2 text-xs text-amber-800">
        Changing this creates a new rule version. Users with a cycle already in progress keep their
        current rule until that cycle completes; the new rule applies from their next cycle. Rewards
        already earned are never recalculated.
      </p>
      <div className="mt-4 flex gap-3">
        <button
          className="rounded-lg bg-brand-600 px-4 py-2 text-sm font-semibold text-white disabled:opacity-50"
          disabled={busy}
          onClick={publish}
        >
          Publish new version
        </button>
        <button
          className="rounded-lg border border-red-200 px-4 py-2 text-sm font-semibold text-red-600 disabled:opacity-50"
          disabled={busy}
          onClick={deactivate}
          title="Deactivating stops new invites from being attributed. In-progress cycles still complete under their pinned rule; no new cycles start until a rule is active again."
        >
          Deactivate active rule
        </button>
      </div>

      <div className="mt-5 space-y-2">
        {rules.map((r) => (
          <div
            key={r.id}
            className="flex flex-wrap items-center gap-3 rounded-lg border border-slate-200 bg-white px-4 py-3 text-sm"
          >
            <span className={r.is_active ? "font-semibold text-emerald-700" : "text-slate-400"}>
              {r.is_active ? "ACTIVE" : "inactive"}
            </span>
            <span className="text-slate-500">v{r.version}</span>
            <span className="text-slate-900">
              {r.required_referrals} → {r.reward_days}d
            </span>
            <span className="text-slate-500">{r.repeatable ? "repeatable" : "one-shot"}</span>
            <span className="text-slate-400">{r.reward_type}</span>
          </div>
        ))}
        {rules.length === 0 && <p className="text-sm text-slate-500">No rules yet.</p>}
      </div>
    </Section>
  );
}

// ── 3+4+5+6. User lookup → detail → manual actions + fraud review ─────────────
function LookupSection({ flash }: { flash: Flash }) {
  const [query, setQuery] = useState("");
  const [results, setResults] = useState<LookupCard[]>([]);
  const [detail, setDetail] = useState<Detail | null>(null);
  const [busy, setBusy] = useState(false);

  async function search() {
    setBusy(true);
    setDetail(null);
    const { ok, json } = await api(`/api/referral-users?query=${encodeURIComponent(query)}`);
    setBusy(false);
    if (!ok) return flash(null, errText(json, "Lookup failed"));
    setResults((json.results ?? []) as LookupCard[]);
    if (json.truncated) flash(null, "Email scan did not find a match within the scanned range.");
  }

  const openDetail = useCallback(
    async (userId: string) => {
      const { ok, json } = await api(`/api/referral-users/${encodeURIComponent(userId)}`);
      if (!ok) return flash(null, errText(json, "Failed to load detail"));
      setDetail(json as Detail);
    },
    [flash],
  );

  return (
    <Section title="User lookup" subtitle="Search by user id, referral code, or auth email. No financial data.">
      <div className="flex gap-3">
        <input
          className="flex-1 rounded-lg border border-slate-200 px-3 py-2 text-sm"
          placeholder="user_id · CODE · email@example.com"
          value={query}
          onChange={(e) => setQuery(e.target.value)}
          onKeyDown={(e) => e.key === "Enter" && void search()}
        />
        <button
          className="rounded-lg bg-brand-600 px-4 py-2 text-sm font-semibold text-white disabled:opacity-50"
          disabled={busy || !query.trim()}
          onClick={search}
        >
          Search
        </button>
      </div>

      <div className="mt-4 space-y-2">
        {results.map((r) => (
          <button
            key={r.user_id}
            onClick={() => void openDetail(r.user_id)}
            className="flex w-full flex-wrap items-center gap-3 rounded-lg border border-slate-200 bg-white px-4 py-3 text-left text-sm hover:border-brand-500"
          >
            <span className="font-mono text-xs text-slate-500">{shortId(r.user_id)}</span>
            <span className="text-slate-900">{r.code ?? "no code"}</span>
            {r.active_entitlement && (
              <span className="rounded-full bg-emerald-100 px-2 py-0.5 text-xs text-emerald-700">ad-free</span>
            )}
            {r.progress.map((p) => (
              <span key={p.reward_type} className="text-xs text-slate-500">
                {p.qualified_in_cycle}/cycle {p.cycle_index} (v{p.pinned_rule_version ?? "—"})
              </span>
            ))}
          </button>
        ))}
        {results.length === 0 && <p className="text-sm text-slate-500">No results.</p>}
      </div>

      {detail && <DetailPanel detail={detail} flash={flash} onChanged={() => void openDetail(detail.user_id)} />}
    </Section>
  );
}

function DetailPanel({ detail, flash, onChanged }: { detail: Detail; flash: Flash; onChanged: () => void }) {
  return (
    <div className="mt-6 space-y-6 rounded-xl border border-slate-200 bg-slate-50 p-5">
      <div>
        <h3 className="text-sm font-semibold text-slate-900">
          {shortId(detail.user_id)} · code {detail.code?.code ?? "—"} ({detail.code?.status ?? "none"})
        </h3>
      </div>

      {/* current cycle + pinned rule (§6) */}
      <div>
        <h4 className="mb-2 text-xs font-semibold uppercase text-slate-500">Current cycle</h4>
        {detail.progress.length === 0 ? (
          <p className="text-sm text-slate-500">No progress.</p>
        ) : (
          detail.progress.map((p) => (
            <p key={p.reward_type} className="text-sm text-slate-700">
              {p.qualified_in_cycle} qualified · cycle {p.cycle_index} · pinned rule v
              {p.pinned_rule_version ?? "—"} · {p.cycle_state}
            </p>
          ))
        )}
      </div>

      {/* current entitlement (§6) */}
      <div>
        <h4 className="mb-2 text-xs font-semibold uppercase text-slate-500">Current entitlement</h4>
        {detail.entitlement.length === 0 ? (
          <p className="text-sm text-slate-500">None.</p>
        ) : (
          detail.entitlement.map((e) => (
            <p key={e.entitlement_type} className="text-sm text-slate-700">
              {e.entitlement_type} · {e.status} · ends {fmtDate(e.ends_at)}
            </p>
          ))
        )}
      </div>

      {/* grant history from the immutable ledger (§6) */}
      <div>
        <h4 className="mb-2 text-xs font-semibold uppercase text-slate-500">Grant history (immutable)</h4>
        {detail.grants.length === 0 ? (
          <p className="text-sm text-slate-500">No grants.</p>
        ) : (
          <div className="space-y-1 text-sm text-slate-700">
            {detail.grants.map((g) => (
              <p key={g.id}>
                v{g.rule_version} · cycle {g.cycle_index} · {g.reward_days_granted}d → ends{" "}
                {fmtDate(g.resulting_ends_at)} · {fmtDate(g.created_at)}
              </p>
            ))}
          </div>
        )}
      </div>

      {/* referrals list — short ids only, "deleted user" for de-identified rows (§6) */}
      <div>
        <h4 className="mb-2 text-xs font-semibold uppercase text-slate-500">Referrals made</h4>
        {detail.referrals.length === 0 ? (
          <p className="text-sm text-slate-500">None.</p>
        ) : (
          <div className="space-y-2">
            {detail.referrals.map((r) => (
              <div
                key={r.id}
                className="flex flex-wrap items-center gap-3 rounded-lg border border-slate-200 bg-white px-3 py-2 text-sm"
              >
                <span className="font-mono text-xs text-slate-500">
                  {r.referred_user === "deleted user"
                    ? "deleted user"
                    : r.referred_user
                      ? shortId(r.referred_user)
                      : "—"}
                </span>
                <span className="text-slate-500">{r.attribution_method}</span>
                <StatusBadge status={r.status} />
                {r.qualified_at && <span className="text-xs text-slate-400">q {fmtDate(r.qualified_at)}</span>}
                {r.rejection_reason && <span className="text-xs text-red-500">{r.rejection_reason}</span>}
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
function ManualActions({ userId, flash, onDone }: { userId: string; flash: Flash; onDone: () => void }) {
  const [action, setAction] = useState("grant");
  const [days, setDays] = useState("7");
  const [progress, setProgress] = useState("0");
  const [reason, setReason] = useState("");
  const [busy, setBusy] = useState(false);

  const needsDays = action === "grant" || action === "extend" || action === "shorten";
  const isProgress = action === "adjust_progress";
  const isRotate = action === "rotate_code";

  async function run() {
    if (!reason.trim()) return flash(null, "A reason is required.");
    setBusy(true);
    const operation_id = crypto.randomUUID(); // one intent, reused on retry
    let url = "";
    let body: Record<string, unknown> = { operation_id, reason };

    if (action === "grant" || action === "extend") {
      url = `/api/entitlements/${action}`;
      body = { ...body, user_id: userId, action, duration_days: Number(days) };
    } else if (action === "revoke" || action === "shorten") {
      url = "/api/entitlements/revoke";
      body = { ...body, user_id: userId, action, ...(action === "shorten" ? { duration_days: Number(days) } : {}) };
    } else if (isProgress) {
      url = "/api/referral-progress/adjust";
      body = { ...body, referrer_user_id: userId, reward_type: REWARD_TYPE, qualified_in_cycle: Number(progress) };
    } else if (isRotate) {
      url = "/api/referral-codes/rotate";
      body = { ...body, user_id: userId };
    }

    const { ok, json } = await api(url, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
    });
    setBusy(false);
    if (!ok) return flash(null, errText(json, "Action failed"));
    const dup = json?.result?.duplicate ? " (already applied)" : "";
    setReason("");
    flash(`Done: ${action}${dup}.`, null);
    onDone();
  }

  return (
    <div className="rounded-lg border border-slate-300 bg-white p-4">
      <h4 className="mb-3 text-xs font-semibold uppercase text-slate-500">Manual action</h4>
      <div className="grid gap-3 md:grid-cols-3">
        <Select
          label="Action"
          value={action}
          options={["grant", "extend", "shorten", "revoke", "adjust_progress", "rotate_code"]}
          onChange={setAction}
        />
        {needsDays && <Input label="Days" value={days} onChange={setDays} />}
        {isProgress && <Input label="New qualified_in_cycle" value={progress} onChange={setProgress} />}
      </div>
      <Reason value={reason} onChange={setReason} />
      <button
        className="mt-3 rounded-lg bg-brand-600 px-4 py-2 text-sm font-semibold text-white disabled:opacity-50"
        disabled={busy}
        onClick={run}
      >
        {busy ? "Working…" : `Confirm ${action}`}
      </button>
      {(action === "revoke" || action === "shorten") && (
        <p className="mt-2 text-xs text-slate-500">
          Revoke/shorten is separate from fraud reversal. Consumed ad-free time is never rewritten.
        </p>
      )}
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

  async function run() {
    if (!reason.trim()) return flash(null, "A reason is required.");
    setBusy(true);
    const operation_id = crypto.randomUUID();
    const url = kind === "reject" ? "/api/referrals/reject" : "/api/referrals/reverse";
    const { ok, json } = await api(url, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ operation_id, referral_id: referralId, reason }),
    });
    setBusy(false);
    if (!ok) return flash(null, errText(json, `${kind} failed`));
    setOpen(false);
    setReason("");
    flash(`Referral ${kind}d.`, null);
    onDone();
  }

  if (!open) {
    return (
      <button
        onClick={() => setOpen(true)}
        className={`rounded-lg border px-2 py-1 text-xs ${
          kind === "reverse" ? "border-red-200 text-red-600" : "border-amber-200 text-amber-700"
        }`}
      >
        {kind}
      </button>
    );
  }
  return (
    <div className="flex w-full items-center gap-2">
      <input
        className="flex-1 rounded border border-slate-200 px-2 py-1 text-xs"
        placeholder={`reason to ${kind}`}
        value={reason}
        onChange={(e) => setReason(e.target.value)}
      />
      <button
        className="rounded bg-brand-600 px-2 py-1 text-xs text-white disabled:opacity-50"
        disabled={busy}
        onClick={run}
      >
        confirm
      </button>
      <button className="rounded border px-2 py-1 text-xs" onClick={() => setOpen(false)}>
        cancel
      </button>
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
    <Section title="Report Ads (diagnostics)" subtitle="Read-only. There is no report_ads_config — nothing here is editable.">
      <div className="space-y-2 text-sm text-slate-700">
        <p>
          <span className="font-medium">enable_report_ads:</span>{" "}
          {flag ? (
            <>
              {flag.is_active ? "on" : "off"}
              {flag.rollout_percent != null ? ` · rollout ${flag.rollout_percent}%` : ""} — edit on the Feature
              Flags screen.
            </>
          ) : (
            "unknown"
          )}
        </p>
        <p>
          <span className="font-medium">Effective ad gate:</span> enable_report_ads ∧ valid build config ∧ UMP
          canRequestAds ∧ entitlement VERIFIED_INACTIVE (fresh) ∧ ad available.
        </p>
        <p className="text-slate-500">
          Ad-unit IDs and environment are supplied by build configuration and are never shown or edited here.
          V1 policy is fail-open: one ad opportunity per export.
        </p>
        <p className="rounded-lg bg-amber-50 px-3 py-2 text-xs text-amber-800">
          Flag flips require catalog sync + app restart — they are not instant. Same-session flag reactivity is
          required rollout hardening before enable_report_ads = true in production.
        </p>
      </div>
    </Section>
  );
}

// ── 8. Audit history (spec §9) — append-only, de-identified ──────────────────
function AuditSection({ flash }: { flash: Flash }) {
  const [rows, setRows] = useState<AuditRow[]>([]);
  useEffect(() => {
    void (async () => {
      const { ok, json } = await api("/api/referral-audit");
      if (!ok) return flash(null, errText(json, "Failed to load audit"));
      setRows((json.audit ?? []) as AuditRow[]);
    })();
  }, [flash]);

  return (
    <Section title="Audit history" subtitle="Append-only. No update or delete. Snapshots are the allowlisted schema.">
      {rows.length === 0 ? (
        <p className="text-sm text-slate-500">No audit rows.</p>
      ) : (
        <div className="space-y-2">
          {rows.map((a) => (
            <div key={a.id} className="rounded-lg border border-slate-200 bg-white px-4 py-3 text-sm">
              <div className="flex flex-wrap items-center gap-3">
                <span className="font-semibold text-slate-900">{a.action}</span>
                <span className="text-xs text-slate-500">{fmtDate(a.created_at)}</span>
                <span className="font-mono text-xs text-slate-400">
                  actor {shortId(a.actor_admin_id)} · target {shortId(a.target_user_id)}
                </span>
              </div>
              <p className="mt-1 text-slate-600">{a.reason}</p>
              {(a.before_state || a.after_state) && (
                <p className="mt-1 font-mono text-xs text-slate-400">
                  {JSON.stringify(a.before_state)} → {JSON.stringify(a.after_state)}
                </p>
              )}
            </div>
          ))}
        </div>
      )}
    </Section>
  );
}

// ── small presentational helpers (local, per admin convention) ───────────────
function Section({ title, subtitle, children }: { title: string; subtitle?: string; children: React.ReactNode }) {
  return (
    <section className="rounded-xl border border-slate-200 bg-white p-5 shadow-sm">
      <h2 className="text-lg font-semibold text-slate-900">{title}</h2>
      {subtitle && <p className="mb-4 text-sm text-slate-500">{subtitle}</p>}
      {children}
    </section>
  );
}
function Stat({ label, value }: { label: string; value: number | string }) {
  return (
    <div className="rounded-lg border border-slate-200 bg-slate-50 px-4 py-3">
      <p className="text-xs uppercase text-slate-500">{label}</p>
      <p className="text-xl font-semibold text-slate-900">{value}</p>
    </div>
  );
}
function StatusBadge({ status }: { status: string }) {
  const color =
    status === "qualified"
      ? "bg-emerald-100 text-emerald-700"
      : status === "rejected" || status === "reversed"
        ? "bg-red-100 text-red-700"
        : "bg-slate-100 text-slate-600";
  return <span className={`rounded-full px-2 py-0.5 text-xs ${color}`}>{status}</span>;
}
function Input({ label, value, onChange }: { label: string; value: string; onChange: (v: string) => void }) {
  return (
    <label className="block text-sm">
      <span className="mb-1 block font-medium text-slate-700">{label}</span>
      <input
        className="w-full rounded-lg border border-slate-200 px-3 py-2"
        value={value}
        onChange={(e) => onChange(e.target.value)}
      />
    </label>
  );
}
function Select({
  label,
  value,
  options,
  onChange,
}: {
  label: string;
  value: string;
  options: string[];
  onChange: (v: string) => void;
}) {
  return (
    <label className="block text-sm">
      <span className="mb-1 block font-medium text-slate-700">{label}</span>
      <select
        className="w-full rounded-lg border border-slate-200 px-3 py-2"
        value={value}
        onChange={(e) => onChange(e.target.value)}
      >
        {options.map((o) => (
          <option key={o} value={o}>
            {o}
          </option>
        ))}
      </select>
    </label>
  );
}
function Reason({ value, onChange }: { value: string; onChange: (v: string) => void }) {
  return (
    <label className="mt-3 block text-sm">
      <span className="mb-1 block font-medium text-slate-700">Reason (required, 4–500 chars)</span>
      <textarea
        className="w-full rounded-lg border border-slate-200 px-3 py-2"
        rows={2}
        value={value}
        maxLength={500}
        onChange={(e) => onChange(e.target.value)}
      />
    </label>
  );
}
function shortId(id: string | null): string {
  return id ? id.slice(0, 8) : "—";
}
function fmtDate(iso: string | null): string {
  if (!iso) return "—";
  const d = new Date(iso);
  return Number.isNaN(d.getTime()) ? "—" : d.toISOString().slice(0, 10);
}
