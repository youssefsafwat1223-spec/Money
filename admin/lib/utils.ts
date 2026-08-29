import { clsx, type ClassValue } from "clsx";
import { twMerge } from "tailwind-merge";

export function cn(...inputs: ClassValue[]) {
  return twMerge(clsx(inputs));
}

/**
 * Presentation-layer formatting only. Nothing here parses, rounds, converts or
 * reconstructs a stored value — a number in, a string out. Digits stay Latin
 * with `,` grouping to match the app's own `Formatters` (`en_US` NumberFormat),
 * so the same figure reads identically on phone and dashboard.
 */
export function fmt(n: number): string {
  return new Intl.NumberFormat("en-US").format(n);
}

/** Arabic month names, Latin digits — e.g. "25 أغسطس 2026". */
export function fmtDate(d: string | null | undefined): string {
  if (!d) return "—";
  const date = new Date(d);
  if (Number.isNaN(date.getTime())) return "—";
  return new Intl.DateTimeFormat("ar-EG-u-nu-latn", {
    day: "2-digit",
    month: "short",
    year: "numeric",
  }).format(date);
}

/** Same as {@link fmtDate} plus a 24-hour clock, for audit/activity lines. */
export function fmtDateTime(d: string | null | undefined): string {
  if (!d) return "—";
  const date = new Date(d);
  if (Number.isNaN(date.getTime())) return "—";
  return new Intl.DateTimeFormat("ar-EG-u-nu-latn", {
    day: "2-digit",
    month: "short",
    year: "numeric",
    hour: "2-digit",
    minute: "2-digit",
    hour12: false,
  }).format(date);
}

/** "منذ 3 ساعات" — relative time for activity feeds. */
export function fmtRelative(d: string | null | undefined): string {
  if (!d) return "—";
  const date = new Date(d);
  if (Number.isNaN(date.getTime())) return "—";
  const seconds = Math.round((date.getTime() - Date.now()) / 1000);
  const units: [Intl.RelativeTimeFormatUnit, number][] = [
    ["year", 31536000],
    ["month", 2592000],
    ["day", 86400],
    ["hour", 3600],
    ["minute", 60],
  ];
  const rtf = new Intl.RelativeTimeFormat("ar-EG-u-nu-latn", { numeric: "auto" });
  for (const [unit, size] of units) {
    if (Math.abs(seconds) >= size) return rtf.format(Math.round(seconds / size), unit);
  }
  return rtf.format(Math.round(seconds), "second");
}

/** Percentage for rollout / ratio displays. */
export function fmtPercent(ratio: number): string {
  return `${Math.round(ratio * 100)}%`;
}
