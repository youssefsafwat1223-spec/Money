"use client";

import { Search, X } from "lucide-react";
import { cn } from "@/lib/utils";

/** Search box + inline selects, sharing one row above a table. */
export function FilterBar({
  search,
  onSearch,
  placeholder = "ابحث…",
  children,
  resultLabel,
  className,
}: {
  search: string;
  onSearch: (v: string) => void;
  placeholder?: string;
  children?: React.ReactNode;
  resultLabel?: string;
  className?: string;
}) {
  return (
    <div className={cn("flex flex-wrap items-center gap-2.5", className)}>
      <div className="relative min-w-[220px] flex-1">
        <Search
          size={15}
          className="pointer-events-none absolute inset-y-0 start-3 my-auto text-ink-faint"
        />
        <input
          value={search}
          onChange={(e) => onSearch(e.target.value)}
          placeholder={placeholder}
          aria-label={placeholder}
          className="w-full rounded-field border border-line bg-surface py-2.5 pe-9 ps-9 text-sm text-ink placeholder:text-ink-faint focus:border-brand-500 focus:outline-none focus:ring-2 focus:ring-brand-500/25"
        />
        {search && (
          <button
            type="button"
            onClick={() => onSearch("")}
            aria-label="مسح البحث"
            className="absolute inset-y-0 end-2.5 my-auto h-5 text-ink-faint hover:text-ink"
          >
            <X size={15} />
          </button>
        )}
      </div>
      {children}
      {resultLabel && (
        <span className="tnum whitespace-nowrap text-tiny text-ink-faint">{resultLabel}</span>
      )}
    </div>
  );
}

/** Compact select used inside a {@link FilterBar}. Options carry Arabic labels. */
export function FilterSelect({
  label,
  value,
  options,
  onChange,
}: {
  label: string;
  value: string;
  options: { value: string; label: string }[];
  onChange: (v: string) => void;
}) {
  return (
    <select
      aria-label={label}
      value={value}
      onChange={(e) => onChange(e.target.value)}
      className="cursor-pointer rounded-field border border-line bg-surface px-3 py-2.5 text-sm text-ink focus:border-brand-500 focus:outline-none focus:ring-2 focus:ring-brand-500/25"
    >
      {options.map((o) => (
        <option key={o.value} value={o.value}>
          {o.label}
        </option>
      ))}
    </select>
  );
}
