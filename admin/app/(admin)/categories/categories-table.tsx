"use client";

import { useMemo, useState } from "react";
import { ListTree } from "lucide-react";
import { DataTable, NameCell, TBody, TD, TEmpty, THead, TR } from "@/components/ui/table";
import { EmptyState, StatusBadge } from "@/components/ui/primitives";
import { FilterBar, FilterSelect } from "@/components/ui/filter-bar";
import { Pagination, usePagination } from "@/components/ui/pagination";
import { CopyId } from "@/components/ui/copy-id";
import { categoryTypeLabel, isSentinelCategory } from "@/lib/labels";
import { fmt } from "@/lib/utils";

export type CategoryRow = {
  id: string;
  key: string;
  name_ar: string | null;
  name_en: string | null;
  type: string;
  is_active: boolean;
  color_hex: string | null;
  parent_key: string | null;
};

export function CategoriesTable({ categories }: { categories: CategoryRow[] }) {
  const [search, setSearch] = useState("");
  const [type, setType] = useState("all");
  const [status, setStatus] = useState("all");

  const types = useMemo(
    () => Array.from(new Set(categories.map((c) => c.type))).sort(),
    [categories],
  );

  const visible = useMemo(() => {
    const q = search.trim().toLowerCase();
    return categories.filter((c) => {
      if (type !== "all" && c.type !== type) return false;
      if (status === "active" && !c.is_active) return false;
      if (status === "inactive" && c.is_active) return false;
      if (!q) return true;
      return (
        (c.name_ar ?? "").toLowerCase().includes(q) ||
        (c.name_en ?? "").toLowerCase().includes(q) ||
        c.key.toLowerCase().includes(q)
      );
    });
  }, [categories, search, type, status]);

  const paged = usePagination(visible, 25);

  const filtering = search.trim() !== "" || type !== "all" || status !== "all";

  return (
    <div className="space-y-4">
      <FilterBar
        search={search}
        onSearch={setSearch}
        placeholder="ابحث باسم الفئة أو مفتاحها…"
        visibleCount={visible.length}
        totalCount={categories.length}
      >
        <FilterSelect
          label="النوع"
          value={type}
          onChange={setType}
          options={[
            { value: "all", label: "كل الأنواع" },
            ...types.map((t) => ({ value: t, label: categoryTypeLabel(t) })),
          ]}
        />
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
        <THead columns={["الفئة", "النوع", "الفئة الأعلى", "المفتاح الثابت", "الحالة"]} />
        <TBody>
          {paged.slice.map((c) => (
            <TR key={c.id}>
              <TD>
                <div className="flex items-center gap-2.5">
                  <span
                    className="h-6 w-6 shrink-0 rounded-md border border-hairline"
                    style={{ background: c.color_hex ?? "#ECEFF6" }}
                    aria-hidden
                  />
                  <NameCell title={c.name_ar ?? "—"} subtitle={c.name_en ?? undefined} />
                  {/* UX-018 — `all_expenses` is a BUDGET SCOPE sentinel, not a
                      category anything can be filed under. The app hides it
                      from every category picker (settings_screen.dart,
                      confirm_transaction_sheet.dart); Admin listed it beside 20
                      real categories with nothing to distinguish it, so an
                      operator would reasonably treat it as spendable.
                      Labelled rather than hidden: the row is real, it is what
                      an all-expenses budget stores, and an operator who finds
                      it in the data should still find it here. */}
                  {isSentinelCategory(c.key) && (
                    <StatusBadge label="ليست فئة إنفاق" tone="warning" dot={false} />
                  )}
                </div>
              </TD>
              <TD className="text-ink-soft">{categoryTypeLabel(c.type)}</TD>
              <TD className="text-ink-soft">
                {c.parent_key ? (
                  <span className="ltr font-mono text-micro">{c.parent_key}</span>
                ) : (
                  <span className="text-ink-faint">فئة رئيسية</span>
                )}
              </TD>
              <TD>
                <CopyId value={c.key} label="مفتاح الفئة" length={24} />
              </TD>
              <TD>
                <StatusBadge
                  label={c.is_active ? "مفعّلة" : "متوقفة"}
                  tone={c.is_active ? "success" : "neutral"}
                />
              </TD>
            </TR>
          ))}

          {visible.length === 0 && (
            <TEmpty colSpan={5}>
              {filtering ? (
                <EmptyState
                  title="لا توجد فئات مطابقة"
                  description="جرّب كلمة بحث أخرى أو أعِد ضبط عوامل التصفية."
                />
              ) : (
                <EmptyState
                  icon={ListTree}
                  title="لا توجد فئات في الكتالوج"
                  description="لن يستطيع التطبيق تصنيف العمليات قبل إضافة الفئات."
                />
              )}
            </TEmpty>
          )}
        </TBody>
      </DataTable>
    </div>
  );
}
