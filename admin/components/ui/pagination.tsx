"use client";

import { useEffect, useMemo, useState } from "react";
import { ChevronLeft, ChevronRight } from "lucide-react";
import { fmt } from "@/lib/utils";

/**
 * Client-side paging over an already-loaded list. Presentation only — it never
 * refetches and never changes what the server returned, it just stops a
 * 136-row catalog from rendering as one endless page.
 */
export function usePagination<T>(items: T[], pageSize = 25) {
  const [page, setPage] = useState(1);
  const pageCount = Math.max(1, Math.ceil(items.length / pageSize));

  // Any filter change can shrink the list under the current page.
  useEffect(() => {
    setPage((p) => Math.min(p, pageCount));
  }, [pageCount]);

  const slice = useMemo(
    () => items.slice((page - 1) * pageSize, page * pageSize),
    [items, page, pageSize],
  );

  return { page, setPage, pageCount, slice, total: items.length, pageSize };
}

export function Pagination({
  page,
  pageCount,
  total,
  pageSize,
  onPage,
}: {
  page: number;
  pageCount: number;
  total: number;
  pageSize: number;
  onPage: (p: number) => void;
}) {
  if (pageCount <= 1) return null;

  const first = (page - 1) * pageSize + 1;
  const last = Math.min(page * pageSize, total);

  return (
    <div className="flex flex-wrap items-center justify-between gap-3 border-t border-divider px-4 py-3">
      <p className="tnum text-tiny text-ink-faint">
        عرض {fmt(first)}–{fmt(last)} من {fmt(total)}
      </p>
      <div className="flex items-center gap-1.5">
        {/* In RTL "previous" points to the right and "next" to the left. */}
        <button
          type="button"
          onClick={() => onPage(page - 1)}
          disabled={page === 1}
          aria-label="الصفحة السابقة"
          className="rounded-field border border-line p-1.5 text-ink-soft transition-colors hover:border-brand-300 hover:bg-brand-50 disabled:cursor-not-allowed disabled:opacity-40"
        >
          <ChevronLeft size={15} className="flip-x" />
        </button>
        <span className="tnum px-2 text-tiny text-ink-soft">
          صفحة {fmt(page)} من {fmt(pageCount)}
        </span>
        <button
          type="button"
          onClick={() => onPage(page + 1)}
          disabled={page === pageCount}
          aria-label="الصفحة التالية"
          className="rounded-field border border-line p-1.5 text-ink-soft transition-colors hover:border-brand-300 hover:bg-brand-50 disabled:cursor-not-allowed disabled:opacity-40"
        >
          <ChevronRight size={15} className="flip-x" />
        </button>
      </div>
    </div>
  );
}
