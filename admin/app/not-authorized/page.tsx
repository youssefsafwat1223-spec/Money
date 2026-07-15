"use client";

import { createClient } from "@/lib/supabase";
import { useRouter } from "next/navigation";

export default function NotAuthorizedPage() {
  const router = useRouter();

  async function signOut() {
    await createClient().auth.signOut();
    router.replace("/login");
    router.refresh();
  }

  return (
    <main className="min-h-screen flex items-center justify-center bg-brand-900 p-6">
      <section className="w-full max-w-md rounded-2xl bg-white p-8 text-center shadow-xl">
        <h1 className="text-xl font-semibold text-gray-900">Not authorized</h1>
        <p className="mt-3 text-sm text-gray-600">
          This account is valid, but it is not authorized to use Mali Admin.
        </p>
        <button
          type="button"
          onClick={signOut}
          className="mt-6 w-full rounded-lg bg-brand-500 px-4 py-2.5 text-sm font-medium text-white"
        >
          Sign out
        </button>
      </section>
    </main>
  );
}
