import { cn } from "@/lib/utils";
import type { LucideIcon } from "lucide-react";
import { AlertTriangle, Info, Inbox, Loader2, ShieldAlert } from "lucide-react";

/* ────────────────────────────────────────────────────────────── surfaces ── */

/** The one card surface. Calm Capital: white, hairline edge, soft navy float. */
export function Card({
  className,
  children,
  padded = true,
  ...rest
}: React.HTMLAttributes<HTMLDivElement> & { padded?: boolean }) {
  return (
    <div
      className={cn(
        "rounded-card border border-hairline bg-surface shadow-card",
        padded && "p-5",
        className,
      )}
      {...rest}
    >
      {children}
    </div>
  );
}

/** Title + optional one-line purpose, used at the top of a card or section. */
export function SectionHeader({
  title,
  description,
  icon: Icon,
  action,
  className,
}: {
  title: string;
  description?: string;
  icon?: LucideIcon;
  action?: React.ReactNode;
  className?: string;
}) {
  return (
    <div className={cn("mb-4 flex items-start justify-between gap-4", className)}>
      <div className="min-w-0">
        <h2 className="flex items-center gap-2 text-lg font-semibold text-ink">
          {Icon && <Icon size={17} className="shrink-0 text-brand-700" />}
          {title}
        </h2>
        {description && <p className="mt-1 text-sm text-ink-soft">{description}</p>}
      </div>
      {action && <div className="shrink-0">{action}</div>}
    </div>
  );
}

/** Page title block. `eyebrow` names the area the page belongs to. */
export function PageHeader({
  eyebrow,
  title,
  description,
  action,
}: {
  eyebrow?: string;
  title: string;
  description?: string;
  action?: React.ReactNode;
}) {
  return (
    <header className="flex flex-wrap items-end justify-between gap-4">
      <div className="min-w-0">
        {eyebrow && (
          <p className="mb-1 text-tiny font-semibold tracking-wide text-brand-700">{eyebrow}</p>
        )}
        <h1 className="text-2xl font-semibold text-ink">{title}</h1>
        {description && <p className="mt-1.5 max-w-2xl text-sm text-ink-soft">{description}</p>}
      </div>
      {action && <div className="shrink-0">{action}</div>}
    </header>
  );
}

/* ──────────────────────────────────────────────────────────────── status ── */

export type Tone = "neutral" | "success" | "warning" | "danger" | "info" | "brand";

const TONE: Record<Tone, string> = {
  neutral: "bg-muted text-ink-soft",
  success: "bg-success-bg text-success",
  warning: "bg-warning-bg text-warning",
  danger: "bg-danger-bg text-danger",
  info: "bg-info-bg text-info",
  brand: "bg-brand-100 text-brand-900",
};

/** A state, said in words — never a raw enum value from the database. */
export function StatusBadge({
  label,
  tone = "neutral",
  dot = true,
  className,
}: {
  label: string;
  tone?: Tone;
  dot?: boolean;
  className?: string;
}) {
  return (
    <span
      className={cn(
        "inline-flex items-center gap-1.5 whitespace-nowrap rounded-full px-2.5 py-1 text-tiny font-medium",
        TONE[tone],
        className,
      )}
    >
      {dot && <span className="h-1.5 w-1.5 shrink-0 rounded-full bg-current opacity-70" />}
      {label}
    </span>
  );
}

/** A single headline number with the sentence that explains what it counts. */
export function StatCard({
  label,
  value,
  hint,
  icon: Icon,
  tone = "brand",
}: {
  label: string;
  value: string | number;
  hint?: string;
  icon?: LucideIcon;
  tone?: Tone;
}) {
  return (
    <Card className="flex items-start gap-3.5">
      {Icon && (
        <span className={cn("mt-0.5 shrink-0 rounded-field p-2.5", TONE[tone])}>
          <Icon size={17} />
        </span>
      )}
      <div className="min-w-0">
        <p className="tnum text-2xl font-semibold leading-none text-ink">{value}</p>
        <p className="mt-1.5 text-sm font-medium text-ink">{label}</p>
        {hint && <p className="mt-0.5 text-tiny text-ink-faint">{hint}</p>}
      </div>
    </Card>
  );
}

/* ──────────────────────────────────────────────────────────── messaging ── */

/** Short explanatory note. Use where a misunderstanding would be likely. */
export function HelpNote({
  children,
  tone = "info",
  className,
}: {
  children: React.ReactNode;
  tone?: "info" | "warning";
  className?: string;
}) {
  return (
    <p
      className={cn(
        "flex items-start gap-2 rounded-field px-3 py-2.5 text-tiny leading-relaxed",
        tone === "warning" ? "bg-warning-bg text-warning" : "bg-info-bg text-brand-800",
        className,
      )}
    >
      {tone === "warning" ? (
        <AlertTriangle size={14} className="mt-0.5 shrink-0" />
      ) : (
        <Info size={14} className="mt-0.5 shrink-0" />
      )}
      <span className="min-w-0">{children}</span>
    </p>
  );
}

/** Result of an action: a green confirmation or a red failure. */
export function Banner({
  tone,
  children,
  onDismiss,
}: {
  tone: "success" | "danger";
  children: React.ReactNode;
  onDismiss?: () => void;
}) {
  return (
    <div
      role={tone === "danger" ? "alert" : "status"}
      className={cn(
        "flex items-start justify-between gap-4 rounded-field border px-4 py-3 text-sm",
        tone === "danger"
          ? "border-danger/20 bg-danger-bg text-danger"
          : "border-success/20 bg-success-bg text-success",
      )}
    >
      <span className="min-w-0">{children}</span>
      {onDismiss && (
        <button
          type="button"
          onClick={onDismiss}
          className="shrink-0 text-tiny font-medium underline underline-offset-2 opacity-80 hover:opacity-100"
        >
          إخفاء
        </button>
      )}
    </div>
  );
}

/* ─────────────────────────────────────────────────────────────── states ── */

export function LoadingState({ label = "جارٍ التحميل…" }: { label?: string }) {
  return (
    <div className="flex items-center justify-center gap-2.5 py-14 text-sm text-ink-faint">
      <Loader2 size={16} className="animate-spin" />
      {label}
    </div>
  );
}

export function EmptyState({
  title,
  description,
  icon: Icon = Inbox,
  action,
}: {
  title: string;
  description?: string;
  icon?: LucideIcon;
  action?: React.ReactNode;
}) {
  return (
    <div className="flex flex-col items-center justify-center px-6 py-14 text-center">
      <span className="mb-3 rounded-2xl bg-muted p-3.5 text-ink-faint">
        <Icon size={22} />
      </span>
      <p className="text-sm font-semibold text-ink">{title}</p>
      {description && <p className="mt-1.5 max-w-sm text-tiny text-ink-faint">{description}</p>}
      {action && <div className="mt-4">{action}</div>}
    </div>
  );
}

/**
 * A failure the operator can act on. `detail` carries the technical text so it
 * stays visible to whoever is diagnosing, under a plain Arabic headline.
 */
export function ErrorState({
  title = "تعذّر تحميل هذا القسم",
  detail,
  action,
}: {
  title?: string;
  detail?: string;
  action?: React.ReactNode;
}) {
  return (
    <div className="flex flex-col items-center justify-center px-6 py-12 text-center">
      <span className="mb-3 rounded-2xl bg-danger-bg p-3.5 text-danger">
        <AlertTriangle size={22} />
      </span>
      <p className="text-sm font-semibold text-ink">{title}</p>
      {detail && (
        <p className="ltr mt-2 max-w-lg rounded-field bg-muted px-3 py-2 text-micro text-ink-faint">
          {detail}
        </p>
      )}
      {action && <div className="mt-4">{action}</div>}
    </div>
  );
}

export function PermissionDenied({ detail }: { detail?: string }) {
  return (
    <div className="flex flex-col items-center justify-center px-6 py-12 text-center">
      <span className="mb-3 rounded-2xl bg-warning-bg p-3.5 text-warning">
        <ShieldAlert size={22} />
      </span>
      <p className="text-sm font-semibold text-ink">لا تملك صلاحية عرض هذا القسم</p>
      <p className="mt-1.5 max-w-sm text-tiny text-ink-faint">
        {detail ?? "تواصل مع مسؤول النظام إذا كنت تعتقد أن هذا خطأ."}
      </p>
    </div>
  );
}
