"use client";

import { useEffect, useState } from "react";
import { AlertTriangle } from "lucide-react";
import { Button } from "@/components/ui/form";
import { cn } from "@/lib/utils";

export type ConfirmSpec = {
  /** What the operator is about to do, in plain Arabic. */
  title: string;
  /** What will actually happen — consequences, not "هل أنت متأكد؟". */
  consequence: React.ReactNode;
  /** Label of the button that performs the action. */
  confirmLabel: string;
  tone?: "danger" | "warning" | "brand";
  /**
   * When set, the operator must type this exact text to enable the button.
   * Reserved for irreversible operations.
   */
  typeToConfirm?: string;
  typeToConfirmLabel?: string;
};

/**
 * Consequence-focused confirmation. Purely presentational: it decides *whether*
 * `onConfirm` runs, never *what* it does. The caller keeps ownership of the
 * mutation, its operation_id and its retry semantics.
 */
export function ConfirmDialog({
  spec,
  onConfirm,
  onCancel,
  busy,
}: {
  spec: ConfirmSpec | null;
  onConfirm: () => void;
  onCancel: () => void;
  busy?: boolean;
}) {
  const [typed, setTyped] = useState("");

  useEffect(() => {
    setTyped("");
  }, [spec]);

  useEffect(() => {
    if (!spec) return;
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape" && !busy) onCancel();
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [spec, busy, onCancel]);

  if (!spec) return null;

  const tone = spec.tone ?? "danger";
  const locked = Boolean(spec.typeToConfirm) && typed.trim() !== spec.typeToConfirm;

  return (
    <div
      className="fixed inset-0 z-50 flex items-center justify-center bg-brand-deep/45 p-4 backdrop-blur-sm"
      role="dialog"
      aria-modal="true"
      aria-labelledby="confirm-title"
    >
      <div className="w-full max-w-md rounded-card border border-hairline bg-surface p-6 shadow-pop">
        <div className="flex items-start gap-3.5">
          <span
            className={cn(
              "shrink-0 rounded-field p-2.5",
              tone === "danger"
                ? "bg-danger-bg text-danger"
                : tone === "warning"
                  ? "bg-warning-bg text-warning"
                  : "bg-brand-100 text-brand-900",
            )}
          >
            <AlertTriangle size={18} />
          </span>
          <div className="min-w-0">
            <h2 id="confirm-title" className="text-lg font-semibold text-ink">
              {spec.title}
            </h2>
            <div className="mt-2 text-sm leading-relaxed text-ink-soft">{spec.consequence}</div>
          </div>
        </div>

        {spec.typeToConfirm && (
          <label className="mt-5 block">
            <span className="mb-1.5 block text-tiny font-medium text-ink">
              {spec.typeToConfirmLabel ?? "اكتب المعرّف التالي للتأكيد:"}{" "}
              <code className="ltr rounded bg-muted px-1.5 py-0.5 font-mono text-micro text-ink">
                {spec.typeToConfirm}
              </code>
            </span>
            <input
              value={typed}
              onChange={(e) => setTyped(e.target.value)}
              autoFocus
              className="ltr w-full rounded-field border border-line bg-surface px-3 py-2.5 font-mono text-tiny text-ink focus:border-brand-500 focus:outline-none focus:ring-2 focus:ring-brand-500/25"
            />
          </label>
        )}

        <div className="mt-6 flex justify-end gap-2.5">
          <Button variant="secondary" onClick={onCancel} disabled={busy}>
            إلغاء
          </Button>
          <Button
            variant={tone === "brand" ? "primary" : "danger"}
            onClick={onConfirm}
            loading={busy}
            disabled={locked}
            className={tone === "danger" ? "border-danger bg-danger text-white hover:bg-danger/90" : undefined}
          >
            {spec.confirmLabel}
          </Button>
        </div>
      </div>
    </div>
  );
}
