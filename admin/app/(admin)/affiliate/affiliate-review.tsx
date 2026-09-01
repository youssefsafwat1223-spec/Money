"use client";

import { useMemo, useState } from "react";
import { Inbox } from "lucide-react";
import { DataTable, TBody, TD, THead, TR } from "@/components/ui/table";
import { EmptyState, StatusBadge } from "@/components/ui/primitives";
import { FilterBar, FilterSelect } from "@/components/ui/filter-bar";

export type SourceRow = {
  id: string;
  external_offer_id: string;
  external_program_id: string;
  merchant_bound: boolean;
  title_ar: string;
  description_ar: string;
  benefit_type: string | null;
  discount_bps: number | null;
  benefit_currency: string | null;
  markets: string[];
  provider_status: string;
  review_state: string;
  review_note: string | null;
  coupon_id: string | null;
  last_seen_at: string;
};

export type RunRow = {
  id: string;
  network_key: string;
  kind: string;
  status: string;
  fetched_count: number;
  new_count: number;
  updated_count: number;
  rejected_count: number;
  safe_error_code: string | null;
  started_at: string;
  finished_at: string | null;
};

async function call(path: string, body: unknown) {
  const res = await fetch(path, {
    method: "PATCH",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  });
  if (!res.ok) {
    const parsed = await res.json().catch(() => ({}));
    throw new Error(parsed?.error ?? `HTTP ${res.status}`);
  }
  return res.json();
}

export function AffiliateReview({
  sources,
  runs,
}: {
  sources: SourceRow[];
  runs: RunRow[];
}) {
  const [state, setState] = useState("pending");
  const [category, setCategory] = useState("");
  const [busy, setBusy] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  const visible = useMemo(
    () => sources.filter((s) => state === "all" || s.review_state === state),
    [sources, state],
  );

  // The most recent run per network. A single stale timestamp here is the whole
  // early-warning system: without it, an ingestion that has been failing for
  // three weeks is indistinguishable from a provider with nothing new.
  const latestByNetwork = useMemo(() => {
    const m = new Map<string, RunRow>();
    for (const r of runs) if (!m.has(r.network_key)) m.set(r.network_key, r);
    return Array.from(m.values());
  }, [runs]);

  async function act(id: string, action: "publish" | "reject") {
    setBusy(id);
    setError(null);
    try {
      await call("/api/affiliate-sources", {
        id,
        action,
        display_category_key: action === "publish" ? category : undefined,
      });
      window.location.reload();
    } catch (e) {
      setError(e instanceof Error ? e.message : "فشل غير متوقع");
    } finally {
      setBusy(null);
    }
  }

  return (
    <div className="space-y-8">
      {error ? (
        <div className="rounded-lg border border-red-300 bg-red-50 p-3 text-sm text-red-800">
          {error}
        </div>
      ) : null}

      <section className="space-y-3">
        <h2 className="text-sm font-semibold">آخر عمليات السحب</h2>
        {latestByNetwork.length === 0 ? (
          <EmptyState icon={Inbox} title="لم تُنفَّذ أي عملية سحب بعد" />
        ) : (
          <DataTable>
            <THead columns={["الشبكة", "الحالة", "مسحوب", "جديد", "محدَّث", "مرفوض", "آخر تشغيل"]} />
            <TBody>
              {latestByNetwork.map((r) => (
                <TR key={r.id}>
                  <TD>{r.network_key}</TD>
                  <TD>
                    <StatusBadge
                      tone={
                        r.status === "ok"
                          ? "success"
                          : r.status === "failed"
                            ? "danger"
                            : "warning"
                      }
                      label={r.safe_error_code ? `${r.status} · ${r.safe_error_code}` : r.status}
                    />
                  </TD>
                  <TD>{r.fetched_count}</TD>
                  <TD>{r.new_count}</TD>
                  <TD>{r.updated_count}</TD>
                  {/* Rejections are shown even when a run succeeded. A feed that
                      is 90% rejected is "ok" by status and broken in fact. */}
                  <TD className={r.rejected_count > 0 ? "text-amber-700" : undefined}>
                    {r.rejected_count}
                  </TD>
                  <TD>{new Date(r.started_at).toLocaleString("ar")}</TD>
                </TR>
              ))}
            </TBody>
          </DataTable>
        )}
      </section>

      <section className="space-y-3">
        <h2 className="text-sm font-semibold">العروض الواردة ({visible.length})</h2>
        <FilterBar search="" onSearch={() => {}}>
          <FilterSelect
            label="الحالة"
            value={state}
            onChange={setState}
            options={[
              { value: "pending", label: "بانتظار المراجعة" },
              { value: "published", label: "منشور" },
              { value: "rejected", label: "مرفوض" },
              { value: "all", label: "الكل" },
            ]}
          />
        </FilterBar>

        <label className="block text-xs">
          مفتاح التصنيف عند النشر
          <input
            value={category}
            onChange={(e) => setCategory(e.target.value)}
            placeholder="shopping"
            className="ms-2 rounded border px-2 py-1 text-xs"
          />
          {/* Required, never defaulted: the category decides which section of
              the app an offer lands in, and a default would be right often
              enough to stop being questioned. */}
        </label>

        {visible.length === 0 ? (
          <EmptyState icon={Inbox} title="لا توجد عروض في هذه الحالة" />
        ) : (
          <DataTable>
            <THead columns={["العرض", "القيمة", "الأسواق", "المزوّد", "الحالة", ""]} />
            <TBody>
              {visible.map((s) => (
                <TR key={s.id}>
                  <TD>
                    <div className="font-medium">{s.title_ar || "—"}</div>
                    <div className="text-xs text-muted-foreground">
                      {s.external_program_id} · {s.external_offer_id}
                    </div>
                    {!s.merchant_bound ? (
                      <div className="text-xs text-amber-700">
                        البرنامج غير مرتبط بمتجر — اربطه أولًا قبل النشر
                      </div>
                    ) : null}
                    {s.review_note ? (
                      <div className="text-xs text-muted-foreground">{s.review_note}</div>
                    ) : null}
                  </TD>
                  <TD>
                    {s.benefit_type
                      ? `${s.benefit_type}${
                          s.discount_bps ? ` · ${s.discount_bps / 100}%` : ""
                        }${s.benefit_currency ? ` · ${s.benefit_currency}` : ""}`
                      : "نص فقط"}
                  </TD>
                  <TD>{s.markets.length === 0 ? "—" : s.markets.join(", ")}</TD>
                  <TD>
                    <StatusBadge
                      tone={s.provider_status === "active" ? "success" : "warning"}
                      label={s.provider_status}
                    />
                  </TD>
                  <TD>
                    <StatusBadge
                      tone={
                        s.review_state === "published"
                          ? "success"
                          : s.review_state === "rejected"
                            ? "danger"
                            : "neutral"
                      }
                      label={s.review_state}
                    />
                  </TD>
                  <TD>
                    {s.review_state === "pending" ? (
                      <div className="flex gap-2">
                        <button
                          type="button"
                          // Publishing needs a bound merchant AND a category.
                          // Disabling explains that before the click rather
                          // than after a 400.
                          disabled={busy === s.id || !s.merchant_bound || !category.trim()}
                          onClick={() => act(s.id, "publish")}
                          className="rounded border px-2 py-1 text-xs disabled:opacity-40"
                          title={
                            !s.merchant_bound
                              ? "اربط البرنامج بمتجر أولًا"
                              : !category.trim()
                                ? "اختر مفتاح التصنيف"
                                : undefined
                          }
                        >
                          نشر
                        </button>
                        <button
                          type="button"
                          disabled={busy === s.id}
                          onClick={() => act(s.id, "reject")}
                          className="rounded border px-2 py-1 text-xs disabled:opacity-40"
                        >
                          رفض
                        </button>
                      </div>
                    ) : null}
                  </TD>
                </TR>
              ))}
            </TBody>
          </DataTable>
        )}
      </section>
    </div>
  );
}
