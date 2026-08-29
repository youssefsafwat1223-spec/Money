"use client";

import { useState } from "react";
import { Check, Copy } from "lucide-react";
import { cn } from "@/lib/utils";

/**
 * A technical identifier shown as a short, copyable chip instead of a raw UUID
 * taking over the row. The full value is always what gets copied.
 */
export function CopyId({
  value,
  label,
  length = 8,
  className,
}: {
  value: string | null | undefined;
  label?: string;
  length?: number;
  className?: string;
}) {
  const [copied, setCopied] = useState(false);
  if (!value) return <span className="text-ink-faint">—</span>;

  async function copy() {
    try {
      await navigator.clipboard.writeText(value!);
      setCopied(true);
      setTimeout(() => setCopied(false), 1400);
    } catch {
      /* clipboard unavailable (insecure context) — the chip still shows the id */
    }
  }

  return (
    <button
      type="button"
      onClick={copy}
      title={`${label ? `${label}: ` : ""}${value} — اضغط للنسخ`}
      className={cn(
        "inline-flex items-center gap-1.5 rounded-md bg-muted px-1.5 py-0.5 text-micro text-ink-soft transition-colors hover:bg-brand-100 hover:text-brand-900",
        className,
      )}
    >
      <span className="ltr font-mono">{value.slice(0, length)}</span>
      {copied ? <Check size={11} className="text-success" /> : <Copy size={11} className="opacity-60" />}
    </button>
  );
}
