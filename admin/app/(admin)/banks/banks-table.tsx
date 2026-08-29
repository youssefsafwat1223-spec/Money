"use client";

import Link from "next/link";
import { useMemo, useState } from "react";
import { Building2, Pencil } from "lucide-react";
import { DataTable, NameCell, TBody, TD, TEmpty, THead, TR } from "@/components/ui/table";
import { EmptyState, StatusBadge } from "@/components/ui/primitives";
import { FilterBar, FilterSelect } from "@/components/ui/filter-bar";
import { Pagination, usePagination } from "@/components/ui/pagination";
import { fmt } from "@/lib/utils";

export type BankRow = {
  id: string;
  name_ar: string | null;
  name_en: string | null;
  short_code: string | null;
  country_code: string | null;
  is_active: boolean;
  senders: string[];
};

export function BanksTable({ banks }: { banks: BankRow[] }) {
  const [search, setSearch] = useState("");
  const [status, setStatus] = useState("all");
  const [country, setCountry] = useState("all");

  const countries = useMemo(
    () => Array.from(new Set(banks.map((b) => b.country_code).filter(Boolean) as string[])).sort(),
    [banks],
  );

  const visible = useMemo(() => {
    const q = search.trim().toLowerCase();
    return banks.filter((b) => {
      if (status === "active" && !b.is_active) return false;
      if (status === "inactive" && b.is_active) return false;
      if (country !== "all" && b.country_code !== country) return false;
      if (!q) return true;
      return (
        (b.name_ar ?? "").toLowerCase().includes(q) ||
        (b.name_en ?? "").toLowerCase().includes(q) ||
        (b.short_code ?? "").toLowerCase().includes(q) ||
        b.senders.some((s) => s.toLowerCase().includes(q))
      );
    });
  }, [banks, search, status, country]);

  const paged = usePagination(visible, 25);

  const filtering = search.trim() !== "" || status !== "all" || country !== "all";

  return (
    <div className="space-y-4">
      <FilterBar
        search={search}
        onSearch={setSearch}
        placeholder="ابحث باسم البنك أو رمزه أو رقم المُرسِل…"
        resultLabel={`${fmt(visible.length)} من ${fmt(banks.length)}`}
      >
        <FilterSelect
          label="الحالة"
          value={status}
          onChange={setStatus}
          options={[
            { value: "all", label: "كل الحالات" },
            { value: "active", label: "مفعّل" },
            { value: "inactive", label: "متوقف" },
          ]}
        />
        <FilterSelect
          label="الدولة"
          value={country}
          onChange={setCountry}
          options={[
            { value: "all", label: "كل الدول" },
            ...countries.map((c) => ({ value: c, label: c })),
          ]}
        />
      </FilterBar>

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
            "البنك",
            "الرمز",
            "الدولة",
            "أرقام المُرسِل",
            "الحالة",
            { label: "إجراء", align: "end" },
          ]}
        />
        <TBody>
          {paged.slice.map((bank) => (
            <TR key={bank.id}>
              <TD>
                <NameCell title={bank.name_ar ?? "—"} subtitle={bank.name_en ?? undefined} />
              </TD>
              <TD className="ltr font-mono text-tiny text-ink-soft">{bank.short_code ?? "—"}</TD>
              <TD className="text-ink-soft">{bank.country_code ?? "—"}</TD>
              <TD>
                {bank.senders.length === 0 ? (
                  <span className="text-tiny text-ink-faint">لم تُضَف بعد</span>
                ) : (
                  <div className="flex flex-wrap gap-1">
                    {bank.senders.slice(0, 3).map((s) => (
                      <span
                        key={s}
                        className="ltr rounded bg-muted px-1.5 py-0.5 font-mono text-micro text-ink-soft"
                      >
                        {s}
                      </span>
                    ))}
                    {bank.senders.length > 3 && (
                      <span
                        className="tnum rounded bg-muted px-1.5 py-0.5 text-micro text-ink-faint"
                        title={bank.senders.join("، ")}
                      >
                        +{bank.senders.length - 3}
                      </span>
                    )}
                  </div>
                )}
              </TD>
              <TD>
                <StatusBadge
                  label={bank.is_active ? "مفعّل" : "متوقف"}
                  tone={bank.is_active ? "success" : "neutral"}
                />
              </TD>
              <TD align="end">
                <Link
                  href={`/banks/${bank.id}`}
                  aria-label={`تعديل ${bank.name_ar ?? ""}`}
                  className="inline-flex items-center gap-1.5 rounded-field border border-line px-2.5 py-1.5 text-tiny text-ink-soft transition-colors hover:border-brand-300 hover:bg-brand-50 hover:text-brand-900"
                >
                  <Pencil size={13} />
                  تعديل
                </Link>
              </TD>
            </TR>
          ))}

          {visible.length === 0 && (
            <TEmpty colSpan={6}>
              {filtering ? (
                <EmptyState
                  title="لا توجد نتائج مطابقة"
                  description="جرّب كلمة بحث أخرى أو أعِد ضبط عوامل التصفية."
                />
              ) : (
                <EmptyState
                  icon={Building2}
                  title="لا توجد بنوك في الكتالوج"
                  description="أضف أول بنك حتى يستطيع التطبيق التعرّف على رسائله."
                />
              )}
            </TEmpty>
          )}
        </TBody>
      </DataTable>
    </div>
  );
}
