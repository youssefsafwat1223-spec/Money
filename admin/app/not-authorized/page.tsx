"use client";

import Image from "next/image";
import { ShieldAlert } from "lucide-react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase";

export default function NotAuthorizedPage() {
  const router = useRouter();

  async function signOut() {
    await createClient().auth.signOut();
    router.replace("/login");
    router.refresh();
  }

  return (
    <main className="flex min-h-screen items-center justify-center bg-gradient-to-b from-brand-deep via-brand-900 to-brand-800 p-6">
      <section className="w-full max-w-md rounded-card bg-surface p-8 text-center shadow-pop">
        <Image
          src="/brand/qirsh-coin.png"
          alt="قِرش"
          width={52}
          height={52}
          className="mx-auto mb-5"
        />
        <span className="mx-auto mb-4 inline-flex rounded-2xl bg-warning-bg p-3 text-warning">
          <ShieldAlert size={22} />
        </span>
        <h1 className="text-xl font-semibold text-ink">هذا الحساب غير مصرّح له</h1>
        <p className="mx-auto mt-2.5 max-w-sm text-sm leading-relaxed text-ink-soft">
          تم تسجيل الدخول بنجاح، لكن هذا الحساب غير مضاف إلى فريق إدارة قِرش، فلا يمكنه فتح لوحة
          الإدارة. إذا كنت تعتقد أن هذا خطأ، تواصل مع مسؤول النظام لإضافة حسابك.
        </p>
        <button
          type="button"
          onClick={signOut}
          className="mt-6 w-full rounded-field bg-brand-700 px-4 py-3 text-sm font-medium text-white transition-colors hover:bg-brand-800"
        >
          تسجيل الخروج والدخول بحساب آخر
        </button>
      </section>
    </main>
  );
}
