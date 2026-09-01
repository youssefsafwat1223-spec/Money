"use client";

import { useMemo, useState } from "react";
import { Store } from "lucide-react";
import { DataTable, NameCell, TBody, TD, THead, TR } from "@/components/ui/table";
import { EmptyState, StatusBadge } from "@/components/ui/primitives";
import { FilterBar, FilterSelect } from "@/components/ui/filter-bar";
import { CopyId } from "@/components/ui/copy-id";
import { hasLookupNoise } from "@/lib/merchant-validation.mjs";

export type MerchantRow = {
  id: string;
  slug: string;
  name_ar: string;
  name_en: string | null;
  primary_domain: string | null;
  country_codes: string[];
  is_active: boolean;
  is_deleted: boolean;
};

export type AliasRow = {
  id: string;
  merchant_id: string;
  alias_raw: string;
  alias_normalized: string;
  alias_kind: string;
  country_code: string | null;
  priority: number;
  provenance: string;
  is_reviewed: boolean;
  is_active: boolean;
};

async function call(path: string, init: RequestInit) {
  const res = await fetch(path, {
    headers: { "content-type": "application/json" },
    ...init,
  });
  if (!res.ok) {
    const body = await res.json().catch(() => ({}));
    throw new Error(body?.error ?? `HTTP ${res.status}`);
  }
  return res.json();
}

/**
 * The merchant catalog, its aliases, and the review queue.
 *
 * The review queue is first on the page on purpose. An unreviewed alias reaches
 * no device, so this list is the only place it can be seen at all — and every
 * hour it sits here is an hour the matcher is missing a merchant it could have
 * resolved. Burying it under the merchant table would make the queue invisible
 * exactly when it is longest.
 */
export function MerchantsManager({
  merchants,
  aliases,
}: {
  merchants: MerchantRow[];
  aliases: AliasRow[];
}) {
  const [search, setSearch] = useState("");
  const [status, setStatus] = useState("all");
  const [busy, setBusy] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  const byMerchant = useMemo(() => {
    const m = new Map<string, AliasRow[]>();
    for (const a of aliases) {
      const list = m.get(a.merchant_id) ?? [];
      list.push(a);
      m.set(a.merchant_id, list);
    }
    return m;
  }, [aliases]);

  const merchantName = useMemo(() => {
    const m = new Map<string, string>();
    for (const x of merchants) m.set(x.id, x.name_ar);
    return m;
  }, [merchants]);

  const pending = useMemo(
    () => aliases.filter((a) => !a.is_reviewed && a.is_active),
    [aliases],
  );

  // A reviewed alias may be claimed by exactly one merchant per country scope —
  // the database's partial unique index enforces it. But an UNREVIEWED
  // duplicate is legal and expected: it is precisely what a provider suggestion
  // colliding with an existing alias looks like, and resolving it is the whole
  // job of this queue. Surfacing the clash next to the row saves the reviewer
  // from approving it and getting a constraint error instead of an explanation.
  const collisions = useMemo(() => {
    const reviewed = new Map<string, string>();
    for (const a of aliases) {
      if (!a.is_reviewed || !a.is_active || !a.alias_normalized) continue;
      reviewed.set(`${a.alias_normalized}|${a.alias_kind}|${a.country_code ?? ""}`, a.merchant_id);
    }
    const out = new Map<string, string>();
    for (const a of pending) {
      if (!a.alias_normalized) continue;
      const owner = reviewed.get(
        `${a.alias_normalized}|${a.alias_kind}|${a.country_code ?? ""}`,
      );
      if (owner && owner !== a.merchant_id) {
        out.set(a.id, merchantName.get(owner) ?? owner);
      }
    }
    return out;
  }, [aliases, pending, merchantName]);

  const visible = useMemo(() => {
    const q = search.trim().toLowerCase();
    return merchants.filter((m) => {
      if (status === "active" && (!m.is_active || m.is_deleted)) return false;
      if (status === "withdrawn" && !m.is_deleted) return false;
      if (!q) return true;
      return (
        m.name_ar.toLowerCase().includes(q) ||
        (m.name_en ?? "").toLowerCase().includes(q) ||
        m.slug.toLowerCase().includes(q)
      );
    });
  }, [merchants, search, status]);

  async function review(aliasId: string, approve: boolean) {
    setBusy(aliasId);
    setError(null);
    try {
      await call("/api/merchant-aliases", {
        method: "PATCH",
        body: JSON.stringify({ id: aliasId, is_reviewed: approve }),
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
        <h2 className="text-sm font-semibold">
          أسماء بديلة بانتظار المراجعة ({pending.length})
        </h2>
        <p className="text-xs text-muted-foreground">
          لا يصل أي اسم بديل هنا إلى أجهزة المستخدمين قبل اعتماده. الاعتماد يعني
          أن هذا النص — حرفيًا — يعني هذا المتجر.
        </p>
        {pending.length === 0 ? (
          <EmptyState icon={Store} title="لا شيء بانتظار المراجعة" />
        ) : (
          <DataTable>
            <THead
              columns={["الاسم البديل", "مفتاح المطابقة", "المتجر", "المصدر", ""]}
            />
            <TBody>
              {pending.map((a) => {
                const clash = collisions.get(a.id);
                return (
                  <TR key={a.id}>
                    <TD>
                      <div className="font-medium">{a.alias_raw}</div>
                      {/* The admin typed the left column; the matcher only ever
                          sees the right one. Showing both is what makes an
                          "obviously fine" alias that folds into something else
                          visible before it is approved. */}
                      {hasLookupNoise(a.alias_raw) ? (
                        <div className="text-xs text-amber-700">
                          يحتوي على زوائد يحذفها التطبيق قبل المطابقة — سيُرفض عند الحفظ
                        </div>
                      ) : null}
                      {clash ? (
                        <div className="text-xs text-red-700">
                          تعارض: نفس المفتاح معتمد بالفعل لمتجر «{clash}»
                        </div>
                      ) : null}
                    </TD>
                    <TD>
                      <code className="text-xs">{a.alias_normalized || "—"}</code>
                    </TD>
                    <TD>{merchantName.get(a.merchant_id) ?? a.merchant_id}</TD>
                    <TD>
                      <StatusBadge
                        tone={a.provenance === "admin" ? "neutral" : "warning"}
                        label={a.provenance}
                      />
                    </TD>
                    <TD>
                      <div className="flex gap-2">
                        <button
                          type="button"
                          disabled={busy === a.id || Boolean(clash)}
                          onClick={() => review(a.id, true)}
                          className="rounded border px-2 py-1 text-xs disabled:opacity-40"
                          // A colliding alias cannot be approved: the database
                          // would reject it. Disabling the button explains that
                          // before the click instead of after.
                          title={clash ? "عالِج التعارض أولًا" : undefined}
                        >
                          اعتماد
                        </button>
                        <button
                          type="button"
                          disabled={busy === a.id}
                          onClick={() => review(a.id, false)}
                          className="rounded border px-2 py-1 text-xs disabled:opacity-40"
                        >
                          إبقاء قيد المراجعة
                        </button>
                      </div>
                    </TD>
                  </TR>
                );
              })}
            </TBody>
          </DataTable>
        )}
      </section>

      <section className="space-y-3">
        <h2 className="text-sm font-semibold">المتاجر ({merchants.length})</h2>
        <FilterBar search={search} onSearch={setSearch}>
          <FilterSelect
            label="الحالة"
            value={status}
            onChange={setStatus}
            options={[
              { value: "all", label: "الكل" },
              { value: "active", label: "نشط" },
              { value: "withdrawn", label: "مسحوب" },
            ]}
          />
        </FilterBar>

        {visible.length === 0 ? (
          <EmptyState icon={Store} title="لا توجد متاجر" />
        ) : (
          <DataTable>
            <THead
              columns={["المتجر", "المعرّف", "النطاق", "الدول", "الأسماء البديلة", "الحالة"]}
            />
            <TBody>
              {visible.map((m) => {
                const list = byMerchant.get(m.id) ?? [];
                const reviewed = list.filter((a) => a.is_reviewed && a.is_active);
                return (
                  <TR key={m.id}>
                    <TD>
                      <NameCell title={m.name_ar} subtitle={m.name_en ?? undefined} />
                    </TD>
                    <TD>
                      <CopyId value={m.slug} />
                    </TD>
                    <TD>{m.primary_domain ?? "—"}</TD>
                    <TD>
                      {m.country_codes.length === 0 ? "عالمي" : m.country_codes.join(", ")}
                    </TD>
                    <TD>
                      {/* Reviewed count first: it is the number that decides
                          whether this merchant can be matched at all. A
                          merchant with zero reviewed aliases is invisible to
                          every device no matter how complete its row looks. */}
                      <span className={reviewed.length === 0 ? "text-amber-700" : undefined}>
                        {reviewed.length} معتمد
                      </span>
                      {list.length > reviewed.length ? (
                        <span className="text-xs text-muted-foreground">
                          {" "}
                          · {list.length - reviewed.length} قيد المراجعة
                        </span>
                      ) : null}
                    </TD>
                    <TD>
                      <StatusBadge
                        tone={m.is_deleted ? "danger" : m.is_active ? "success" : "neutral"}
                        label={m.is_deleted ? "مسحوب" : m.is_active ? "نشط" : "معطّل"}
                      />
                    </TD>
                  </TR>
                );
              })}
            </TBody>
          </DataTable>
        )}
      </section>
    </div>
  );
}
