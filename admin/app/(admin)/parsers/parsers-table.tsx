"use client";

import Link from "next/link";
import { useMemo, useState } from "react";
import { Pencil, ScanText } from "lucide-react";
import { DataTable, NameCell, TBody, TD, TEmpty, THead, TR } from "@/components/ui/table";
import { EmptyState, StatusBadge } from "@/components/ui/primitives";
import { FilterBar, FilterSelect } from "@/components/ui/filter-bar";
import { Pagination, usePagination } from "@/components/ui/pagination";
import {
  languageLabel,
  txnTypeLabel,
  txnTypeTone,
  validationLabel,
  validationTone,
} from "@/lib/labels";
import { fmt } from "@/lib/utils";

export type ParserRow = {
  id: string;
  bank_name: string | null;
  bank_code: string | null;
  sender_pattern: string | null;
  transaction_type: string | null;
  language: string | null;
  priority: number | null;
  validation_status: string;
  is_active: boolean;
};

export function ParsersTable({ parsers }: { parsers: ParserRow[] }) {
  const [search, setSearch] = useState("");
  const [status, setStatus] = useState("all");
  const [type, setType] = useState("all");

  const visible = useMemo(() => {
    const q = search.trim().toLowerCase();
    return parsers.filter((p) => {
      if (status !== "all" && p.validation_status !== status) return false;
      if (type !== "all" && p.transaction_type !== type) return false;
      if (!q) return true;
      return (
        (p.bank_name ?? "").toLowerCase().includes(q) ||
        (p.bank_code ?? "").toLowerCase().includes(q) ||
        (p.sender_pattern ?? "").toLowerCase().includes(q)
      );
    });
  }, [parsers, search, status, type]);

  const paged = usePagination(visible, 25);

  const filtering = search.trim() !== "" || status !== "all" || type !== "all";

  return (
    <div className="space-y-4">
      <FilterBar
        search={search}
        onSearch={setSearch}
        placeholder="ابحث باسم البنك أو نمط المُرسِل…"
        resultLabel={`${fmt(visible.length)} من ${fmt(parsers.length)}`}
      >
        <FilterSelect
          label="حالة الفحص"
          value={status}
          onChange={setStatus}
          options={[
            { value: "all", label: "كل حالات الفحص" },
            { value: "passed", label: "اجتازت الفحص" },
            { value: "pending", label: "بانتظار الفحص" },
            { value: "failed", label: "فشل الفحص" },
          ]}
        />
        <FilterSelect
          label="نوع العملية"
          value={type}
          onChange={setType}
          options={[
            { value: "all", label: "كل الأنواع" },
            { value: "debit", label: "خصم" },
            { value: "credit", label: "إيداع" },
            { value: "balance_inquiry", label: "استعلام رصيد" },
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
            "نمط المُرسِل",
            "نوع العملية",
            "اللغة",
            "الأولوية",
            "حالة الفحص",
            { label: "إجراء", align: "end" },
          ]}
        />
        <TBody>
          {paged.slice.map((p) => (
            <TR key={p.id}>
              <TD>
                <NameCell title={p.bank_name ?? "—"} subtitle={p.bank_code ?? undefined} mono />
              </TD>
              <TD>
                <span
                  className="ltr block max-w-[230px] truncate rounded bg-muted px-1.5 py-0.5 font-mono text-micro text-ink-soft"
                  title={p.sender_pattern ?? ""}
                >
                  {p.sender_pattern ?? "—"}
                </span>
              </TD>
              <TD>
                <StatusBadge
                  label={txnTypeLabel(p.transaction_type)}
                  tone={txnTypeTone(p.transaction_type)}
                  dot={false}
                />
              </TD>
              <TD className="text-ink-soft">{languageLabel(p.language)}</TD>
              <TD className="tnum text-ink-soft">{p.priority ?? 0}</TD>
              <TD>
                <div className="flex flex-wrap items-center gap-1.5">
                  <StatusBadge
                    label={validationLabel(p.validation_status)}
                    tone={validationTone(p.validation_status)}
                  />
                  {!p.is_active && <StatusBadge label="متوقفة" tone="neutral" dot={false} />}
                </div>
              </TD>
              <TD align="end">
                <Link
                  href={`/parsers/${p.id}`}
                  aria-label="تعديل القاعدة"
                  className="inline-flex items-center gap-1.5 rounded-field border border-line px-2.5 py-1.5 text-tiny text-ink-soft transition-colors hover:border-brand-300 hover:bg-brand-50 hover:text-brand-900"
                >
                  <Pencil size={13} />
                  تعديل
                </Link>
              </TD>
            </TR>
          ))}

          {visible.length === 0 && (
            <TEmpty colSpan={7}>
              {filtering ? (
                <EmptyState
                  title="لا توجد قواعد مطابقة"
                  description="جرّب كلمة بحث أخرى أو أعِد ضبط عوامل التصفية."
                />
              ) : (
                <EmptyState
                  icon={ScanText}
                  title="لا توجد قواعد قراءة بعد"
                  description="أضف أول قاعدة حتى يستطيع التطبيق تحويل رسائل البنك إلى عمليات."
                />
              )}
            </TEmpty>
          )}
        </TBody>
      </DataTable>
    </div>
  );
}
