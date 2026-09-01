"use client";

import { useMemo, useState } from "react";
import { Receipt } from "lucide-react";
import { DataTable, TBody, TD, THead, TR } from "@/components/ui/table";
import { EmptyState, StatusBadge } from "@/components/ui/primitives";
import { FilterBar, FilterSelect } from "@/components/ui/filter-bar";

export type ConversionRow = {
  id: string;
  network_key: string;
  external_conversion_id: string;
  correlated: boolean;
  status: string;
  history_length: number;
  order_amount_minor: number | null;
  order_currency: string | null;
  commission_amount_minor: number | null;
  commission_currency: string | null;
  provider_discount_minor: number | null;
  provider_discount_currency: string | null;
  updated_at: string;
};

/**
 * Minor units to a readable figure.
 *
 * Two decimals is an ASSUMPTION and is shown as such by always printing the
 * currency beside it. The admin panel has no scale registry — the app's
 * `kCurrencyScale` lives in Dart — so a zero-decimal currency like JPY would
 * read wrong here. Showing the code makes that visible rather than silent, and
 * a real multi-currency rate card should bring the registry with it.
 */
function money(minor: number | null, currency: string | null): string {
  if (minor == null || currency == null) return "—";
  return `${(minor / 100).toFixed(2)} ${currency}`;
}

export function ConversionsTable({ rows }: { rows: ConversionRow[] }) {
  const [status, setStatus] = useState("all");

  const visible = useMemo(
    () => rows.filter((r) => status === "all" || r.status === status),
    [rows, status],
  );

  // Totals per currency, and ONLY for approved rows. A pending conversion may
  // still be clawed back, and a "revenue" figure that counts them is a number
  // that goes down without anything going wrong — which is how a dashboard
  // stops being trusted.
  const approvedByCurrency = useMemo(() => {
    const m = new Map<string, number>();
    for (const r of rows) {
      if (r.status !== "approved") continue;
      if (r.commission_amount_minor == null || r.commission_currency == null) continue;
      m.set(
        r.commission_currency,
        (m.get(r.commission_currency) ?? 0) + r.commission_amount_minor,
      );
    }
    return Array.from(m.entries()).sort();
  }, [rows]);

  const uncorrelated = rows.filter((r) => !r.correlated).length;

  return (
    <div className="space-y-4">
      <div className="flex flex-wrap gap-4">
        {approvedByCurrency.length === 0 ? (
          <div className="text-sm text-muted-foreground">لا توجد عمولة معتمدة بعد.</div>
        ) : (
          approvedByCurrency.map(([currency, total]) => (
            <div key={currency} className="rounded-lg border px-3 py-2">
              <div className="text-xs text-muted-foreground">عمولة معتمدة</div>
              <div className="text-lg font-semibold">{money(total, currency)}</div>
            </div>
          ))
        )}
      </div>

      {uncorrelated > 0 ? (
        <div className="rounded-lg border border-amber-300 bg-amber-50 p-3 text-sm text-amber-900">
          {uncorrelated} تحويلًا بلا نقرة مرتبطة. هذا متوقّع أحيانًا — تُبلغ
          الشبكات عن مبيعات لا نستطيع ربطها — ولكن ارتفاع النسبة يعني غالبًا أن
          مُعرّف التتبّع لا يصل.
        </div>
      ) : null}

      <FilterBar search="" onSearch={() => {}}>
        <FilterSelect
          label="الحالة"
          value={status}
          onChange={setStatus}
          options={[
            { value: "all", label: "الكل" },
            { value: "pending", label: "معلّق" },
            { value: "approved", label: "معتمد" },
            { value: "returned", label: "مُرتجع" },
            { value: "rejected", label: "مرفوض" },
            { value: "cancelled", label: "ملغى" },
          ]}
        />
      </FilterBar>

      {visible.length === 0 ? (
        <EmptyState icon={Receipt} title="لا توجد تحويلات" />
      ) : (
        <DataTable>
          <THead
            columns={["الشبكة", "المُعرّف", "الحالة", "قيمة الطلب", "العمولة", "خصم المستخدم", "النقرة"]}
          />
          <TBody>
            {visible.map((r) => (
              <TR key={r.id}>
                <TD>{r.network_key}</TD>
                <TD>
                  <code className="text-xs">{r.external_conversion_id}</code>
                </TD>
                <TD>
                  <StatusBadge
                    tone={
                      r.status === "approved"
                        ? "success"
                        : r.status === "pending"
                          ? "neutral"
                          : "danger"
                    }
                    label={r.status}
                  />
                  {/* More than one entry means the status CHANGED. A clawback is
                      the case worth noticing, and it is invisible from the
                      current status alone. */}
                  {r.history_length > 1 ? (
                    <span className="ms-1 text-xs text-muted-foreground">
                      ({r.history_length} تغييرات)
                    </span>
                  ) : null}
                </TD>
                <TD>{money(r.order_amount_minor, r.order_currency)}</TD>
                <TD>{money(r.commission_amount_minor, r.commission_currency)}</TD>
                {/* The user's discount — the ONLY figure here that may ever
                    inform a savings number, and only as verified evidence. */}
                <TD>{money(r.provider_discount_minor, r.provider_discount_currency)}</TD>
                <TD>
                  {r.correlated ? (
                    "مرتبطة"
                  ) : (
                    <span className="text-amber-700">غير مرتبطة</span>
                  )}
                </TD>
              </TR>
            ))}
          </TBody>
        </DataTable>
      )}
    </div>
  );
}
