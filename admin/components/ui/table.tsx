import { cn } from "@/lib/utils";

/**
 * The one table treatment. Compact, RTL-aware (all alignment uses logical
 * `start`/`end`), with a caller-supplied Arabic header per column.
 */
export function DataTable({
  children,
  footer,
  className,
}: {
  children: React.ReactNode;
  /** Rendered under the table inside the same card — e.g. pagination. */
  footer?: React.ReactNode;
  className?: string;
}) {
  return (
    <div className={cn("rounded-card border border-hairline bg-surface shadow-card", className)}>
      {/* Only the table scrolls sideways; the page itself never does. */}
      <div className="overflow-x-auto">
        <table className="w-full text-sm">{children}</table>
      </div>
      {footer}
    </div>
  );
}

export function THead({ columns }: { columns: (string | { label: string; align?: "end" })[] }) {
  return (
    <thead>
      <tr className="border-b border-divider bg-raised/60">
        {columns.map((c, i) => {
          const label = typeof c === "string" ? c : c.label;
          const align = typeof c === "string" ? undefined : c.align;
          return (
            <th
              key={`${label}-${i}`}
              scope="col"
              className={cn(
                "whitespace-nowrap px-4 py-3 text-tiny font-semibold text-ink-soft",
                align === "end" ? "text-end" : "text-start",
              )}
            >
              {label}
            </th>
          );
        })}
      </tr>
    </thead>
  );
}

export function TBody({ children }: { children: React.ReactNode }) {
  return <tbody className="divide-y divide-divider">{children}</tbody>;
}

export function TR({ children, className }: { children: React.ReactNode; className?: string }) {
  return <tr className={cn("transition-colors hover:bg-raised/50", className)}>{children}</tr>;
}

export function TD({
  children,
  className,
  align,
  colSpan,
}: {
  children?: React.ReactNode;
  className?: string;
  align?: "end";
  colSpan?: number;
}) {
  return (
    <td
      colSpan={colSpan}
      className={cn("px-4 py-3 align-middle text-ink", align === "end" ? "text-end" : "text-start", className)}
    >
      {children}
    </td>
  );
}

/** Full-width row used for the empty / no-results state inside a table. */
export function TEmpty({ colSpan, children }: { colSpan: number; children: React.ReactNode }) {
  return (
    <tr>
      <td colSpan={colSpan} className="px-4 py-0">
        {children}
      </td>
    </tr>
  );
}

/** Two-line cell: the human name on top, the technical identity underneath. */
export function NameCell({ title, subtitle, mono }: { title: string; subtitle?: string; mono?: boolean }) {
  return (
    <div className="min-w-0">
      <div className="truncate font-medium text-ink">{title}</div>
      {subtitle && (
        <div className={cn("truncate text-micro text-ink-faint", mono && "ltr font-mono")}>{subtitle}</div>
      )}
    </div>
  );
}
