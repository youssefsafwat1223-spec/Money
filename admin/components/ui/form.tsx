"use client";

import { useId } from "react";
import { cn } from "@/lib/utils";
import type { LucideIcon } from "lucide-react";
import { Loader2 } from "lucide-react";

/* ─────────────────────────────────────────────────────────────── buttons ── */

type Variant = "primary" | "secondary" | "ghost" | "danger";

const VARIANT: Record<Variant, string> = {
  primary: "bg-brand-700 text-white hover:bg-brand-800 shadow-sm",
  secondary: "border border-line bg-surface text-ink hover:bg-raised",
  ghost: "text-ink-soft hover:bg-muted hover:text-ink",
  danger: "border border-danger/25 bg-danger-bg text-danger hover:bg-danger hover:text-white",
};

export function Button({
  variant = "primary",
  size = "md",
  icon: Icon,
  loading,
  className,
  children,
  disabled,
  ...rest
}: React.ButtonHTMLAttributes<HTMLButtonElement> & {
  variant?: Variant;
  size?: "sm" | "md";
  icon?: LucideIcon;
  loading?: boolean;
}) {
  return (
    <button
      {...rest}
      disabled={disabled || loading}
      className={cn(
        "inline-flex items-center justify-center gap-2 rounded-field font-medium transition-colors disabled:cursor-not-allowed disabled:opacity-50",
        size === "sm" ? "px-3 py-1.5 text-tiny" : "px-4 py-2.5 text-sm",
        VARIANT[variant],
        className,
      )}
    >
      {loading ? (
        <Loader2 size={size === "sm" ? 13 : 15} className="animate-spin" />
      ) : (
        Icon && <Icon size={size === "sm" ? 13 : 15} />
      )}
      {children}
    </button>
  );
}

/* ──────────────────────────────────────────────────────────────── fields ── */

const CONTROL =
  "w-full rounded-field border border-line bg-surface px-3 py-2.5 text-sm text-ink " +
  "placeholder:text-ink-faint transition-colors hover:border-brand-300 " +
  "focus:border-brand-500 focus:outline-none focus:ring-2 focus:ring-brand-500/25 " +
  "disabled:cursor-not-allowed disabled:bg-muted disabled:text-ink-faint";

/** Label + required marker + helper text + validation message, in Arabic. */
export function Field({
  label,
  hint,
  error,
  required,
  htmlFor,
  children,
  className,
}: {
  label: string;
  hint?: string;
  error?: string;
  required?: boolean;
  htmlFor?: string;
  children: React.ReactNode;
  className?: string;
}) {
  return (
    <div className={cn("min-w-0", className)}>
      <label htmlFor={htmlFor} className="mb-1.5 block text-tiny font-medium text-ink">
        {label}
        {required && (
          <span className="ms-1 text-danger" title="حقل مطلوب">
            *
          </span>
        )}
      </label>
      {children}
      {error ? (
        <p className="mt-1.5 text-micro text-danger">{error}</p>
      ) : (
        hint && <p className="mt-1.5 text-micro leading-relaxed text-ink-faint">{hint}</p>
      )}
    </div>
  );
}

export function TextField({
  label,
  hint,
  error,
  required,
  mono,
  className,
  ...rest
}: React.InputHTMLAttributes<HTMLInputElement> & {
  label: string;
  hint?: string;
  error?: string;
  mono?: boolean;
}) {
  const id = useId();
  return (
    <Field label={label} hint={hint} error={error} required={required} htmlFor={id} className={className}>
      <input
        id={id}
        {...rest}
        className={cn(CONTROL, mono && "ltr font-mono text-tiny", error && "border-danger")}
      />
    </Field>
  );
}

export function TextAreaField({
  label,
  hint,
  error,
  required,
  mono,
  rows = 3,
  className,
  ...rest
}: React.TextareaHTMLAttributes<HTMLTextAreaElement> & {
  label: string;
  hint?: string;
  error?: string;
  mono?: boolean;
}) {
  const id = useId();
  return (
    <Field label={label} hint={hint} error={error} required={required} htmlFor={id} className={className}>
      <textarea
        id={id}
        rows={rows}
        {...rest}
        className={cn(CONTROL, "resize-y", mono && "ltr font-mono text-tiny", error && "border-danger")}
      />
    </Field>
  );
}

/**
 * A select whose options carry Arabic labels. Callers pass
 * `{ value, label }` so a database enum never becomes the visible text.
 */
export function SelectField({
  label,
  hint,
  error,
  required,
  options,
  placeholder,
  className,
  ...rest
}: Omit<React.SelectHTMLAttributes<HTMLSelectElement>, "children"> & {
  label: string;
  hint?: string;
  error?: string;
  options: { value: string; label: string }[];
  placeholder?: string;
}) {
  const id = useId();
  return (
    <Field label={label} hint={hint} error={error} required={required} htmlFor={id} className={className}>
      <select id={id} {...rest} className={cn(CONTROL, "cursor-pointer", error && "border-danger")}>
        {placeholder && <option value="">{placeholder}</option>}
        {options.map((o) => (
          <option key={o.value} value={o.value}>
            {o.label}
          </option>
        ))}
      </select>
    </Field>
  );
}

export function CheckboxField({
  label,
  hint,
  checked,
  onChange,
  disabled,
}: {
  label: string;
  hint?: string;
  checked: boolean;
  onChange: (v: boolean) => void;
  disabled?: boolean;
}) {
  return (
    <label
      className={cn(
        "flex cursor-pointer items-start gap-2.5",
        disabled && "cursor-not-allowed opacity-60",
      )}
    >
      <input
        type="checkbox"
        checked={checked}
        disabled={disabled}
        onChange={(e) => onChange(e.target.checked)}
        className="mt-0.5 h-4 w-4 shrink-0 cursor-pointer rounded border-line accent-brand-700"
      />
      <span className="min-w-0">
        <span className="block text-sm text-ink">{label}</span>
        {hint && <span className="mt-0.5 block text-micro text-ink-faint">{hint}</span>}
      </span>
    </label>
  );
}

/** On/off switch. The knob travels toward the reading direction's end. */
export function Toggle({
  checked,
  onChange,
  disabled,
  label,
}: {
  checked: boolean;
  onChange: () => void;
  disabled?: boolean;
  label: string;
}) {
  return (
    <button
      type="button"
      role="switch"
      aria-checked={checked}
      aria-label={label}
      disabled={disabled}
      onClick={onChange}
      className={cn(
        "relative inline-flex h-6 w-11 shrink-0 items-center rounded-full transition-colors disabled:opacity-50",
        checked ? "bg-brand-700" : "bg-line",
      )}
    >
      <span
        className={cn(
          "inline-block h-4 w-4 rounded-full bg-white shadow transition-transform",
          // `translate-x` is physical, so each direction needs its own pair:
          // the knob rests at the reading START when off and travels to the END.
          checked ? "translate-x-6 rtl:translate-x-1" : "translate-x-1 rtl:translate-x-6",
        )}
      />
    </button>
  );
}
