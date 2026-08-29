"use client";

import Image from "next/image";
import { useState } from "react";
import { useRouter } from "next/navigation";
import { LogIn, ShieldCheck } from "lucide-react";
import { createClient } from "@/lib/supabase";

/**
 * Arabic error copy for the authentication failures an operator can actually
 * hit. Authentication behaviour itself is untouched — this only replaces the
 * raw English message from the auth service with something readable, and falls
 * back to the original text for anything unrecognised.
 */
function arabicAuthError(message: string): string {
  const m = message.toLowerCase();
  if (m.includes("invalid login credentials")) return "البريد الإلكتروني أو كلمة المرور غير صحيحة.";
  if (m.includes("email not confirmed")) return "لم يتم تأكيد هذا البريد الإلكتروني بعد.";
  if (m.includes("rate limit") || m.includes("too many"))
    return "محاولات كثيرة خلال وقت قصير. انتظر قليلًا ثم أعد المحاولة.";
  if (m.includes("failed to fetch") || m.includes("network"))
    return "تعذّر الاتصال بالخادم. تأكد من أن الخدمة تعمل ثم أعد المحاولة.";
  return message;
}

export default function LoginPage() {
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [error, setError] = useState("");
  const [loading, setLoading] = useState(false);
  const router = useRouter();
  const supabase = createClient();

  async function handleLogin(e: React.FormEvent) {
    e.preventDefault();
    setLoading(true);
    setError("");
    const { error } = await supabase.auth.signInWithPassword({ email, password });
    if (error) {
      setError(arabicAuthError(error.message));
      setLoading(false);
    } else {
      const response = await fetch("/api/admin-session", { cache: "no-store" });
      router.push(response.ok ? "/dashboard" : "/not-authorized");
      router.refresh();
    }
  }

  return (
    <div className="relative flex min-h-screen items-center justify-center overflow-hidden bg-gradient-to-b from-brand-deep via-brand-900 to-brand-800 p-6">
      {/* Calm Capital aurora — the same soft brand glow the app paints. */}
      <div className="pointer-events-none absolute -top-40 start-1/3 h-[520px] w-[520px] rounded-full bg-brand-500/20 blur-[120px]" />
      <div className="pointer-events-none absolute -bottom-40 end-1/4 h-[420px] w-[420px] rounded-full bg-brand-400/10 blur-[120px]" />

      <div className="relative w-full max-w-[400px]">
        <div className="mb-7 flex flex-col items-center text-center">
          {/* The dark-canvas lockup — same rule the app uses in AppAssets:
              the navy-tagline variant is for light surfaces only. */}
          <Image
            src="/brand/qirsh-lockup-dark.png"
            alt="قِرش — كل قرش محسوب"
            width={190}
            height={195}
            className="mb-4 drop-shadow-lg"
            priority
          />
          <span className="inline-flex items-center gap-1.5 rounded-full bg-white/10 px-3 py-1 text-tiny font-medium text-white/85 ring-1 ring-inset ring-white/15">
            <ShieldCheck size={13} />
            بوابة الإدارة
          </span>
        </div>

        <div className="rounded-card border border-white/10 bg-surface p-7 shadow-pop">
          <h1 className="text-xl font-semibold text-ink">تسجيل الدخول</h1>
          <p className="mt-1.5 text-sm text-ink-soft">
            هذه اللوحة مخصّصة لفريق إدارة قِرش فقط. الحسابات العادية لا تستطيع الدخول إليها.
          </p>

          <form onSubmit={handleLogin} className="mt-6 space-y-4">
            <div>
              <label htmlFor="email" className="mb-1.5 block text-tiny font-medium text-ink">
                البريد الإلكتروني <span className="text-danger">*</span>
              </label>
              <input
                id="email"
                type="email"
                dir="ltr"
                value={email}
                onChange={(e) => setEmail(e.target.value)}
                required
                autoComplete="username"
                placeholder="you@example.com"
                className="w-full rounded-field border border-line bg-surface px-3 py-2.5 text-start text-sm text-ink placeholder:text-ink-faint focus:border-brand-500 focus:outline-none focus:ring-2 focus:ring-brand-500/25"
              />
            </div>

            <div>
              <label htmlFor="password" className="mb-1.5 block text-tiny font-medium text-ink">
                كلمة المرور <span className="text-danger">*</span>
              </label>
              <input
                id="password"
                type="password"
                dir="ltr"
                value={password}
                onChange={(e) => setPassword(e.target.value)}
                required
                autoComplete="current-password"
                className="w-full rounded-field border border-line bg-surface px-3 py-2.5 text-start text-sm text-ink focus:border-brand-500 focus:outline-none focus:ring-2 focus:ring-brand-500/25"
              />
            </div>

            {error && (
              <p role="alert" className="rounded-field bg-danger-bg px-3 py-2.5 text-sm text-danger">
                {error}
              </p>
            )}

            <button
              type="submit"
              disabled={loading}
              className="flex w-full items-center justify-center gap-2 rounded-field bg-brand-700 py-3 text-sm font-medium text-white transition-colors hover:bg-brand-800 disabled:opacity-50"
            >
              <LogIn size={15} className="flip-x" />
              {loading ? "جارٍ الدخول…" : "دخول"}
            </button>
          </form>
        </div>

        <p className="mt-5 text-center text-micro text-white/45">كل قرش محسوب</p>
      </div>
    </div>
  );
}
